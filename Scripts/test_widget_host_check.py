import unittest
from widget_host_check import assess, EXPECTED


class WidgetHostCheckTests(unittest.TestCase):
    bundle = "local.ClaudeUsage.Local.Widget"

    def deliveries(self, generation=100, version="1.5.4"):
        return [{"eventMessage": f"WidgetDelivery bundle={self.bundle} version={version} kind={kind} family={family} phase=timeline generation={generation} storageUnavailable=false"}
                for kind, family in EXPECTED]

    def test_actual_fresh_delivery_of_every_kind_and_size(self):
        self.assertEqual(len(assess(self.deliveries(), self.bundle, "1.5.4", 100)), 9)

    def test_reported_regression_fails_even_when_provider_read_fresh_data(self):
        events = self.deliveries() + [{"eventMessage": f"[{self.bundle}] on local reload: failed with error WidgetKit.WidgetArchiver.ValidationError.bundleStubNotSupported(underlyingError: Bundle version did not match; LaunchServices DB may need to be rebuilt)"}]
        with self.assertRaisesRegex(ValueError, "rejected an archive"):
            assess(events, self.bundle, "1.5.4", 100)

    def test_empty_desktop_missing_family_old_generation_and_old_binary_fail(self):
        for events in ([], self.deliveries()[:-1], self.deliveries(generation=99), self.deliveries(version="1.5.3")):
            with self.subTest(events=len(events)), self.assertRaises(ValueError):
                assess(events, self.bundle, "1.5.4", 100)

    def test_deleted_build_launch_job_fails_even_with_fresh_provider_receipts(self):
        for failure in ("Missing executable detected", "Could not find and/or execute program specified by service",
                        "Attempt to re-bootstrap service from different path, will use existing",
                        "Failed to create extensionProcess", "Failed to launch extension"):
            events = self.deliveries() + [{"eventMessage": f"[{self.bundle}] {failure}"}]
            with self.subTest(failure=failure), self.assertRaisesRegex(ValueError, "launch/registration failed"):
                assess(events, self.bundle, "1.5.4", 100)

    def test_another_apps_errors_do_not_invalidate_the_test(self):
        events = self.deliveries() + [{"eventMessage": "[other.Widget] failed with error ValidationError"},
                                     {"eventMessage": "[other.Widget] Missing executable detected"}]
        self.assertEqual(len(assess(events, self.bundle, "1.5.4", 100)), 9)

    def test_storage_failure_is_not_a_successful_delivery(self):
        events = self.deliveries()
        events[0]["eventMessage"] = events[0]["eventMessage"].replace("storageUnavailable=false", "storageUnavailable=true")
        with self.assertRaisesRegex(ValueError, "could not read"):
            assess(events, self.bundle, "1.5.4", 100)
