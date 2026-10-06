import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("boundaries", ROOT / "Scripts/diagnose-claude-boundaries.py")
BOUNDARIES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOUNDARIES)
FIXTURES = {case["name"]: case for case in json.loads(
    (ROOT / "LLMUsage/Tests/Fixtures/claude-response-boundaries.json").read_text())}


class BoundaryDiagnosticsTests(unittest.TestCase):
    def scan(self, records):
        with tempfile.TemporaryDirectory(prefix="private-diagnostic-") as directory:
            project = Path(directory) / "projects/private-project-identity"
            project.mkdir(parents=True)
            (project / "private-session-identity.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in records))
            return BOUNDARIES.inspect_boundaries("2026-10-05", "UTC", [directory])

    def test_stop_reason_is_not_a_request_boundary(self):
        for name in ("requestless_tool_use_fragments", "requestless_end_turn_fragments",
                     "requestless_equal_counters_with_stop_reason"):
            with self.subTest(name=name):
                report = self.scan(FIXTURES[name]["records"])["whole_window"]
                self.assertEqual(report["pairs_accepted_by_current_patch"], 1)
                self.assertEqual(report["pairs_previously_blocked_only_by_stop_reason"], 1)
                self.assertEqual(report["failed_conditions"], {})

    def test_diagnostic_rules_match_the_shared_cli_fixtures(self):
        merged = {name: 1 for name in (
            "requestless_stream", "requestless_tool_use_fragments", "requestless_equal_counters_with_stop_reason",
            "requestless_end_turn_fragments", "stream_progress", "stream_replay", "stream_midnight",
            "interleaved_tool_fragments", "interleaved_tool_hook_fragments", "interleaved_tools_midnight")}
        merged["interleaved_multiple_tool_fragments"] = 2
        for name, case in FIXTURES.items():
            with self.subTest(name=name):
                report = self.scan(case["records"])["whole_window"]
                self.assertEqual(report["pairs_accepted_by_current_patch"], merged.get(name, 0))

    def test_real_boundaries_remain_separate(self):
        for name, label in (("gateway_new_user", "user_without_tool_result"),
                            ("gateway_tool_result", "user_tool_result"),
                            ("gateway_unknown_boundary", "other")):
            with self.subTest(name=name):
                report = self.scan(FIXTURES[name]["records"])["whole_window"]
                self.assertEqual(report["pairs_accepted_by_current_patch"], 0)
                context = report["remaining_pair_context"]
                self.assertEqual(context["intervening_records"], {label: 1})
                self.assertEqual(context["current_parent_kind"], {label: 1})
                self.assertEqual(context["current_parent_location"], {"between_pair_records": 1})

    def test_boundary_overrides_even_a_direct_parent_link(self):
        report = self.scan(FIXTURES["gateway_boundary_with_misleading_parent"]["records"])["whole_window"]
        self.assertEqual(report["pairs_accepted_by_current_patch"], 0)
        self.assertEqual(report["failed_conditions"], {"not_previous_assistant_in_patch": 1})

    def tool_rows(self):
        rows = copy.deepcopy(FIXTURES["gateway_tool_result"]["records"])
        rows[1]["message"]["content"] = [{"type": "tool_use", "id": "t", "name": "synthetic", "input": {"value": "private"}}]
        rows[2]["parentUuid"] = "a1"
        rows[3]["message"] = copy.deepcopy(rows[1]["message"])
        return rows

    def test_replayed_tool_payload_and_ancestry_are_compared_locally(self):
        report = self.scan(self.tool_rows())["whole_window"]
        context = report["remaining_pair_context"]
        self.assertEqual(context["content_equality"], {"equal": 1})
        self.assertEqual(context["message_payload_equality"], {"equal": 1})
        self.assertEqual(context["tool_id_relationship"], {"identical": 1})
        self.assertEqual(context["shared_tool_payloads"], {"equal": 1})
        self.assertEqual(context["intervening_tool_result_ownership"], {"previous_fragment": 1})
        self.assertEqual(context["parent_chain"], {"reaches_previous_fragment": 1})
        self.assertEqual(report["unmerged_pair_previous_tokens"], {
            "inputTokens": 100, "outputTokens": 10, "cacheCreationTokens": 40, "cacheReadTokens": 20})

    def test_distinct_tool_calls_are_distinguishable_from_replays(self):
        rows = self.tool_rows()
        rows[3]["message"]["content"][0]["id"] = "different-call"
        report = self.scan(rows)["whole_window"]
        self.assertEqual(report["pairs_accepted_by_current_patch"], 1)
        self.assertEqual(report["pairs_joined_across_owned_tool_results"], 1)
        self.assertEqual(report["remaining_pair_context"], {})

    def test_same_counters_do_not_prove_that_a_new_text_answer_is_a_replay(self):
        rows = self.tool_rows()
        rows[3]["message"]["content"] = [{"type": "text", "text": "New answer"}]
        context = self.scan(rows)["whole_window"]["remaining_pair_context"]
        self.assertEqual(context["usage_relation"], {"equal": 1})
        self.assertEqual(context["content_equality"], {"different": 1})
        self.assertEqual(context["tool_id_relationship"], {"only_previous": 1})

    def test_chain_that_bypasses_previous_fragment_is_not_reported_as_linked(self):
        rows = self.tool_rows()
        rows[2]["parentUuid"] = "u1"
        context = self.scan(rows)["whole_window"]["remaining_pair_context"]
        self.assertEqual(context["parent_chain"], {"bypasses_previous_fragment": 1})

    def test_tool_arguments_results_ids_and_fingerprints_are_never_exported(self):
        rows = self.tool_rows()
        marker = "PRIVATE-TOOL-CONTENT"
        for i in (1, 3):
            rows[i]["message"]["content"][0].update(id=marker, name=marker, input={marker: marker})
        rows[2]["message"]["content"][0].update(tool_use_id=marker, content=marker)
        report = self.scan(rows)
        output = json.dumps(report)
        self.assertNotIn(marker, output)
        for row in rows:
            metadata = BOUNDARIES.content_metadata(row)
            for field in ("content_fingerprint", "payload_fingerprint"):
                if metadata[field]:
                    self.assertNotIn(metadata[field].hex(), output)
        context = report["whole_window"]["remaining_pair_context"]
        self.assertEqual(context["intervening_tool_result_ownership"], {"previous_fragment": 1})

    def test_only_fixed_labels_and_aggregates_are_exported(self):
        rows = copy.deepcopy(FIXTURES["gateway_unknown_boundary"]["records"])
        marker = "SENSITIVE-IDENTITY-CONTENT"
        for row in rows:
            row["sessionId"] = marker
            row["uuid"] = marker + str(row.get("uuid"))
            row["parentUuid"] = marker + str(row.get("parentUuid"))
            if isinstance(row.get("message"), dict):
                row["message"]["id"] = marker
                row["message"]["model"] = marker
                row["message"]["content"] = marker
                row["message"]["stop_reason"] = marker
        rows[2]["type"] = marker
        report = self.scan(rows)
        output = json.dumps(report)
        self.assertNotIn(marker, output)
        self.assertNotIn("private-project", output)
        self.assertNotIn("private-session", output)
        self.assertNotIn("private-diagnostic", output)
        self.assertEqual(report["whole_window"]["previous_stop_reasons"], {"other": 1})
        self.assertEqual(report["whole_window"]["remaining_pair_context"]["intervening_records"], {"other": 1})

    def test_empty_directory_is_reported_without_private_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(BOUNDARIES.inspect_boundaries("2026-10-05", "UTC", [directory]),
                             {"status": "no_jsonl_files"})


if __name__ == "__main__":
    unittest.main()
