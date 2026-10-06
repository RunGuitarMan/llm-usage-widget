import hashlib
from pathlib import Path
import plistlib
import tempfile
import unittest

from bundle_identity import app_bundle_id, RELEASE_BUNDLE_ID, LOCAL_BUNDLE_ID
from package_icon import install_icon


class WidgetPackagingTests(unittest.TestCase):
    def test_release_identity_is_stable_but_development_is_isolated(self):
        self.assertEqual(app_bundle_id("release"), "local.ClaudeUsage.Development")
        self.assertEqual(app_bundle_id("development"), LOCAL_BUNDLE_ID)
        self.assertNotEqual(app_bundle_id("release"), app_bundle_id("development"))
        with self.assertRaises(ValueError):
            app_bundle_id("development", RELEASE_BUNDLE_ID)
        with self.assertRaises(ValueError):
            app_bundle_id("release", LOCAL_BUNDLE_ID)

    def test_review_override_cannot_change_release_identity(self):
        self.assertEqual(app_bundle_id("development", "local.ClaudeUsage.ManualReview"), "local.ClaudeUsage.ManualReview")
        for channel, override in [("unknown", None), ("release", "local.fixture"), ("development", "../escape")]:
            with self.subTest(channel=channel, override=override), self.assertRaises(ValueError):
                app_bundle_id(channel, override)

    def test_gallery_icon_identity_changes_with_bytes_and_matches_both_bundles(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            icon = root / "generated.icns"
            app, widget = root / "LLM Usage.app", root / "LLM Usage.app/Contents/PlugIns/LLMUsageWidget.appex"
            for bundle in (app, widget):
                (bundle / "Contents/Resources").mkdir(parents=True)
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIconFile": "LLMUsage"}))
                (bundle / "Contents/Resources/LLMUsage.icns").write_bytes(b"old icon")
            previous = None
            for payload in (b"old approved artwork", b"new approved artwork"):
                data = b"icns" + (len(payload) + 8).to_bytes(4, "big") + payload
                icon.write_bytes(data)
                names = [install_icon(bundle, icon) for bundle in (app, widget)]
                self.assertEqual(names[0], names[1])
                self.assertNotEqual(names[0], previous)
                for bundle in (app, widget):
                    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
                    self.assertEqual(info["CFBundleIconFile"], "LLMUsage-" + hashlib.sha256(data).hexdigest()[:16])
                    self.assertEqual((bundle / "Contents/Resources" / (names[0] + ".icns")).read_bytes(), data)
                    self.assertFalse((bundle / "Contents/Resources/LLMUsage.icns").exists())
                    if previous:
                        self.assertFalse((bundle / "Contents/Resources" / (previous + ".icns")).exists())
                previous = names[0]

    def test_missing_or_truncated_icon_cannot_silently_reuse_an_old_resource(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(FileNotFoundError):
                install_icon(root / "app", root / "missing.icns")
            icon = root / "truncated.icns"
            icon.write_bytes(b"icns" + (100).to_bytes(4, "big"))
            with self.assertRaises(ValueError):
                install_icon(root / "app", icon)
