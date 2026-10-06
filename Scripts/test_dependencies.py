import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from ccusage_build import checked_patch, verify_built

spec = importlib.util.spec_from_file_location("dependencies", Path(__file__).with_name("prepare-dependencies.py"))
dependencies = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dependencies)


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))

    def test_modified_patch_and_mismatched_build_inputs_are_rejected(self):
        patch_file = self.root / "fix.patch"
        patch_file.write_bytes(b"reviewed patch")
        locked = {"patch": {"path": "fix.patch", "sha256": hashlib.sha256(patch_file.read_bytes()).hexdigest()}}
        self.assertEqual(checked_patch(self.root, locked), patch_file)
        patch_file.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "patch checksum"):
            checked_patch(self.root, locked)
        binary = self.root / "package/bin/ccusage"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"compiled")
        receipt = {"inputsSHA256": hashlib.sha256(json.dumps(locked, sort_keys=True).encode()).hexdigest(),
                   "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest()}
        (self.root / "build-receipt.json").write_text(json.dumps(receipt))
        verify_built(self.root, locked)
        with self.assertRaisesRegex(ValueError, "receipt mismatch"):
            verify_built(self.root, dict(locked, contractVersion=3))
        binary.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "receipt mismatch"):
            verify_built(self.root, locked)

    def test_corrupt_download_never_replaces_known_archive(self):
        destination = self.root / "archive"
        destination.write_bytes(b"previous")
        def corrupt(*args, **kwargs):
            destination.with_suffix(".partial").write_bytes(b"corrupt")
        with patch.object(dependencies.subprocess, "run", side_effect=corrupt):
            with self.assertRaises(ValueError):
                dependencies.download("https://example.invalid/locked", destination, "sha256", hashlib.sha256(b"expected").hexdigest())
        self.assertEqual(destination.read_bytes(), b"previous")
        self.assertFalse(destination.with_suffix(".partial").exists())

    def test_path_and_link_escapes_are_rejected(self):
        for name, link in [("../escape", None), ("/absolute", None), ("link", "../../escape")]:
            archive = self.root / "unsafe.tar"
            with tarfile.open(archive, "w") as target:
                member = tarfile.TarInfo(name)
                if link:
                    member.type = tarfile.SYMTYPE
                    member.linkname = link
                target.addfile(member, io.BytesIO())
            with self.subTest(name=name), self.assertRaises(ValueError):
                dependencies.extract(archive, self.root / "extracted")

    def test_framework_links_are_supported_and_tampering_changes_digest(self):
        archive = self.root / "framework.tar"
        with tarfile.open(archive, "w") as target:
            member = tarfile.TarInfo("Versions/B/Binary")
            member.size = 4
            target.addfile(member, io.BytesIO(b"code"))
            link = tarfile.TarInfo("Binary")
            link.type = tarfile.SYMTYPE
            link.linkname = "Versions/B/Binary"
            target.addfile(link)
        destination = self.root / "framework"
        dependencies.extract(archive, destination)
        self.assertEqual((destination / "Binary").read_bytes(), b"code")
        original = dependencies.contents_digest(destination)
        (destination / "Versions/B/Binary").write_bytes(b"changed")
        self.assertNotEqual(original, dependencies.contents_digest(destination))
