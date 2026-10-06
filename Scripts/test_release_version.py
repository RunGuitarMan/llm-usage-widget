"""Exercise manual versions and monotonic PR checks against real Git histories."""
import json
import unittest

from release_version import check_increase, configured_version, previous_version, release_version
from test_build_version import VersionRepository


class ReleaseVersionTests(VersionRepository):
    def test_reads_exact_version_independently_of_commit_title(self):
        self.write_version("7.12.3")
        self.git("commit", "-am", "Any PR title is allowed")
        self.assertEqual(release_version(self.repository), {"version": "7.12.3", "tag": "v7.12.3", "build": "3"})
        self.git("commit", "--allow-empty", "-m", "feat!: title must not change version")
        self.assertEqual(release_version(self.repository)["version"], "7.12.3")

    def test_requires_a_strict_increase_with_numeric_comparison(self):
        for version in ["1.4.1", "1.10.0", "2.0.0", "9.0.0"]:
            self.write_version(version)
            with self.subTest(version=version):
                self.assertEqual(check_increase(self.repository, "HEAD")["version"], version)
        for version in ["1.4.0", "1.3.99", "0.99.99"]:
            self.write_version(version)
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "Every PR must increase"):
                check_increase(self.repository, "HEAD")
        self.write_version("1.10.0")
        self.git("commit", "-am", "Choose minor version")
        self.write_version("1.9.99")
        with self.assertRaises(ValueError):
            check_increase(self.repository, "HEAD")

    def test_parallel_pr_must_pick_a_higher_version_after_first_merges(self):
        base = self.git("rev-parse", "HEAD")
        self.write_version("1.4.1")
        check_increase(self.repository, base)
        self.git("commit", "-am", "First PR")
        # A second PR that still proposes 1.4.1 fails against the updated base.
        with self.assertRaisesRegex(ValueError, "greater than 1.4.1"):
            check_increase(self.repository, "HEAD")
        self.write_version("1.4.2")
        check_increase(self.repository, "HEAD")

    def test_rejects_missing_invalid_and_legacy_current_configuration(self):
        for config in [{}, {"base_version": "1.4.0", "base_commit": "a" * 40}, [],
                       {"version": "1.4.1", "other": True}]:
            with self.subTest(config=config), self.assertRaises(ValueError):
                configured_version(config)
        for version in [None, 123, "1.0", "v1.0.0", "01.0.0", "1.00.0", "1.0.0\n", "1.0.0-beta", "1.0.0+build"]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                configured_version({"version": version})
        (self.repository / ".github/release.json").unlink()
        with self.assertRaises(FileNotFoundError):
            release_version(self.repository)

    def test_migration_compares_against_actual_legacy_main_version(self):
        baseline = self.git("rev-parse", "HEAD")
        (self.repository / ".github/release.json").write_text(json.dumps(
            {"base_version": "1.4.0", "base_commit": baseline}))
        self.git("commit", "-am", "feat: previous automatic release")
        self.git("commit", "--allow-empty", "-m", "fix: unreleased main change")
        self.assertEqual(previous_version(self.repository, "HEAD"), "1.5.1")
        self.write_version("1.5.1")
        with self.assertRaises(ValueError):
            check_increase(self.repository, "HEAD")
        self.write_version("1.5.2")
        check_increase(self.repository, "HEAD")

    def test_build_number_uses_first_parent_history(self):
        self.git("switch", "-c", "feature")
        for _ in range(3):
            self.git("commit", "--allow-empty", "-m", "Intermediate work")
        self.write_version("1.4.1")
        self.git("commit", "-am", "Choose version")
        self.git("switch", "main")
        self.git("merge", "--no-ff", "feature", "-m", "Merged PR")
        self.assertEqual(release_version(self.repository)["build"], "3")
        self.assertEqual(release_version(self.repository)["version"], "1.4.1")


if __name__ == "__main__":
    unittest.main()
