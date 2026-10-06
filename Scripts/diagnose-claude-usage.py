#!/usr/bin/env python3
"""Local, aggregate-only diagnostics for LLM Usage issue #24.

Reads ccusage JSON into memory. The output is built from an explicit allowlist:
dates, versions, numeric counters/costs and comparison results. Raw CLI stdout,
stderr, session IDs, model names, project paths and configuration never go into
the output file. Optional --include-boundaries reads local JSONL structure using
the adjacent diagnostic script; only aggregate counters leave that scanner.
Does not modify the app/settings/logs.
ccusage may refresh its normal public pricing cache (--no-offline).
"""
import argparse
import datetime as dt
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

FIELDS = ("inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens",
          "totalTokens", "totalCost")
TOKEN_FIELDS = FIELDS[:-1]


def version(value):
    match = re.fullmatch(r"(?:ccusage\s+)?(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)", str(value).strip())
    return match.group(1) if match else None


def amounts(row):
    output = {}
    for key in FIELDS:
        value = row.get(key)
        if value is not None and (type(value) not in (int, float) or not math.isfinite(value) or value < 0):
            raise ValueError("invalid numeric field")
        output[key] = value
    return output


def combine(rows):
    return {key: sum(row[key] for row in rows) if all(row[key] is not None for row in rows) else None
            for key in FIELDS}


def difference(left, right):
    return {key: left[key] - right[key] if left[key] is not None and right[key] is not None else None
            for key in FIELDS}


def equivalent(left, right, fields=FIELDS):
    # Missing values are unknown, never silently converted to zero.
    for key in fields:
        if left[key] is None or right[key] is None:
            return False
        tolerance = 1e-8 if key == "totalCost" else 0
        if abs(left[key] - right[key]) > tolerance:
            return False
    return True


def run(executable, args):
    try:
        result = subprocess.run([executable] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=120, env=dict(os.environ, NO_COLOR="1"))
    except subprocess.TimeoutExpired:
        return None, {"status": "timeout"}
    except OSError:
        return None, {"status": "cannot_execute"}
    if result.returncode:
        return None, {"status": "cli_failed", "exit_code": result.returncode}
    return result.stdout, None


def report(executable, kind, mode, start, end, timezone):
    args = ["claude", kind, "--json", "--since", start.strftime("%Y%m%d"),
            "--until", end.strftime("%Y%m%d"), "--timezone", timezone,
            "--mode", mode, "--order", "desc", "--no-offline"]
    raw, error = run(executable, args)
    if error:
        return error, None
    try:
        payload = json.loads(raw)
        rows = payload["sessions" if kind == "session" else "daily"]
        if not isinstance(rows, list) or not isinstance(payload.get("totals"), dict):
            raise ValueError("unexpected schema")
        numeric_rows = [amounts(row) for row in rows]
        total = amounts(payload["totals"])
        row_sum = combine(numeric_rows)
        safe = {"status": "ok", "row_count": len(rows), "totals": total,
                "row_sum": row_sum, "totals_match_rows": equivalent(total, row_sum)}
        # Identities are used ONLY in memory to check per-session additivity.
        sessions = {}
        if kind == "session":
            for row, numeric in zip(rows, numeric_rows):
                identity = (row.get("projectPath"), row.get("sessionId"))
                if not all(value is None or isinstance(value, str) for value in identity) or identity[1] is None:
                    raise ValueError("missing identity")
                if identity in sessions:
                    raise ValueError("duplicate identity")
                sessions[identity] = numeric
        return safe, sessions
    except (ValueError, KeyError, TypeError, AttributeError, OverflowError):
        return {"status": "unsupported_or_invalid_json"}, None


def inspect_engine(executable, days, timezone, label):
    output = {"available": executable is not None}
    if executable is None:
        return output
    raw, error = run(executable, ["--version"])
    output["version"] = version(raw.decode("utf-8", "replace")) if raw is not None else None
    if error:
        output["version_check"] = error
        return output
    end = days[-1]
    cases = [("session_auto_" + day.isoformat(), "session", "auto", day, day) for day in days]
    cases += [("daily_auto_" + day.isoformat(), "daily", "auto", day, day) for day in days[:-1]]
    cases += [("session_auto_range", "session", "auto", days[0], end),
              ("session_calculate_selected", "session", "calculate", end, end),
              ("daily_auto_selected", "daily", "auto", end, end),
              ("daily_calculate_selected", "daily", "calculate", end, end),
              ("session_auto_selected_repeat", "session", "auto", end, end)]
    output["reports"] = {}
    internal_sessions = {}
    for index, (name, kind, mode, start, finish) in enumerate(cases, 1):
        print("%s: %d/%d" % (label, index, len(cases)), file=sys.stderr, flush=True)
        safe, sessions = report(executable, kind, mode, start, finish, timezone)
        output["reports"][name] = safe
        internal_sessions[name] = sessions
    reports = output["reports"]
    selected = "session_auto_" + end.isoformat()
    comparisons = {}
    for day in days:
        session_key = "session_auto_" + day.isoformat()
        daily_key = "daily_auto_selected" if day == end else "daily_auto_" + day.isoformat()
        if all(reports[key]["status"] == "ok" for key in (session_key, daily_key)):
            a, b = reports[session_key]["totals"], reports[daily_key]["totals"]
            comparisons["session_vs_daily_" + day.isoformat()] = {
                "tokens_equal": equivalent(a, b, TOKEN_FIELDS),
                "cost_equal": equivalent(a, b, ("totalCost",)),
                "session_minus_daily": difference(a, b),
            }
    for name, left, right in [
        ("selected_repeat", selected, "session_auto_selected_repeat"),
        ("session_auto_vs_calculate", selected, "session_calculate_selected"),
        ("session_vs_daily_auto", selected, "daily_auto_selected"),
        ("session_vs_daily_calculate", "session_calculate_selected", "daily_calculate_selected"),
    ]:
        if all(reports[key]["status"] == "ok" for key in (left, right)):
            a, b = reports[left]["totals"], reports[right]["totals"]
            comparisons[name] = {"tokens_equal": equivalent(a, b, TOKEN_FIELDS),
                                 "cost_equal": equivalent(a, b, ("totalCost",)),
                                 "left_minus_right": difference(a, b)}
    daily_names = ["session_auto_" + day.isoformat() for day in days]
    if all(reports[name]["status"] == "ok" for name in daily_names + ["session_auto_range"]):
        day_sum = combine([reports[name]["totals"] for name in daily_names])
        range_sum = reports["session_auto_range"]["totals"]
        by_session = {}
        occurrences = {}
        for name in daily_names:
            for identity, numeric in internal_sessions[name].items():
                by_session.setdefault(identity, []).append(numeric)
                occurrences[identity] = occurrences.get(identity, 0) + 1
        ranged = internal_sessions["session_auto_range"]
        overlap = by_session.keys() & ranged.keys()
        comparisons["three_days_vs_range"] = {
            "tokens_equal": equivalent(day_sum, range_sum, TOKEN_FIELDS),
            "cost_equal": equivalent(day_sum, range_sum, ("totalCost",)),
            "days_minus_range": difference(day_sum, range_sum),
            "sessions_seen_on_multiple_days": sum(n > 1 for n in occurrences.values()),
            "sessions_only_in_days": len(by_session.keys() - ranged.keys()),
            "sessions_only_in_range": len(ranged.keys() - by_session.keys()),
            "sessions_with_token_mismatch": sum(not equivalent(combine(by_session[key]), ranged[key], TOKEN_FIELDS) for key in overlap),
            "sessions_with_cost_mismatch": sum(not equivalent(combine(by_session[key]), ranged[key], ("totalCost",)) for key in overlap),
        }
    output["comparisons"] = comparisons
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--date", required=True, help="Completed day with incorrect app totals, YYYY-MM-DD")
    parser.add_argument("--timezone", default="UTC", help="Exactly the timezone selected in the app")
    parser.add_argument("--cli", default="ccusage", help="Installed ccusage command or absolute executable path")
    parser.add_argument("--app", help="Installed LLM Usage.app path, if outside /Applications or ~/Applications")
    parser.add_argument("--expect-engine-version", help="Require this bundled helper version before querying usage")
    parser.add_argument("--expect-app-version", help="Require this app version and a bundled helper before running any queries")
    parser.add_argument("--include-boundaries", action="store_true", help="Also include aggregate local response-boundary counters")
    parser.add_argument("--output", default="llm-usage-diagnostics.json")
    args = parser.parse_args()
    end = dt.date.fromisoformat(args.date)
    if not re.fullmatch(r"[A-Za-z0-9_+./-]{1,80}", args.timezone):
        raise ValueError("invalid timezone")
    days = [end - dt.timedelta(days=n) for n in (2, 1, 0)]
    candidates = [Path(args.app).expanduser()] if args.app else [Path("/Applications/LLM Usage.app"), Path.home() / "Applications/LLM Usage.app"]
    app = next((path for path in candidates if path.is_dir()), None)
    bundled = app / "Contents/Helpers/ccusage" if app else None
    app_version = None
    if app:
        try:
            with (app / "Contents/Info.plist").open("rb") as stream:
                app_version = version(plistlib.load(stream).get("CFBundleShortVersionString"))
        except (OSError, ValueError, plistlib.InvalidFileException):
            pass
    if args.expect_app_version and (app_version != args.expect_app_version or not bundled or not bundled.is_file()):
        print("Expected app version/bundled helper was not found. Check --app. No usage queries were run.", file=sys.stderr)
        raise SystemExit(2)
    if args.expect_engine_version:
        raw, error = run(str(bundled), ["--version"]) if bundled and bundled.is_file() else (None, "missing")
        if error or raw is None or version(raw.decode("utf-8", "replace")) != args.expect_engine_version:
            print("Expected bundled engine was not found. No usage queries were run.", file=sys.stderr)
            return 2
    result = {
        "schema": 4,
        "selected_date": end.isoformat(), "days": [day.isoformat() for day in days],
        "timezone": args.timezone, "app_version": app_version,
        "pricing": "no-offline; normal CLI config; app-generated pricing overrides are not reproduced",
        "environment_flags": {key + "_set": bool(os.environ.get(key)) for key in
                              ("CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME")},
        "engines": {},
    }
    result["engines"]["installed"] = inspect_engine(shutil.which(args.cli), days, args.timezone, "installed")
    result["engines"]["bundled"] = inspect_engine(str(bundled) if bundled and bundled.is_file() else None,
                                                   days, args.timezone, "bundled")
    if args.include_boundaries:
        spec = importlib.util.spec_from_file_location("claude_boundaries", Path(__file__).with_name("diagnose-claude-boundaries.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        result["response_boundaries"] = module.inspect_boundaries(args.date, args.timezone)
    # Exclusive creation avoids overwriting any existing file or following a symlink.
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write("\n")
    print("Done. The output contains only allowlisted aggregate diagnostics.")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Cancelled. No raw CLI output was saved.", file=sys.stderr)
        sys.exit(130)
    except FileExistsError:
        print("Output already exists. Choose a new --output filename.", file=sys.stderr)
        sys.exit(1)
    except Exception:
        # Exceptions may contain private paths or raw decoder input: never print them.
        print("Diagnostics could not finish. Check Python 3.9+, arguments and file permissions; no raw CLI output was saved.", file=sys.stderr)
        sys.exit(1)
