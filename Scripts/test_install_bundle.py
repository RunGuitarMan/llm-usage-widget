"""Exercise upgrades entirely inside a temporary Applications directory."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import Mock, patch

import install_bundle


class InstallBundleTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.source = self.root / "build/New.app"
        self.destination = self.root / "Applications/Installed.app"
        self.bundle(self.source, "new")
        self.bundle(self.destination, "old")

    def bundle(self, path, version, identifier="example.test"):
        (path / "Contents").mkdir(parents=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        (path / "Contents/executable").write_text(version)

    def installed_version(self):
        return (self.destination / "Contents/executable").read_text()

    def test_upgrade_drops_removed_resources_and_is_repeatable(self):
        obsolete = self.destination / "Contents/removed-resource"
        obsolete.write_text("obsolete sealed resource")
        verify = Mock()
        for _ in range(2):
            install_bundle.install(self.source, self.destination, verify)
            self.assertEqual(self.installed_version(), "new")
            self.assertFalse(obsolete.exists())
        self.assertEqual((self.source / "Contents/executable").read_text(), "new")

    def test_partial_copy_failure_preserves_installed_bundle(self):
        def fail_copy(args, **kwargs):
            target = Path(args[-1])
            (target / "Contents").mkdir(parents=True, exist_ok=True)
            (target / "Contents/executable").write_text("incomplete")
            raise subprocess.CalledProcessError(1, args)
        with patch.object(install_bundle.subprocess, "run", side_effect=fail_copy):
            with self.assertRaises(subprocess.CalledProcessError):
                install_bundle.install(self.source, self.destination, Mock())
        self.assertEqual(self.installed_version(), "old")

    def test_failed_verification_preserves_installed_bundle(self):
        verify = Mock(side_effect=[None, ValueError("Invalid copied bundle")])
        with self.assertRaises(ValueError):
            install_bundle.install(self.source, self.destination, verify)
        self.assertEqual(self.installed_version(), "old")

    def test_wrong_identifier_is_unchanged(self):
        (self.source / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "another.app"}))
        with self.assertRaises(ValueError):
            install_bundle.install(self.source, self.destination, Mock())
        self.assertEqual(self.installed_version(), "old")

    def test_fresh_install(self):
        target = self.root / "new-parent/New.app"
        install_bundle.install(self.source, target, Mock())
        self.assertEqual((target / "Contents/executable").read_text(), "new")

    def test_failed_rename_restores_previous_installation(self):
        rename = Path.rename
        def fail_commit(path, target):
            if path.name == self.destination.name and path.parent != self.destination.parent:
                raise OSError("Simulated rename failure")
            return rename(path, target)
        with patch.object(Path, "rename", fail_commit):
            with self.assertRaises(OSError):
                install_bundle.install(self.source, self.destination, Mock())
        self.assertEqual(self.installed_version(), "old")

    def test_failed_rollback_preserves_recovery_copy(self):
        rename = Path.rename
        def fail_commit_and_rollback(path, target):
            if Path(target) == self.destination:
                raise OSError("Simulated filesystem failure")
            return rename(path, target)
        with patch.object(Path, "rename", fail_commit_and_rollback):
            with self.assertRaisesRegex(RuntimeError, "preserved at"):
                install_bundle.install(self.source, self.destination, Mock())
        recovery = list(self.destination.parent.glob("*/previous.app/Contents/executable"))
        self.assertEqual([path.read_text() for path in recovery], ["old"])

    def test_destination_symlink_is_unchanged(self):
        link = self.destination.parent / "Linked.app"
        link.symlink_to(self.destination, target_is_directory=True)
        with self.assertRaises(ValueError):
            install_bundle.install(self.source, link, Mock())
        self.assertTrue(link.is_symlink())
        self.assertEqual(self.installed_version(), "old")

    def test_concurrent_installers_verify_and_replace_serially(self):
        second_source = self.root / "build/Second.app"
        self.bundle(second_source, "second")
        first_staged, second_waiting, release_first = (threading.Event() for _ in range(3))
        verified = []
        flock = install_bundle.fcntl.flock
        calls = 0
        def lock(fd, operation):
            nonlocal calls
            calls += 1
            if calls == 2:
                second_waiting.set()
            return flock(fd, operation)
        def verify(path):
            if path in (self.source, second_source):
                return
            verified.append((path / "Contents/executable").read_text())
            if len(verified) == 1:
                first_staged.set()
                if not release_first.wait(5):
                    raise TimeoutError("Test did not release first installation")
        with patch.object(install_bundle.fcntl, "flock", lock), ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(install_bundle.install, self.source, self.destination, verify)
            try:
                self.assertTrue(first_staged.wait(5))
                second = pool.submit(install_bundle.install, second_source, self.destination, verify)
                self.assertTrue(second_waiting.wait(5))
                self.assertEqual(verified, ["new"])
            finally:
                release_first.set()
            first.result(timeout=5)
            second.result(timeout=5)
        self.assertEqual(verified, ["new", "second"])
        self.assertEqual(self.installed_version(), "second")


if __name__ == "__main__":
    unittest.main()
