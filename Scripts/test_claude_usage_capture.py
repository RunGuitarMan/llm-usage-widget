"""Synthetic CLI/HTTP tests. Never starts Claude or reads the user's transcripts."""
import argparse
import contextlib
import http.client
import importlib.util
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit

SCRIPT = Path(__file__).with_name("claude-usage-capture.py")
SPEC = importlib.util.spec_from_file_location("capture", SCRIPT)
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)
SID = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
SECRET = "PRIVATE_PROMPT_KEY_HEADER_PATH"


def payload(sid=SID):
    attrs = {"event.name": "api_request", "session.id": sid, "model": "anthropic/claude-sonnet-5.5",
             "input_tokens": "48", "output_tokens": 22361, "cache_creation_tokens": "133967",
             "cache_read_tokens": 2318358, "cost_usd": "1.0222951", "cost_usd_micros": "1022295",
             "request_id": "req_test", "query_source": "repl_main_thread",
             "prompt": SECRET, "error": SECRET, "user.id": SECRET}
    return {"resourceLogs": [{"resource": {"attributes": [
        {"key": "service.version", "value": {"stringValue": "2.1.280"}},
        {"key": "private", "value": {"stringValue": SECRET}}]}, "scopeLogs": [{"logRecords": [{
        "body": {"stringValue": "claude_code.api_request"}, "timeUnixNano": "1791369190000000000",
        "attributes": [{"key": k, "value": {"stringValue" if isinstance(v, str) else "intValue": v}}
                       for k, v in attrs.items()]}]}]}]}


def post(endpoint, body, content_type="application/json"):
    url = urlsplit(endpoint)
    conn = http.client.HTTPConnection(url.hostname, url.port, timeout=3)
    try:
        conn.request("POST", url.path, body, {"Content-Type": content_type})
        response = conn.getresponse()
        response.read()
        return response.status
    finally:
        conn.close()


class CaptureTests(unittest.TestCase):
    def test_otlp_allowlist_and_numeric_types(self):
        event, = C.sanitize_otlp(payload())
        self.assertNotIn(SECRET, json.dumps(event))
        self.assertEqual(event["cost_usd"], 1.0222951)
        self.assertEqual(event["cost_usd_micros"], 1022295)
        self.assertEqual(event["time_unix_nano"], 1791369190000000000)
        self.assertEqual(event["service.version"], "2.1.280")
        self.assertEqual(event["session_id"], SID)
        self.assertNotIn("attempt", event)  # Missing is not zero.
        for value in (True, -1, float("nan"), float("inf"), 10 ** 400, "9" * 5000):
            self.assertIsNone(C.number(value))

    def test_raw_bodies_and_unrelated_events_are_dropped(self):
        value = payload()
        record = value["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]
        record["attributes"][0]["value"]["stringValue"] = "api_response_body"
        record["body"]["stringValue"] = SECRET
        self.assertEqual(C.sanitize_otlp(value), [])

    def test_loopback_http_rejects_wrong_transport_and_keeps_only_safe_fields(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            sink = C.Sink(root)
            server, endpoint = C.collector(sink, 0)
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                self.assertEqual(server.server_address[0], "127.0.0.1")
                self.assertEqual(post(endpoint, json.dumps(payload())), 200)
                self.assertEqual(post(endpoint, "invalid"), 400)
                self.assertEqual(post(endpoint, "{}", "application/x-protobuf"), 400)
                self.assertEqual(post(endpoint + "/wrong", "{}"), 404)
                events = (root / "events.jsonl").read_text()
                self.assertNotIn(SECRET, events)
                self.assertEqual((root / "events.jsonl").stat().st_mode & 0o777, 0o600)
                status = C.read_json(root / "collector-status.json")
                self.assertEqual(status["events"], {"api_request": 1})
                self.assertEqual(status["sessions"], {SID: 1})
                self.assertEqual(status["rejected_batches"], 2)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()

    def test_loopback_startup_does_not_resolve_dns(self):
        with tempfile.TemporaryDirectory() as temp, patch("socket.getfqdn", side_effect=AssertionError("DNS must not run")):
            server, endpoint = C.collector(C.Sink(Path(temp)), 0)
            try:
                self.assertEqual(server.server_name, "127.0.0.1")
                self.assertEqual(urlsplit(endpoint).port, server.server_port)
            finally:
                server.server_close()

    def test_external_launcher_cli_and_export(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            project = root / "projects" / SECRET
            project.mkdir(parents=True)
            usage = {"input_tokens": 48, "output_tokens": 22361, "cache_creation_input_tokens": 133967,
                     "cache_read_input_tokens": 2318358,
                     "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0},
                     "iterations": [], "private": SECRET}
            row = {"type": "assistant", "sessionId": SID, "requestId": "req_test", "costUSD": None,
                   "cwd": SECRET, "message": {"id": "msg_test", "model": "anthropic/claude-sonnet-5.5",
                                               "content": SECRET, "usage": usage}}
            (project / (SID + ".jsonl")).write_text(json.dumps(row) + "\n")
            related = project / SID / "subagents"
            related.mkdir(parents=True)
            (related / "agent-synthetic.jsonl").write_text(json.dumps({"type": "progress", "data": {"message": row}}) + "\n")
            (root / ".claude.json").write_text(json.dumps({"projects": {SECRET: {
                "lastSessionId": SID, "lastCost": 1.0222951, "lastModelUsage": {
                    "claude-sonnet-5-5": {"inputTokens": 48, "costUSD": 1.0222951, "secret": SECRET}}}}}))
            directory = root / "capture"
            args = argparse.Namespace(directory=directory, session_id=None, output=root / "report.json")
            process = subprocess.Popen([sys.executable, str(SCRIPT), "listen", "--port", "0",
                                        "--directory", str(directory), "--projects-directory", str(root / "projects")],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 5
                while not (directory / "latest.json").exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        self.fail("synthetic listener failed to start")
                    time.sleep(0.02)
                run_directory, _ = C.selected_run(args)
                settings = C.read_json(run_directory / "settings-env.json")["env"]
                self.assertEqual(settings["OTEL_LOG_RAW_API_BODIES"], "")
                self.assertEqual(settings["OTEL_METRICS_INCLUDE_SESSION_ID"], "true")
                self.assertFalse(any(k.startswith("ANTHROPIC_") for k in settings))
                self.assertEqual(post(settings["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"], json.dumps(payload())), 200)
                with self.assertRaises(ValueError):
                    C.export_report(args)
                process.send_signal(signal.SIGINT)
                out, err = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, err)
                self.assertIn("Сбор завершён", out)
                with patch.object(C.Path, "home", return_value=root), contextlib.redirect_stdout(io.StringIO()):
                    report = C.export_report(args)
                self.assertNotIn(SECRET, json.dumps(report))
                self.assertNotIn(str(root), json.dumps(report))
                self.assertEqual(report["session_id"], SID)
                self.assertEqual(report["claude_versions_observed"], ["2.1.280"])
                self.assertEqual(report["saved_totals"]["status"], "matching_session")
                self.assertEqual(report["correlation"]["telemetry_only_request_ids"], [])
                self.assertEqual(report["correlation"]["transcript_only_request_ids"], [])
                self.assertEqual([f["source"] for f in report["files"]], ["main", "related"])
                self.assertEqual(report["files"][0]["records"][0]["usage"]["cache_creation_input_tokens"], 133967)
                self.assertEqual(report["files"][1]["records"][0]["location"], "progress_message")
                self.assertEqual(args.output.stat().st_mode & 0o777, 0o600)
                # Additional sessions cannot be silently merged into this total.
                with (run_directory / "events.jsonl").open("a") as stream:
                    stream.write(json.dumps(C.sanitize_otlp(payload(OTHER))[0]) + "\n")
                with self.assertRaisesRegex(ValueError, "несколько сессий"):
                    C.export_report(args)
                args.session_id, args.output = SID, root / "selected.json"
                with patch.object(C.Path, "home", return_value=root), contextlib.redirect_stdout(io.StringIO()):
                    selected = C.export_report(args)
                self.assertEqual(selected["excluded_other_session_events"], 1)
                self.assertEqual(len(selected["telemetry"]), 1)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)

    def test_no_events_is_an_incomplete_capture_not_zero_spend(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            directory = root / "run"
            directory.mkdir()
            C.Sink(directory)
            C.private_json(root / "latest.json", {"run": "run"})
            C.private_json(directory / "run.json", {"started_at": C.utc_now(), "finished_at": C.utc_now(),
                "data_roots": [str(root / "projects")], "launch_method": "external_user_launcher",
                "effective_claude_environment": "not_inspected"})
            args = argparse.Namespace(directory=root, session_id=None, output=root / "report.json")
            text = io.StringIO()
            with patch.object(C.Path, "home", return_value=root), contextlib.redirect_stdout(text):
                report = C.export_report(args)
            self.assertIsNone(report["session_id"])
            self.assertEqual(report["saved_totals"]["status"], "not_found")
            self.assertNotIn("total_cost", report)
            self.assertIn("Сбор неполный", text.getvalue())


if __name__ == "__main__":
    unittest.main()
