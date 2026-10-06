import unittest
import xml.etree.ElementTree as ET

from sign_release import make_feed, SPARKLE


class AppcastTests(unittest.TestCase):
    def test_release_identity_signature_and_escaped_notes(self):
        feed = ET.fromstring(make_feed("1.5.0", "100", "https://example.invalid/update.zip", "signature", 123, "Fix <unsafe> & text"))
        item = feed.find("./channel/item")
        self.assertEqual(item.findtext(f"{{{SPARKLE}}}version"), "100")
        self.assertEqual(item.findtext(f"{{{SPARKLE}}}minimumSystemVersion"), "26.0")
        self.assertEqual(item.findtext("description"), "Fix <unsafe> & text")
        self.assertEqual(item.find("enclosure").get(f"{{{SPARKLE}}}edSignature"), "signature")

    def test_retry_keeps_distinct_builds_and_older_compatible_releases(self):
        previous = ET.fromstring(make_feed("1.5.0", "100", "https://example.invalid/update.zip", "sig", 1, "First"))
        retry = ET.fromstring(make_feed("1.5.0", "100", "https://example.invalid/update.zip", "sig", 1, "First", previous))
        self.assertEqual(len(retry.findall("./channel/item")), 1)
        next_feed = ET.fromstring(make_feed("1.5.1", "101", "https://example.invalid/update.zip", "sig", 1, "Second", previous))
        self.assertEqual([item.findtext(f"{{{SPARKLE}}}version") for item in next_feed.findall("./channel/item")], ["101", "100"])

    def test_invalid_version_is_not_published(self):
        with self.assertRaises(ValueError):
            make_feed("latest", "100", "https://example.invalid", "sig", 1, "")

    def test_version_or_build_cannot_move_backwards_even_after_other_checks(self):
        previous = ET.fromstring(make_feed("1.5.0", "100", "https://example.invalid/update.zip", "sig", 1, "First"))
        for version, build in [("1.4.99", "101"), ("1.5.0", "101"), ("1.5.1", "99"), ("2.0.0", "100")]:
            with self.subTest(version=version, build=build), self.assertRaisesRegex(ValueError, "must both increase"):
                make_feed(version, build, "https://example.invalid/update.zip", "sig", 1, "Later", previous)
