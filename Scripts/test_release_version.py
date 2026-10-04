"""Exercise release titles and versioning against real temporary Git histories."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from release_version import release_kind, release_version


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repository = Path(self.directory.name)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.commit("Released baseline")
        self.config = {"base_version": "1.3.1", "base_commit": self.git("rev-parse", "HEAD")}

    def git(self, *arguments):
        return subprocess.check_output(
            ["git", "-C", str(self.repository), *arguments], text=True, stderr=subprocess.PIPE
        ).strip()

    def commit(self, title="fix: correct usage"):
        self.git("commit", "--allow-empty", "-m", title)

    def version(self):
        return release_version(self.repository, self.config)

    def test_baseline_is_already_released(self):
        self.assertEqual(self.version(), {"version": "1.3.1", "tag": "v1.3.1", "build": "1"})

    def test_minor_resets_patch_and_fixes_increment_patch(self):
        for title, expected in [("fix: correct totals", "1.3.2"),
                                ("feat(review): add catalogue (#22)", "1.4.0"),
                                ("fix(chat): restore links", "1.4.1"),
                                ("feat: add another feature", "1.5.0")]:
            self.commit(title)
            self.assertEqual(self.version()["version"], expected)
        self.assertEqual(self.version()["build"], "5")

    def test_maintenance_merges_are_patch_releases(self):
        for patch_number, kind in enumerate(
            ["docs", "refactor", "perf", "test", "build", "ci", "chore", "revert"], start=2
        ):
            self.commit(f"{kind}: maintain project")
            self.assertEqual(self.version()["tag"], f"v1.3.{patch_number}")

    def test_rerun_and_out_of_order_run_keep_the_same_version(self):
        self.commit("feat: add review")
        first = self.git("rev-parse", "HEAD")
        self.commit()
        self.assertEqual(self.version(), self.version())
        self.assertEqual(release_version(self.repository, self.config, first)["tag"], "v1.4.0")
        self.assertEqual(self.version()["tag"], "v1.4.1")

    def test_only_first_parent_titles_count(self):
        self.git("switch", "-c", "feature")
        for _ in range(4):
            self.commit("feat: development step")
        self.git("switch", "main")
        self.git("merge", "--no-ff", "feature", "-m", "feat: complete feature")
        self.assertEqual(self.version()["tag"], "v1.4.0")
        self.assertEqual(self.version()["build"], "2")

    def test_squash_body_does_not_change_release_type(self):
        self.commit("fix: restore layout\n\nfeat: historical branch commit")
        self.assertEqual(self.version()["tag"], "v1.3.2")

    def test_reject_unknown_or_non_first_parent_baseline(self):
        self.commit()
        self.config["base_commit"] = "0" * 40
        with self.assertRaises(ValueError):
            self.version()
        self.git("switch", "-c", "feature")
        self.commit()
        self.config["base_commit"] = self.git("rev-parse", "HEAD")
        self.git("switch", "main")
        self.git("merge", "--no-ff", "feature", "-m", "feat: feature")
        with self.assertRaises(ValueError):
            self.version()

    def test_reject_invalid_config(self):
        for version in ["1.0", "01.0.0", "1.0.0\ninvalid=value", "1.0.0-beta"]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                release_version(self.repository, {**self.config, "base_version": version})
        with self.assertRaises(ValueError):
            release_version(self.repository, {**self.config, "base_commit": "HEAD"})

    def test_reject_unclassified_history_instead_of_guessing(self):
        self.commit("Add a new feature")
        with self.assertRaises(ValueError):
            self.version()

    def test_title_validation(self):
        self.assertEqual(release_kind("feat: календарь"), "minor")
        self.assertEqual(release_kind("fix(ui): restore layout (#42)"), "patch")
        for title in ["", "Add feature", "feature: x", "feat:", "fix: ", "feat!: breaking",
                      "feat(): x", "feat: x\nfix: y", "feat: x\n", "feat:  "]:
            with self.subTest(title=title), self.assertRaises(ValueError):
                release_kind(title)


if __name__ == "__main__":
    unittest.main()
