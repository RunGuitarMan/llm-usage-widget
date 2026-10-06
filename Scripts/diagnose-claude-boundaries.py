#!/usr/bin/env python3
"""Explain why the issue-24 patch does not recognize local Claude fragments.

Python 3.9+; standard library; no network or subprocesses. Reads JSONL locally
without modifying it. Exports aggregate counters only: no content, IDs, hashes,
models, paths, exact timestamps, per-response records or raw error messages.
"""
import argparse
from collections import Counter, defaultdict
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import sys
from zoneinfo import ZoneInfo

IGNORED = {"progress", "file-history-snapshot", "queue-operation"}
STOP_REASONS = {"end_turn", "tool_use", "max_tokens", "stop_sequence", "pause_turn", "refusal"}
KINDS = {"assistant", "user", "system", "progress", "file-history-snapshot", "queue-operation",
         "attachment", "summary", "last-prompt", "custom-title", "agent-name", "agent-color",
         "tag", "mode", "pr-link", "saved_hook_context"}
BLOCK_KINDS = {"text", "thinking", "redacted_thinking", "tool_use", "server_tool_use",
               "tool_result", "image", "document", "search_result"}
ATTACHMENT_KINDS = {"file", "directory", "selected_lines", "mcp_resource", "diagnostics",
                    "queued_command", "task_progress", "task_notification", "todo",
                    "hook_success", "hook_additional_context", "plan_mode", "exit_plan_mode"}
TOKEN_KEYS = ("inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens")


def nonempty(value):
    return value if isinstance(value, str) and value else None


def bucket(value, allowed):
    if value is None:
        return "missing_or_null"
    return value if isinstance(value, str) and value in allowed else "other"


def integer(value):
    return type(value) is int and 0 <= value <= 18446744073709551615


def fingerprint(value):
    # Used only for local equality comparisons. No digest is ever exported.
    if value is None:
        return None
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).digest()


def content_metadata(row):
    message = row.get("message")
    message = message if isinstance(message, dict) else {}
    content = message.get("content")
    blocks = content if isinstance(content, list) else []
    uses, results, types = {}, [], Counter()
    for block in blocks:
        if not isinstance(block, dict):
            types["non_object"] += 1
            continue
        kind = bucket(block.get("type"), BLOCK_KINDS)
        types[kind] += 1
        if kind in {"tool_use", "server_tool_use"} and nonempty(block.get("id")):
            uses[block["id"]] = fingerprint(block)
        if kind == "tool_result" and nonempty(block.get("tool_use_id")):
            results.append(block["tool_use_id"])
    if isinstance(content, str):
        types["string"] += 1
    attachment = row.get("attachment")
    attachment_type = bucket(attachment.get("type"), ATTACHMENT_KINDS) if isinstance(attachment, dict) else "missing_or_null"
    return dict(content_fingerprint=fingerprint(content), payload_fingerprint=fingerprint(message or None),
                tool_uses=uses, tool_results=results, content_types=dict(types), attachment_type=attachment_type)


def equality(a, b):
    return "unavailable" if a is None or b is None else "equal" if a == b else "different"


def strict_block_ids(row, kind, key):
    message = row.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list) or not content:
        return None
    if not all(isinstance(block, dict) and block.get("type") == kind and nonempty(block.get(key)) for block in content):
        return None
    return {block[key] for block in content}


def remainder_context(a, b, timeline):
    """Return only allowlisted labels and aggregate counts, never private metadata."""
    start, finish = a["index"][1], b["index"][1]
    gap = timeline[start + 1:finish]
    left, right = set(a["tool_uses"]), set(b["tool_uses"])
    relation = ("neither" if not left and not right else "only_current" if not left else
                "only_previous" if not right else "identical" if left == right else
                "overlap" if left & right else "disjoint")
    owners = Counter()
    for record in gap:
        for identity in record.get("tool_results", []):
            owner = record["result_owners"].get(identity)
            label = ("previous_fragment" if identity in left else "current_fragment" if identity in right else
                     "not_seen" if owner is None else "earlier_fragment_of_same_message"
                     if owner == (b["session"], b["message"]) else "other_response")
            owners[label] += 1
    chain, cursor = Counter(), b["parent_index"]
    while cursor is not None and start < cursor < finish:
        record = timeline[cursor]
        chain[record["category"]] += 1
        cursor = record["parent_index"]
    chain_result = ("reaches_previous_fragment" if cursor == start else
                    "bypasses_previous_fragment" if cursor is not None else "unresolved")
    return {
        "content_equality": {equality(a["content_fingerprint"], b["content_fingerprint"]): 1},
        "message_payload_equality": {equality(a["payload_fingerprint"], b["payload_fingerprint"]): 1},
        "previous_content_types": a["content_types"], "current_content_types": b["content_types"],
        "tool_id_relationship": {relation: 1},
        "shared_tool_payloads": dict(Counter(equality(a["tool_uses"][key], b["tool_uses"][key]) for key in left & right)),
        "intervening_tool_result_ownership": dict(owners),
        "parent_chain": {chain_result: 1}, "parent_chain_records": dict(chain),
        "intervening_attachment_types": dict(Counter(r["attachment_type"] for r in gap if r["category"] == "attachment")),
    }


def metadata(row, file_number, ordinal):
    message = row.get("message")
    values = message if isinstance(message, dict) else {}
    usage = values.get("usage")
    usage = usage if isinstance(usage, dict) else None
    valid = all(row.get(k) is None or isinstance(row[k], str)
                for k in ("type", "uuid", "parentUuid", "sessionId", "requestId"))
    valid &= row.get("isSidechain") is None or type(row["isSidechain"]) is bool
    valid &= message is None or isinstance(message, dict)
    valid &= all(values.get(k) is None or isinstance(values[k], str) for k in ("id", "model"))
    tokens = None
    if values.get("usage") is not None:
        valid &= usage is not None
    if usage is not None:
        fields = (usage.get("input_tokens"), usage.get("output_tokens"),
                  usage.get("cache_creation_input_tokens", 0), usage.get("cache_read_input_tokens", 0))
        usage_valid = all(integer(v) for v in fields)
        speed = usage.get("speed")
        usage_valid &= speed is None or type(speed) is str and speed in {"standard", "fast"}
        cache = usage.get("cache_creation")
        if cache is not None:
            usage_valid &= isinstance(cache, dict)
            if isinstance(cache, dict):
                ephemeral = (cache.get("ephemeral_5m_input_tokens", 0), cache.get("ephemeral_1h_input_tokens", 0))
                usage_valid &= all(integer(v) for v in ephemeral)
                if usage_valid:
                    fields = (fields[0], fields[1], min(sum(ephemeral), 18446744073709551615), fields[3])
        valid &= usage_valid
        if usage_valid:
            tokens = fields
    # These private fields stay in memory and are never serialized.
    return dict(index=(file_number, ordinal), valid=bool(valid), kind=row.get("type"),
                uuid=row.get("uuid"), parent=row.get("parentUuid"), session=row.get("sessionId"),
                request=row.get("requestId"), sidechain=row.get("isSidechain"),
                message=values.get("id"), model=values.get("model"), stop=values.get("stop_reason"),
                stop_field_present="stop_reason" in values, tokens=tokens,
                speed=usage.get("speed") if usage else None)


def failure_reasons(a, b):
    reasons = []
    def require(condition, name):
        if not condition:
            reasons.append(name)
    require(a["valid"] and b["valid"], "typed_parser_rejected")
    require(a["index"][0] == b["index"][0], "different_files")
    require(b["patch_previous"] == a["index"], "not_previous_assistant_in_patch")
    require(a["kind"] == "assistant" and b["kind"] == "assistant", "type_not_assistant")
    require(a["request"] is None and b["request"] is None, "request_id_present")
    require(nonempty(a["uuid"]) is not None, "previous_uuid_missing")
    require(nonempty(b["uuid"]) is not None, "current_uuid_missing")
    parent = b["patch_tail"] if b["patch_crossed_tool_result"] else a["uuid"]
    require(nonempty(parent) is not None and parent == b["parent"], "parent_not_previous_uuid")
    require(a["session"] == b["session"], "session_changed")
    require(a["sidechain"] == b["sidechain"], "sidechain_field_changed")
    require(a["model"] == b["model"], "model_changed")
    if a["tokens"] is None or b["tokens"] is None:
        reasons.append("usage_not_accepted_by_patch")
    else:
        require(all(a["tokens"][n] == b["tokens"][n] for n in (0, 2, 3)), "input_or_cache_changed")
        require(a["tokens"][1] <= b["tokens"][1], "output_decreased")
    require(a["speed"] == b["speed"], "speed_changed")
    if b["patch_crossed_tool_result"]:
        require(a["tokens"] is not None and b["tokens"] is not None and a["tokens"][1] == b["tokens"][1],
                "output_changed_after_tool_result")
        require(a["patch_tools"] is not None and b["patch_tools"] is not None and a["patch_tools"].isdisjoint(b["patch_tools"]),
                "not_distinct_tool_fragments")
    return reasons


def summarize(rows):
    groups = defaultdict(list)
    for row in rows:
        if row["request"] is None and row["sidechain"] is not True and nonempty(row["message"]):
            groups[(row["group_session"], row["message"])].append(row)
    repeated = [group for group in groups.values() if len({r["at"] for r in group}) > 1]
    failures, combinations, relationships, previous_stops, kinds, separators = [Counter() for _ in range(6)]
    eligible = pairs = v1_stop_only = bridged = 0
    remaining_context = defaultdict(Counter)
    remaining_tokens = Counter()
    for group in repeated:
        # Preserve on-disk order; the patch processes files in that order.
        group.sort(key=lambda r: r["index"])
        for a, b in zip(group, group[1:]):
            if a["at"] == b["at"]:
                continue
            pairs += 1
            reasons = failure_reasons(a, b)
            failures.update(reasons)
            combinations[" + ".join(reasons) if reasons else "all_rules_pass"] += 1
            eligible += not reasons
            v1_stop_only += not reasons and a["stop"] is not None and not b["patch_crossed_tool_result"]
            bridged += not reasons and b["patch_crossed_tool_result"]
            if reasons:
                for name, counts in b.get("pair_context", {}).items():
                    remaining_context[name].update(counts)
                if a["tokens"] is not None:
                    remaining_tokens.update(dict(zip(TOKEN_KEYS, a["tokens"])))
            previous_stops[bucket(a["stop"], STOP_REASONS)] += 1
            kinds[bucket(a["kind"], KINDS) + " -> " + bucket(b["kind"], KINDS)] += 1
            if nonempty(a["uuid"]) and a["uuid"] == b["parent"]:
                relation = "direct_chain"
            elif nonempty(a["parent"]) and a["parent"] == b["parent"]:
                relation = "shared_parent"
            elif not nonempty(b["parent"]):
                relation = "current_parent_missing"
            else:
                relation = "other_relationship"
            relationships[relation] += 1
            if b["patch_previous"] != a["index"]:
                separator = ("different_file" if a["index"][0] != b["index"][0] else
                             "another_assistant" if b["patch_previous"] is not None else b["last_reset"])
                separators[separator] += 1
    return {"direct_usage_records": len(rows), "requestless_repeated_message_groups": len(repeated),
            "pairs_at_different_timestamps": pairs, "pairs_accepted_by_current_patch": eligible,
            "pairs_previously_blocked_only_by_stop_reason": v1_stop_only,
            "pairs_joined_across_owned_tool_results": bridged,
            "failed_conditions": dict(sorted(failures.items())),
            "failure_combinations": dict(sorted(combinations.items())),
            "parent_relationships": dict(sorted(relationships.items())),
            "previous_stop_reasons": dict(sorted(previous_stops.items())),
            "record_type_pairs": dict(sorted(kinds.items())),
            "last_reset_for_nonadjacent_pairs": dict(sorted(separators.items())),
            "unmerged_pair_previous_tokens": dict(remaining_tokens),
            "remaining_pair_context": {key: dict(sorted(value.items())) for key, value in sorted(remaining_context.items())}}


def record_kind(row):
    """Only fixed labels escape this function, never user-defined type values."""
    kind = bucket(row.get("type"), KINDS)
    if kind != "user":
        return kind
    message = row.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, list) and content:
        tools = [isinstance(block, dict) and block.get("type") == "tool_result" for block in content]
        if all(tools):
            return "user_tool_result"
        if any(tools):
            return "user_mixed_tool_result"
    return "user_without_tool_result"


def inspect_boundaries(date, timezone, claude_dirs=None):
    end = dt.date.fromisoformat(date)
    zone = ZoneInfo(timezone)
    days = [(end - dt.timedelta(days=n)).isoformat() for n in (2, 1, 0)]
    if claude_dirs:
        roots = [Path(p).expanduser() for p in claude_dirs]
    elif os.environ.get("CLAUDE_CONFIG_DIR"):
        roots = [Path(p.strip()).expanduser() for p in os.environ["CLAUDE_CONFIG_DIR"].split(",") if p.strip()]
    else:
        roots = [Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "claude", Path.home() / ".claude"]
    projects = {p.resolve() if p.name == "projects" else (p / "projects").resolve() for p in roots}
    files = sorted({p for root in projects if root.is_dir() for p in root.rglob("*.jsonl") if p.is_file()})
    if not files:
        return {"status": "no_jsonl_files"}
    per_day = {day: [] for day in days}
    scan = Counter()
    for number, path in enumerate(files):
        previous = None
        tail, crossed = None, False
        last_reset = "start_of_file"
        timeline, seen_uuids, last_in_group, tool_owners = [], {}, {}, {}
        try:
            with path.open(encoding="utf-8", errors="replace") as stream:
                for ordinal, line in enumerate(stream):
                    scan["lines_scanned"] += 1
                    try:
                        row = json.loads(line)
                    except (ValueError, RecursionError):
                        timeline.append({"category": "invalid_json", "parent_index": None})
                        previous = None
                        last_reset = "invalid_json"
                        scan["invalid_json_lines"] += 1
                        continue
                    if not isinstance(row, dict):
                        timeline.append({"category": "non_object", "parent_index": None})
                        previous = None
                        last_reset = "non_object"
                        continue
                    item = metadata(row, number, ordinal)
                    item.update(content_metadata(row))
                    item.update(patch_tools=strict_block_ids(row, "tool_use", "id"),
                                patch_results=strict_block_ids(row, "tool_result", "tool_use_id"))
                    parent = seen_uuids.get(nonempty(item["parent"]))
                    category = record_kind(row)
                    item.update(category=category, parent_index=parent[0] if parent else None,
                                result_owners={key: tool_owners.get(key) for key in item["tool_results"]})
                    for identity in item["tool_uses"]:
                        tool_owners[identity] = (item["session"], item["message"])
                    if nonempty(item["uuid"]):
                        seen_uuids[item["uuid"]] = (ordinal, category)
                    timeline.append(item)
                    item["patch_previous"] = previous["index"] if previous else None
                    item["patch_tail"] = tail
                    item["patch_crossed_tool_result"] = crossed if previous else False
                    item["last_reset"] = last_reset
                    if not item["valid"]:
                        previous = None
                        last_reset = "typed_parser_rejected"
                    elif item["kind"] == "assistant":
                        previous, tail, crossed = item, item["uuid"], False
                    elif isinstance(item["kind"], str) and item["kind"] in IGNORED:
                        pass
                    else:
                        linked = nonempty(tail) and tail == item["parent"] and nonempty(item["uuid"])
                        owned_results = (previous and previous["patch_tools"] is not None and item["kind"] == "user"
                                         and item["patch_results"] is not None and item["patch_results"].issubset(previous["patch_tools"]))
                        hook = item["kind"] == "attachment" and crossed and item["attachment_type"] == "hook_success"
                        if previous and previous["request"] is None and previous["patch_tools"] is not None and linked and (owned_results or hook):
                            tail, crossed = item["uuid"], True
                        else:
                            previous = None
                            last_reset = bucket(item["kind"], KINDS)
                    try:
                        at = dt.datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00"))
                        if at.tzinfo is None:
                            continue
                        day = at.astimezone(zone).date().isoformat()
                    except (KeyError, ValueError, TypeError, AttributeError, OverflowError):
                        continue
                    message = row.get("message")
                    if day not in per_day or not isinstance(message, dict) or not isinstance(message.get("usage"), dict):
                        continue
                    item.update(at=at, group_session=nonempty(row.get("sessionId")) or ("file", number))
                    if item["request"] is None and item["sidechain"] is not True and nonempty(item["message"]):
                        group = (item["group_session"], item["message"])
                        prior = last_in_group.get(group)
                        if prior:
                            position = prior["index"][1]
                            location = ("not_seen" if parent is None else
                                        "previous_pair_record" if parent[0] == position else
                                        "between_pair_records" if parent[0] > position else "earlier_record")
                            usage_relation = ("unavailable" if prior["tokens"] is None or item["tokens"] is None else
                                              "equal" if prior["tokens"] == item["tokens"] else "different")
                            item["pair_context"] = {
                                "intervening_records": dict(Counter(r["category"] for r in timeline[position + 1:ordinal])),
                                "current_parent_kind": {parent[1] if parent else "not_seen": 1},
                                "current_parent_location": {location: 1},
                                "record_uuid_relation": {equality(nonempty(prior["uuid"]), nonempty(item["uuid"])): 1},
                                "usage_relation": {usage_relation: 1},
                            }
                            item["pair_context"].update(remainder_context(prior, item, timeline))
                        last_in_group[group] = item
                    per_day[day].append(item)
        except OSError:
            scan["unreadable_files"] += 1
    return {"schema": 4, "tested_rule_set": "20.0.26-llmusage.3", "days": days, "timezone": timezone,
              "files_scanned": len(files), "scan_counts": dict(scan),
              "per_day": {day: summarize(rows) for day, rows in per_day.items()},
              "whole_window": summarize([r for rows in per_day.values() for r in rows])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--date", default="2026-10-05", help="Last day in a three-day window")
    parser.add_argument("--timezone", default="UTC")
    parser.add_argument("--claude-dir", action="append", help="Optional Claude configuration root")
    parser.add_argument("--output", default="issue24-boundaries.json")
    args = parser.parse_args()
    result = inspect_boundaries(args.date, args.timezone, args.claude_dir)
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write("\n")
    print("Done. Only aggregate counters were exported; no log content or identities.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Cancelled.", file=sys.stderr)
        sys.exit(130)
    except FileExistsError:
        print("Output exists; choose another --output filename.", file=sys.stderr)
        sys.exit(1)
    except Exception:
        print("Could not finish. Check Python 3.9+, date, timezone and permissions. Raw errors are suppressed.", file=sys.stderr)
        sys.exit(1)
