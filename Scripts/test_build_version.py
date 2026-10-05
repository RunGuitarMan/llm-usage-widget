"""Version identity must survive branching and reject manual/stale build metadata."""
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

from build_version import build_identity, validate_info, verify_bundle, version_fields


class VersionRepository(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.repository = self.root / "source"
        self.repository.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Version tests")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("commit", "--allow-empty", "-m", "Released baseline")
        baseline = self.git("rev-parse", "HEAD")
        self.git("tag", "v1.3.1")
        (self.repository / ".github").mkdir()
        (self.repository / ".github/release.json").write_text(json.dumps({"base_version": "1.3.1", "base_commit": baseline}))
        self.git("add", ".github/release.json")
        self.git("commit", "-m", "feat: release feature")
        self.git("tag", "v1.4.0")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repository), *args], text=True, stderr=subprocess.PIPE).strip()


class BuildVersionTests(VersionRepository):
    def test_release_and_test_build_share_the_release_version(self):
        release = build_identity(self.repository, "release")
        review = build_identity(self.repository)
        self.assertEqual(release["version"], "1.4.0")
        self.assertEqual(release["version"], review["version"])
        self.assertEqual(release["build"], review["build"])
        self.assertEqual(release["commit"], review["versionCommit"])

    def test_branch_uses_base_release_and_records_actual_source(self):
        base = self.git("rev-parse", "HEAD")
        self.git("switch", "-c", "work")
        self.git("commit", "--allow-empty", "-m", "Unfinished work without a release title")
        development = build_identity(self.repository)
        self.assertEqual(development["version"], "1.4.0")
        self.assertEqual(development["versionCommit"], base)
        self.assertNotEqual(development["commit"], base)
        self.assertEqual(development["channel"], "development")

    def test_manual_version_override_is_rejected(self):
        for override in [{"MARKETING_VERSION": "1.3.1"}, {"CURRENT_PROJECT_VERSION": "999"}]:
            with self.subTest(override=override), self.assertRaises(ValueError):
                build_identity(self.repository, overrides=override)

    def test_dirty_tree_is_marked_for_review_and_rejected_for_release(self):
        (self.repository / "uncommitted.swift").write_text("changed source")
        self.assertTrue(build_identity(self.repository)["dirty"])
        with self.assertRaisesRegex(ValueError, "clean source tree"):
            build_identity(self.repository, "release")

    def test_missing_or_inconsistent_tags_fail_without_a_fallback_number(self):
        self.git("tag", "-d", "v1.4.0", "v1.3.1")
        with self.assertRaises(subprocess.CalledProcessError):
            build_identity(self.repository)
        self.git("tag", "v9.9.9")
        with self.assertRaisesRegex(ValueError, "tag disagrees"):
            build_identity(self.repository)

    def test_shallow_history_is_rejected(self):
        clone = self.root / "shallow"
        subprocess.run(["git", "clone", "--depth", "1", self.repository.as_uri(), str(clone)], check=True, capture_output=True)
        with self.assertRaisesRegex(ValueError, "full Git history"):
            build_identity(clone)

    def test_bundle_and_widget_cannot_keep_an_old_version(self):
        identity = build_identity(self.repository)
        app = self.root / "Application.app"
        host = app / "Contents/Info.plist"
        widget = app / "Contents/PlugIns/LLMUsageWidget.appex/Contents/Info.plist"
        for path in [host, widget]:
            path.parent.mkdir(parents=True)
            path.write_bytes(plistlib.dumps(version_fields(identity)))
        verify_bundle(app, identity, with_widget=True)
        info = version_fields(identity)
        info["CFBundleShortVersionString"] = "1.3.1"
        widget.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "CFBundleShortVersionString"):
            verify_bundle(app, identity, with_widget=True)

    def test_review_bundle_cannot_be_marked_as_a_release(self):
        identity = build_identity(self.repository, "release")
        with self.assertRaisesRegex(ValueError, "review build"):
            validate_info(dict(version_fields(identity), ManualReviewBuild="review"), identity)
