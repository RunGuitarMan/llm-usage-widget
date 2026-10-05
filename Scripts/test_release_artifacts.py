"""Publication checks read the actual ZIP and reject inconsistent release assets."""
import hashlib
import plistlib
import warnings
import zipfile

from build_version import build_identity, version_fields
from release_artifacts import APP_INFO, WIDGET_INFO, verify_archive, verify_release_assets
from sign_release import make_feed
from test_build_version import VersionRepository


class ReleaseArtifactTests(VersionRepository):
    def setUp(self):
        super().setUp()
        self.identity = build_identity(self.repository, "release")
        self.assets = self.root / "assets"
        self.assets.mkdir()
        self.archive = self.assets / "LLM-Usage-v1.4.0-macOS-arm64.zip"
        self.write_archive()
        self.write_sidecars()

    def write_archive(self, host=None, widget=None):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr(APP_INFO, plistlib.dumps(host or version_fields(self.identity)))
            archive.writestr(WIDGET_INFO, plistlib.dumps(widget or version_fields(self.identity)))

    def write_sidecars(self, version="1.4.0", build=None, url=None):
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (self.assets / "SHA256SUMS.txt").write_text(f"{digest}  {self.archive.name}\n")
        url = url or f"https://github.com/example/project/releases/download/v1.4.0/{self.archive.name}"
        (self.assets / "appcast.xml").write_bytes(make_feed(version, build or self.identity["build"],
            url, "signature", self.archive.stat().st_size, "Release"))

    def verify(self, tag="v1.4.0", commit=None):
        return verify_release_assets(tag, commit or self.identity["commit"], "example/project", self.assets, self.repository)

    def test_matching_archive_feed_checksum_and_source_pass(self):
        self.assertEqual(self.verify(), self.identity)

    def test_app_or_widget_version_build_source_channel_mismatch_is_rejected(self):
        for key, value in [("CFBundleShortVersionString", "1.3.1"), ("CFBundleVersion", "999"),
                           ("UsageSourceCommit", "a" * 40), ("UsageVersionCommit", "b" * 40),
                           ("UsageUpdateChannel", "development"), ("UsageSourceDirty", True)]:
            for target in ["host", "widget"]:
                with self.subTest(key=key, target=target):
                    altered = dict(version_fields(self.identity), **{key: value})
                    self.write_archive(**{target: altered})
                    self.write_sidecars()
                    with self.assertRaisesRegex(ValueError, key):
                        self.verify()

    def test_wrong_tag_or_checkout_is_rejected(self):
        for kwargs in [{"tag": "v1.4.1"}, {"commit": "a" * 40}]:
            with self.subTest(kwargs=kwargs), self.assertRaisesRegex(ValueError, "tag/commit"):
                self.verify(**kwargs)

    def test_stale_feed_version_build_or_download_url_is_rejected(self):
        for kwargs in [{"version": "1.3.1"}, {"build": "999"}, {"url": "https://example.invalid/old.zip"}]:
            self.write_sidecars(**kwargs)
            with self.subTest(kwargs=kwargs), self.assertRaisesRegex(ValueError, "Appcast"):
                self.verify()

    def test_checksum_for_another_archive_is_rejected(self):
        (self.assets / "SHA256SUMS.txt").write_text("0" * 64 + f"  {self.archive.name}\n")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.verify()

    def test_duplicate_metadata_and_missing_widget_are_rejected(self):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.archive, "a") as archive:
                archive.writestr(APP_INFO, plistlib.dumps(version_fields(self.identity)))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            verify_archive(self.archive, self.identity)
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr(APP_INFO, plistlib.dumps(version_fields(self.identity)))
        with self.assertRaisesRegex(ValueError, "Missing"):
            verify_archive(self.archive, self.identity)
