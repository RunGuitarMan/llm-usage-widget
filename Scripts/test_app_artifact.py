"""Reject a stale or different binary instead of silently testing a second app."""
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

from app_artifact import artifact_lock, record, verify


class AppArtifactTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.app = self.root / 'LLM Usage.app'
        host = self.app / 'Contents/MacOS/LLM Usage'
        host.parent.mkdir(parents=True)
        host.write_bytes(b'common app executable')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'LLM Usage', 'CFBundleIdentifier': 'local.ClaudeUsage.Development',
            'CFBundleVersion': '12', 'CFBundleShortVersionString': '1.5.3'}))
        self.widget = self.app / 'Contents/PlugIns/LLMUsageWidget.appex/Contents/MacOS/LLMUsageWidget'
        self.widget.parent.mkdir(parents=True)
        self.widget.write_bytes(b'embedded widget')
        self.identity = {'commit': 'a' * 40, 'sourceSHA256': 'b' * 64}
        self.source = self.enterContext(patch('app_artifact.source_identity', return_value=self.identity))
        self.manifest = self.root / 'app-artifact.json'
        record(self.app, self.manifest, self.identity)

    def test_normal_and_review_can_reuse_one_immutable_artifact(self):
        before = self.manifest.read_bytes()
        normal = verify(self.app, self.manifest)
        review = verify(self.app, self.manifest)
        self.assertEqual(normal['executableSHA256'], review['executableSHA256'])
        self.assertEqual(before, self.manifest.read_bytes())

    def test_old_source_revision_is_rejected(self):
        self.source.return_value = dict(self.identity, sourceSHA256='c' * 64)
        with self.assertRaisesRegex(ValueError, 'stale'):
            verify(self.app, self.manifest)

    def test_changes_during_compilation_do_not_get_a_valid_manifest(self):
        self.source.return_value = dict(self.identity, commit='c' * 40)
        with self.assertRaisesRegex(ValueError, 'during the build'):
            record(self.app, self.manifest, self.identity)

    def test_app_and_widget_changes_are_both_rejected(self):
        for target in [self.app / 'Contents/MacOS/LLM Usage', self.widget]:
            original = target.read_bytes()
            with self.subTest(target=target):
                target.write_bytes(b'different executable')
                with self.assertRaisesRegex(ValueError, 'differs'):
                    verify(self.app, self.manifest)
            target.write_bytes(original)

    def test_repackaging_or_resigning_is_rejected(self):
        signature = self.app / 'Contents/_CodeSignature/CodeResources'
        signature.parent.mkdir()
        signature.write_bytes(b'different signature')
        with self.assertRaisesRegex(ValueError, 'differs'):
            verify(self.app, self.manifest)

    def test_separate_review_identity_is_rejected_even_with_matching_manifest(self):
        info = self.app / 'Contents/Info.plist'
        value = plistlib.loads(info.read_bytes())
        value['CFBundleIdentifier'] = 'local.ClaudeUsage.ManualReview'
        info.write_bytes(plistlib.dumps(value))
        record(self.app, self.manifest, self.identity)
        with self.assertRaisesRegex(ValueError, 'separate review bundle'):
            verify(self.app, self.manifest)

    def test_build_cannot_replace_an_artifact_while_checks_hold_the_lock(self):
        (self.root / 'build').mkdir()
        with artifact_lock(self.root):
            with self.assertRaisesRegex(ValueError, 'being built or checked'):
                with artifact_lock(self.root):
                    self.fail('two operations acquired the artifact')
        with artifact_lock(self.root):
            pass

    def test_launcher_contains_no_compilation_or_bundle_mutation(self):
        root = Path(__file__).resolve().parent
        launcher = (root / 'launch-review.py').read_text() + (root / 'manual-review.sh').read_text()
        for forbidden in ['swiftc', 'package-bundle', 'build-local.sh', 'codesign --force', 'shutil.copy', 'shutil.move']:
            self.assertNotIn(forbidden, launcher)


if __name__ == '__main__':
    unittest.main()
