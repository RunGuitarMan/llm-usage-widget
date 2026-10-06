"""Verify manual publication, monotonic releases and safe retries before any mutation."""
import subprocess
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import publish_release


class PublishReleaseTests(unittest.TestCase):
    def setUp(self):
        env = {"GITHUB_REPOSITORY": "example/project", "GITHUB_SHA": "a" * 40,
               "GITHUB_REF": "refs/heads/main", "GITHUB_EVENT_NAME": "workflow_dispatch", "RELEASE_TAG": "v2.0.0"}
        self.enterContext(patch.dict(publish_release.os.environ, env))
        self.api = self.enterContext(patch.object(publish_release, "api"))
        self.run = self.enterContext(patch.object(publish_release.subprocess, "run"))
        self.verify = self.enterContext(patch.object(publish_release, "verify_release_assets"))
        self.enterContext(patch.object(publish_release.Path, "is_file", return_value=True))
        self.enterContext(patch.object(publish_release.Path, "stat", return_value=SimpleNamespace(st_size=100)))
        self.enterContext(patch.object(publish_release.Path, "read_text", return_value="Install notes"))
        self.tag = {"object": {"sha": "a" * 40}}
        self.draft = {"id": 42, "draft": True}
        self.published = {"id": 42, "draft": False, "html_url": "https://example.invalid/release"}
        self.latest = {"tag_name": "v1.5.0"}

    def test_wrong_commit_cannot_be_overwritten(self):
        self.api.return_value = {"object": {"sha": "b" * 40}}
        with self.assertRaises(SystemExit):
            publish_release.main()
        self.run.assert_not_called()
        self.assertEqual(self.api.call_count, 1)

    def test_published_release_is_unchanged_on_retry(self):
        self.api.side_effect = [self.tag, self.published]
        publish_release.main()
        self.run.assert_not_called()
        self.assertEqual(self.api.call_count, 2)

    def test_new_release_can_skip_versions_and_stays_draft_until_upload_completes(self):
        self.api.side_effect = [None, None, self.latest, self.draft, self.published]
        publish_release.main()
        create = self.api.call_args_list[3]
        self.assertTrue(create.args[2]["draft"])
        self.assertEqual(create.args[2]["target_commitish"], "a" * 40)
        self.assertTrue(create.args[2]["generate_release_notes"])
        self.run.assert_called_once()
        self.assertEqual(self.api.call_args.args[2], {"draft": False, "make_latest": "legacy", "name": "LLM Usage 2.0.0"})

    def test_failed_upload_leaves_draft_for_retry(self):
        self.api.side_effect = [self.tag, self.draft, self.latest]
        self.run.side_effect = subprocess.CalledProcessError(1, "gh release upload")
        with self.assertRaises(subprocess.CalledProcessError):
            publish_release.main()
        self.assertEqual(self.api.call_count, 3)

    def test_existing_draft_resumes_without_creating_another(self):
        self.api.side_effect = [self.tag, self.draft, self.latest, self.published]
        publish_release.main()
        self.run.assert_called_once()
        self.assertEqual(self.api.call_args.args[1], "PATCH")

    def test_draft_can_resume_before_github_creates_its_tag(self):
        self.api.side_effect = [None, self.draft, self.latest, self.published]
        publish_release.main()
        self.run.assert_called_once()
        self.assertEqual(self.api.call_args.args[1], "PATCH")

    def test_missing_assets_cannot_be_published(self):
        self.api.side_effect = [None, None, self.latest]
        with patch.object(publish_release.Path, "is_file", return_value=False):
            with self.assertRaises(SystemExit):
                publish_release.main()
        self.assertEqual(self.api.call_count, 3)
        self.run.assert_not_called()

    def test_mismatched_archive_prevents_all_publication_mutations(self):
        self.api.side_effect = [None, None, self.latest]
        self.verify.side_effect = ValueError("Archived application has another version")
        with self.assertRaisesRegex(ValueError, "another version"):
            publish_release.main()
        self.assertEqual([call.args[0] for call in self.api.call_args_list], [
            "repos/example/project/git/ref/tags/v2.0.0", "repos/example/project/releases/tags/v2.0.0",
            "repos/example/project/releases/latest"])
        self.run.assert_not_called()

    def test_push_and_non_main_runs_cannot_publish(self):
        for env in [{"GITHUB_EVENT_NAME": "push"}, {"GITHUB_EVENT_NAME": "pull_request"},
                    {"GITHUB_REF": "refs/heads/work"}]:
            with self.subTest(env=env), patch.dict(publish_release.os.environ, env):
                with self.assertRaises(SystemExit):
                    publish_release.main()
        self.api.assert_not_called()
        self.run.assert_not_called()

    def test_older_equal_or_stale_draft_release_cannot_be_published(self):
        for latest in ["v2.0.0", "v2.0.1", "v10.0.0"]:
            for release in [None, self.draft]:
                with self.subTest(latest=latest, release=release):
                    self.api.reset_mock()
                    self.api.side_effect = [self.tag, release, {"tag_name": latest}]
                    with self.assertRaisesRegex(SystemExit, "must be greater"):
                        publish_release.main()
                    self.assertEqual(self.api.call_count, 3)
        self.run.assert_not_called()
        self.verify.assert_not_called()

    def test_preflight_is_read_only_and_needs_no_artifacts(self):
        for latest in [self.latest, None]:
            self.api.reset_mock()
            self.api.side_effect = [None, None, latest]
            publish_release.main(check_only=True)
            self.assertEqual(self.api.call_count, 3)
        self.run.assert_not_called()
        self.verify.assert_not_called()

    def test_release_without_source_tag_fails_closed(self):
        self.api.side_effect = [None, self.published]
        with self.assertRaisesRegex(SystemExit, "missing its source tag"):
            publish_release.main()
        self.run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
