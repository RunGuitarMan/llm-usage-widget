"""Exercise versioning against real temporary Git histories."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from release_version import release_version


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repository = Path(self.directory.name)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.commit()
        self.config = {"base_version": "1.0", "base_commit": self.git("rev-parse", "HEAD")}

    def git(self, *arguments):
        return subprocess.check_output(
            ["git", "-C", str(self.repository), *arguments], text=True, stderr=subprocess.PIPE
        ).strip()

    def commit(self):
        self.git("commit", "--allow-empty", "-m", "Test commit")

    def version(self):
        return release_version(self.repository, self.config)

    def test_initial_release_and_patch_increments(self):
        self.commit()
        self.assertEqual(self.version(), {"version": "1.0", "tag": "v1.0", "build": "2"})
        for patch in range(1, 4):
            self.commit()
            self.assertEqual(self.version()["tag"], f"v1.0.{patch}")

    def test_rerun_and_out_of_order_run_keep_the_same_version(self):
        self.commit()
        first = self.git("rev-parse", "HEAD")
        self.commit()
        self.assertEqual(self.version(), self.version())
        self.assertEqual(release_version(self.repository, self.config, first)["tag"], "v1.0")
        self.assertEqual(self.version()["tag"], "v1.0.1")

    def test_merge_counts_once_regardless_of_feature_commits(self):
        self.git("switch", "-c", "feature")
        for _ in range(4):
            self.commit()
        self.git("switch", "main")
        self.git("merge", "--no-ff", "feature", "-m", "Merge feature")
        self.assertEqual(self.version()["tag"], "v1.0")

    def test_new_version_line(self):
        self.config["base_version"] = "2.3.4"
        self.commit()
        self.assertEqual(self.version()["tag"], "v2.3.4")
        self.commit()
        self.assertEqual(self.version()["tag"], "v2.3.5")

    def test_reject_baseline_without_a_release_commit(self):
        with self.assertRaises(ValueError):
            self.version()

    def test_reject_unknown_baseline_and_invalid_version(self):
        self.commit()
        self.config["base_commit"] = "0" * 40
        with self.assertRaises(ValueError):
            self.version()
        self.config["base_version"] = "1.0\ninvalid=value"
        with self.assertRaises(ValueError):
            self.version()


if __name__ == "__main__":
    unittest.main()
