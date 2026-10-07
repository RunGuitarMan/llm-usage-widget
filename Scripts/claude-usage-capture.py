#!/usr/bin/env python3
"""Local, allowlisted Claude accounting capture. Python 3.9+, no dependencies.

listen: receive OTLP/HTTP JSON on loopback; launch Claude yourself, by any method.
status: check whether real API events arrived (a listening port is insufficient).
export: combine the saved numeric events with that session's transcript metadata.
No prompt/response bodies, tool payloads, HTTP headers or account IDs are saved.
"""
import argparse
from collections import Counter
import datetime as dt
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import re
import secrets
from socketserver import TCPServer
import threading
import time
import uuid

SCHEMA = 1
MAX_BODY = 16 * 1024 * 1024
TOKEN_KEYS = ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
MODEL_KEYS = ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens", "costUSD", "webSearchRequests")
EVENT_NUMBERS = ("event.sequence", "input_tokens", "output_tokens", "cache_read_tokens",
                 "cache_creation_tokens", "cost_usd", "cost_usd_micros", "duration_ms", "attempt", "status_code")
EVENT_STRINGS = ("request_id", "client_request_id", "model", "query_source", "speed", "event.timestamp", "app.version")
KINDS = {"assistant", "user", "system", "progress", "result", "summary", "attachment",
         "file-history-snapshot", "queue-operation"}


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def obj(value):
    return value if isinstance(value, dict) else {}


def number(value):
    if isinstance(value, str) and len(value) < 100 and re.fullmatch(r"\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", value):
        value = float(value) if any(c in value for c in ".eE") else int(value)
    if type(value) is int:
        return value if 0 <= value < 10 ** 100 else None
    return value if type(value) is float and math.isfinite(value) and value >= 0 else None


def numeric_fields(value, keys):
    value = obj(value)
    return {k: number(value[k]) for k in keys if k in value}


def label(value):
    return value if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.:/@+\[\] -]{1,180}", value) else None


def session_id(value):
    try:
        return str(uuid.UUID(value)) if isinstance(value, str) else None
    except ValueError:
        return None


def private_json(path, value, replace=False):
    temporary = path.with_name(path.name + ".tmp-" + secrets.token_hex(4)) if replace else path
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write("\n")
    if replace:
        os.replace(temporary, path)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def any_value(value):
    value = obj(value)
    for key in ("stringValue", "intValue", "doubleValue", "boolValue"):
        if key in value:
            return value[key]
    return None


def attributes(items):
    return {item["key"]: any_value(item.get("value")) for item in items
            if isinstance(item, dict) and isinstance(item.get("key"), str)} if isinstance(items, list) else {}


def sanitize_otlp(payload):
    output = []
    resources = obj(payload).get("resourceLogs", [])
    if not isinstance(resources, list):
        raise ValueError("invalid OTLP envelope")
    for resource in resources:
        resource_attrs = attributes(obj(obj(resource).get("resource")).get("attributes"))
        scopes = obj(resource).get("scopeLogs", [])
        if not isinstance(scopes, list):
            continue
        for scope in scopes:
            records = obj(scope).get("logRecords", [])
            if not isinstance(records, list):
                continue
            for record in records:
                record = obj(record)
                attrs = attributes(record.get("attributes"))
                event = attrs.get("event.name") or any_value(record.get("body"))
                if not isinstance(event, str):
                    continue
                event = event.removeprefix("claude_code.")
                if event not in {"api_request", "api_error", "user_prompt"}:
                    continue
                clean = {"event": event}
                release = resource_attrs.get("service.version")
                if isinstance(release, str) and re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", release):
                    clean["service.version"] = release
                sid = session_id(attrs.get("session.id") or attrs.get("session_id"))
                if sid:
                    clean["session_id"] = sid
                clean.update(numeric_fields(attrs, EVENT_NUMBERS))
                for key in EVENT_STRINGS:
                    if label(attrs.get(key)) is not None:
                        clean[key] = attrs[key]
                if number(record.get("timeUnixNano")) is not None:
                    clean["time_unix_nano"] = number(record["timeUnixNano"])
                output.append(clean)
    return output


class Sink:
    def __init__(self, directory):
        self.directory = directory
        self.lock = threading.Lock()
        self.accepted_batches = 0
        self.rejected_batches = 0
        self.event_counts = Counter()
        self.sessions = Counter()
        self.write_status()

    def write_status(self):
        private_json(self.directory / "collector-status.json", {
            "accepted_batches": self.accepted_batches, "rejected_batches": self.rejected_batches,
            "events": dict(self.event_counts), "sessions": dict(self.sessions), "updated_at": utc_now()}, replace=True)

    def accept(self, payload):
        events = sanitize_otlp(payload)
        with self.lock:
            descriptor = os.open(self.directory / "events.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                for event in events:
                    stream.write(json.dumps(event, ensure_ascii=False, allow_nan=False) + "\n")
                    self.event_counts[event["event"]] += 1
                    if event.get("session_id") and event["event"] == "api_request":
                        self.sessions[event["session_id"]] += 1
            self.accepted_batches += 1
            self.write_status()

    def reject(self):
        with self.lock:
            self.rejected_batches += 1
            self.write_status()


def collector(sink, port=4318):
    route = "/v1/logs"

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # Never log headers, paths, bodies or raw exceptions.

        def do_POST(self):
            if self.path != route:
                self.send_error(404)
                return
            self.connection.settimeout(10)
            try:
                length = int(self.headers.get("Content-Length", "-1"))
                if not 0 <= length <= MAX_BODY or self.headers.get("Content-Encoding", "identity") != "identity":
                    raise ValueError("unsupported transport")
                if self.headers.get_content_type() != "application/json":
                    raise ValueError("expected OTLP JSON")
                raw = self.rfile.read(length)
                if len(raw) != length:
                    raise ValueError("truncated body")
                sink.accept(json.loads(raw))
            except (ValueError, OSError, RecursionError):
                sink.reject()
                self.send_error(400)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")

    class Server(ThreadingHTTPServer):
        daemon_threads = True

        def server_bind(self):
            # HTTPServer.server_bind performs reverse DNS through getfqdn().
            # A fixed loopback collector must start without a DNS dependency.
            TCPServer.server_bind(self)
            self.server_name, self.server_port = self.server_address[:2]

        def handle_error(self, *_):
            sink.reject()

    server = Server(("127.0.0.1", port), Handler)
    return server, "http://127.0.0.1:%d%s" % (server.server_port, route)


def settings_env(endpoint):
    # This is a snippet to merge manually, never a replacement for settings.json.
    return {"CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_LOGS_EXPORTER": "otlp",
                "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
                "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": endpoint,
                "OTEL_LOGS_EXPORT_INTERVAL": "1000", "OTEL_METRICS_EXPORTER": "none",
                "OTEL_TRACES_EXPORTER": "none", "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "0",
                "ENABLE_ENHANCED_TELEMETRY_BETA": "0",
                "OTEL_METRICS_INCLUDE_SESSION_ID": "true", "OTEL_METRICS_INCLUDE_VERSION": "true",
                "OTEL_LOG_USER_PROMPTS": "0", "OTEL_LOG_ASSISTANT_RESPONSES": "0",
                "OTEL_LOG_TOOL_DETAILS": "0", "OTEL_LOG_TOOL_CONTENT": "0",
                "OTEL_LOG_RAW_API_BODIES": ""}


def data_roots(home, environment):
    configured = environment.get("CLAUDE_CONFIG_DIR")
    if configured:
        paths = [Path(p.strip()).expanduser() for p in configured.split(",") if p.strip()]
    else:
        paths = [home / ".claude", Path(environment.get("XDG_CONFIG_HOME", str(home / ".config"))) / "claude"]
    return [str((p if p.name == "projects" else p / "projects").resolve()) for p in paths]


def listen(args):
    args.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory = args.directory / (dt.datetime.now().strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(4))
    directory.mkdir(mode=0o700)
    run = {"schema": SCHEMA, "started_at": utc_now(), "finished_at": None,
           "data_roots": [str(args.projects_directory.expanduser().resolve())] if args.projects_directory
                         else data_roots(Path.home(), os.environ),
           "launch_method": "external_user_launcher", "effective_claude_environment": "not_inspected"}
    sink = Sink(directory)
    server, endpoint = collector(sink, args.port)
    private_json(directory / "run.json", run)
    private_json(directory / "settings-env.json", {"env": settings_env(endpoint)})
    private_json(args.directory / "latest.json", {"run": directory.name}, replace=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    print("Локальный приёмник готов:", endpoint, flush=True)
    print("Блок env для settings.json (объедините с существующим env):", flush=True)
    print(json.dumps({"env": settings_env(endpoint)}, indent=2), flush=True)
    print("Запустите НОВУЮ сессию Claude своим обычным способом на этом компьютере.", flush=True)
    print("После первого ответа проверьте status в другом терминале.", flush=True)
    print("В конце: сохраните /usage → /exit → подождите 5 секунд → Ctrl+C здесь.", flush=True)
    print("Не используйте /clear или /resume; собирайте одну сессию за раз.", flush=True)
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        run["finished_at"] = utc_now()
        private_json(directory / "run.json", run, replace=True)
    requests = sink.event_counts["api_request"]
    print("Сбор завершён. Сохранено API-событий:", requests)
    if not requests:
        print("Телеметрия API НЕ получена. Это не означает нулевой расход; отправьте экспорт с этим статусом.")
    print("Теперь выполните этот скрипт с командой export.")


def selected_run(args):
    name = read_json(args.directory / "latest.json").get("run")
    if not isinstance(name, str) or Path(name).name != name:
        raise ValueError("Некорректный указатель последнего сбора.")
    directory = args.directory / name
    return directory, read_json(directory / "run.json")


def show_status(args):
    directory, run = selected_run(args)
    status = read_json(directory / "collector-status.json")
    print("Сессии (ID: число API-событий):", json.dumps(status.get("sessions", {})))
    print("API-событий:", status.get("events", {}).get("api_request", 0))
    print("Ошибок API:", status.get("events", {}).get("api_error", 0))
    print("Отвергнутых пакетов:", status.get("rejected_batches", 0))
    print("Сбор завершён:" if run.get("finished_at") else "Сбор начат:", run.get("finished_at") or run["started_at"])
    if not status.get("events", {}).get("api_request"):
        print("После первого ответа подождите 5 секунд. Если API-событий всё ещё 0 — остановитесь и пришлите этот вывод.")


def usage_fields(value):
    result = numeric_fields(value, TOKEN_KEYS)
    value = obj(value)
    if "cache_creation" in value:
        result["cache_creation"] = numeric_fields(value["cache_creation"],
            ("ephemeral_5m_input_tokens", "ephemeral_1h_input_tokens")) if isinstance(value["cache_creation"], dict) else None
    if value.get("speed") in ("standard", "fast"):
        result["speed"] = value["speed"]
    if isinstance(value.get("iterations"), list):
        result["iterations"] = [numeric_fields(item, TOKEN_KEYS) for item in value["iterations"] if isinstance(item, dict)]
    return result


def model_fields(value):
    return {key: numeric_fields(item, MODEL_KEYS) for key, item in obj(value).items()
            if label(key) is not None and isinstance(item, dict)}


def transcript_file(path, source):
    output = {"source": source, "records": []}
    counts = Counter()
    try:
        with path.open(encoding="utf-8") as stream:
            for index, line in enumerate(stream, 1):
                if not line.strip():
                    continue
                counts["lines"] += 1
                try:
                    row = obj(json.loads(line))
                except (ValueError, RecursionError):
                    counts["invalid_json_lines"] += 1
                    continue
                kind = row.get("type")
                kind = kind if isinstance(kind, str) and kind in KINDS else "other"
                candidates = [("root", row)]
                nested = obj(obj(row.get("data")).get("message"))
                if kind == "progress" and nested:
                    candidates.append(("progress_message", nested))
                for location, record in candidates:
                    message = obj(record.get("message"))
                    if not any(isinstance(v, dict) for v in
                               (message.get("usage"), record.get("usage"), record.get("modelUsage"))) \
                            and not numeric_fields(record, ("costUSD", "total_cost_usd")):
                        continue
                    item = {"line": index, "location": location, "type": kind}
                    for key in ("timestamp", "uuid", "parentUuid", "requestId", "sessionId"):
                        if label(record.get(key)) is not None:
                            item[key] = record[key]
                    if type(record.get("isSidechain")) is bool:
                        item["isSidechain"] = record["isSidechain"]
                    for key, target in (("id", "messageId"), ("model", "model")):
                        if label(message.get(key)) is not None:
                            item[target] = message[key]
                    for container, target in ((message, "usage"), (record, "root_usage")):
                        if isinstance(container.get("usage"), dict):
                            item[target] = usage_fields(container["usage"])
                    if isinstance(record.get("modelUsage"), dict):
                        item["modelUsage"] = model_fields(record["modelUsage"])
                    item.update(numeric_fields(record, ("costUSD", "total_cost_usd")))
                    output["records"].append(item)
    except (OSError, UnicodeError):
        output["read_error"] = True
    output["counts"] = dict(counts)
    return output


def saved_totals(home, sessions):
    path = home / ".claude.json"
    if not path.is_file():
        return {"status": "not_found", "sessions": []}
    try:
        state = read_json(path)
        results = []
        for item in obj(obj(state).get("projects")).values():
            item = obj(item)
            if session_id(item.get("lastSessionId")) not in sessions:
                continue
            result = numeric_fields(item, ("lastCost", "lastTotalInputTokens", "lastTotalOutputTokens",
                "lastTotalCacheCreationInputTokens", "lastTotalCacheReadInputTokens"))
            result["session_id"] = item["lastSessionId"]
            if isinstance(item.get("lastModelUsage"), dict):
                result["lastModelUsage"] = model_fields(item["lastModelUsage"])
            results.append(result)
        return {"status": "matching_session" if results else "no_matching_session", "sessions": results}
    except (ValueError, OSError, UnicodeError):
        return {"status": "unreadable", "sessions": []}


def export_report(args):
    directory, run = selected_run(args)
    if not run.get("finished_at"):
        raise ValueError("Сначала завершите Claude: /exit → подождите 5 секунд → Ctrl+C в окне приёмника.")
    events_path = directory / "events.jsonl"
    all_events = [json.loads(line) for line in events_path.read_text().splitlines() if line.strip()] if events_path.is_file() else []
    available = {e["session_id"] for e in all_events if session_id(e.get("session_id"))}
    selected = session_id(args.session_id)
    if args.session_id and not selected:
        raise ValueError("Параметр --session-id должен быть UUID сессии Claude.")
    if not selected and len(available) > 1:
        raise ValueError("Получено несколько сессий. Повторите export --session-id UUID, выбрав нужную: "
                         + ", ".join(sorted(available)))
    selected = selected or next(iter(available), None)
    sessions = {selected} if selected else set()
    events = [e for e in all_events if e.get("session_id") == selected and selected]
    unattributed = [e for e in all_events if not e.get("session_id")]
    files, seen = [], set()
    for root in run["data_roots"]:
        for sid in sorted(sessions):
            for main in sorted(Path(root).glob("*/" + sid + ".jsonl")):
                candidates = [main] + sorted(main.with_suffix("").rglob("*.jsonl"))
                for path in candidates:
                    if path.is_symlink() or path.resolve() in seen:
                        continue
                    seen.add(path.resolve())
                    files.append(transcript_file(path, "main" if path == main else "related"))
    requests = [e for e in events if e.get("event") == "api_request"]
    telemetry_ids = {e["request_id"] for e in requests if e.get("request_id")}
    transcript_ids = {r["requestId"] for f in files for r in f["records"] if r.get("requestId")}
    report = {"schema": SCHEMA, "session_id": selected, "started_at": run["started_at"],
              "finished_at": run["finished_at"], "launch_method": run["launch_method"],
              "effective_claude_environment": run["effective_claude_environment"],
              "available_sessions": sorted(available),
              "claude_versions_observed": sorted({e[k] for e in events for k in ("app.version", "service.version") if k in e}),
              "ttl_status": "not_proven_by_standard_api_events",
              "collector": read_json(directory / "collector-status.json"), "telemetry": events,
              "unattributed_telemetry": unattributed,
              "excluded_other_session_events": len(all_events) - len(events) - len(unattributed),
              "files": files, "saved_totals": saved_totals(Path.home(), sessions),
              "correlation": {"api_event_count": len(requests), "unique_api_request_ids": len(telemetry_ids),
                  "api_events_without_request_id": sum(not e.get("request_id") for e in requests),
                  "unique_transcript_request_ids": len(transcript_ids),
                  "telemetry_only_request_ids": sorted(telemetry_ids - transcript_ids),
                  "transcript_only_request_ids": sorted(transcript_ids - telemetry_ids)},
              "limitations": ["Transcript and telemetry counters may have different scopes.",
                              "A missing telemetry event is not proof that a request did not occur.",
                              "No raw API bodies or effective gateway TTL were captured."]}
    output = args.output or Path.home() / "Desktop" / ("claude-usage-capture-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(2) + ".json")
    private_json(output, report)
    print("Готово. Пришлите файл:", output)
    print("API-событий:", len(requests), "Файлов сессии:", len(files))
    if not requests or not files:
        print("Сбор неполный; отсутствие данных отмечено в отчёте, а не заменено нулевым расходом.")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("listen", "status", "export"))
    parser.add_argument("--directory", type=Path, default=Path.home() / "Desktop/ClaudeUsageCapture")
    parser.add_argument("--port", type=int, default=4318, help="Loopback port for listen (default 4318)")
    parser.add_argument("--projects-directory", type=Path, help="Optional transcript projects directory for listen")
    parser.add_argument("--session-id", help="For export: required only if multiple sessions were received")
    parser.add_argument("--output", type=Path, help="Optional report path for export; existing files are never overwritten")
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("--port must be between 0 and 65535")
    {"listen": listen, "status": show_status, "export": export_report}[args.command](args)


if __name__ == "__main__":
    try:
        main()
    except FileNotFoundError:
        print("Данные сбора не найдены. Сначала выполните listen на этом компьютере.")
        raise SystemExit(1)
    except ValueError as error:
        # Only controlled CLI errors should reach here; do not print JSON parser input.
        print(str(error) if not isinstance(error, json.JSONDecodeError) else "Не удалось прочитать данные сбора.")
        raise SystemExit(1)
    except (OSError, UnicodeError):
        print("Не удалось завершить сбор: проверьте доступ к рабочему столу и локальному порту.")
        raise SystemExit(1)
