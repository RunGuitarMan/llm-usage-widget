import Foundation
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#elseif !PORTABLE_CHECKS
@testable import LLMUsage
#endif

private struct TimingFailure: Error, CustomStringConvertible { var description: String }

@MainActor enum TranscriptTimingScenarios {
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw TimingFailure(description: message) }
    }
    private static func record(_ type: String, _ time: Double, _ payload: [String: Any]) -> [String: Any] {
        ["type": type, "timestamp": time, "payload": payload]
    }
    private static func event(_ type: String, _ time: Double, _ fields: [String: Any] = [:]) -> [String: Any] {
        record("event_msg", time, fields.merging(["type": type]) { _, new in new })
    }
    private static func message(_ role: String, _ id: String, _ time: Double, _ text: String = "Hello") -> [String: Any] {
        record("response_item", time, ["type": "message", "role": role, "id": id, "content": text])
    }
    private static func decode(_ source: String, _ records: [[String: Any]]) throws -> SessionTranscript {
        var decoder = TranscriptDecoder(source: source)
        for record in records { decoder.append(record) }
        let usage = try TranscriptUsageParser.annotate(.init(events: decoder.finish()), source: source)
        return try TranscriptTimingParser.annotate(usage, source: source)
    }
    static func run(check: (String, () async throws -> Void) async -> Void) async {
        await check("Codex errors: explicit tool outcomes are searchable without changing billing") {
            let outputs: [(Any, Bool)] = [
                (["output": "failed", "metadata": ["exit_code": 1]], true),
                (["isError": true, "content": [["type": "text", "text": "denied"]]], true),
                (#"{"isError":true,"content":[]}"#, true),
                ("Chunk ID: example\nWall time: 0.1 seconds\nProcess exited with code 1\nFinal output:\n", true),
                ("Wall time: 0.1 seconds\nExit code: -1\nOutput:\n", true),
                ("Process exited with code 0\nFinal output:\nError: example\nProcess exited with code 1", false),
                (["output": "error", "metadata": ["exit_code": 0]], false),
                (["metadata": ["exit_code": true]], false),
                ("Error: this is ordinary output without recorded status", false)
            ]
            for (output, failed) in outputs {
                let value = try decode("codex", [
                    record("turn_context", 100, ["model": "gpt-fixture"]),
                    record("response_item", 101, ["type": "custom_tool_call", "call_id": "call", "name": "exec", "input": "false"]),
                    record("response_item", 102, ["type": "custom_tool_call_output", "call_id": "call", "output": output]),
                    event("token_count", 103, ["info": ["last_token_usage": ["input_tokens": 10, "output_tokens": 5]]])])
                let all = try TranscriptSearchResult.evaluate(.init(transcript: value))
                let errors = try TranscriptSearchResult.evaluate(.init(transcript: value, filter: .errors))
                try require(value.events.first { $0.kind == .tool }?.isError == failed, "Tool outcome was misclassified: \(output)")
                try require(errors.eventCount == (failed ? 1 : 0), "Error filter lost a failure or included ordinary output")
                try require(errors.analysis?.reported == all.analysis?.reported && all.analysis?.reported.total == 15,
                            "Error filtering changed request billing")
            }
        }
        await check("Codex errors: completion status matches tools in either record order") {
            for item: [String: Any] in [
                ["type": "CommandExecution", "id": "call", "status": "failed"],
                ["type": "CommandExecution", "id": "call", "exitCode": 1],
                ["type": "McpToolCall", "id": "call", "result": ["isError": true]]
            ] {
                let completion = event("item_completed", 103, ["item": item])
                let response = [
                    record("response_item", 101, ["type": "function_call", "call_id": "call", "name": "exec", "arguments": "false"]),
                    record("response_item", 102, ["type": "function_call_output", "call_id": "call", "output": "denied"])]
                for records in [[completion] + response, response + [completion]] {
                    let value = try decode("codex", records)
                    let errors = try TranscriptSearchResult.evaluate(.init(transcript: value, query: "denied", filter: .errors))
                    try require(errors.eventCount == 1 && errors.rows.first?.events.first?.kind == .tool, "Completion failed to mark its tool")
                    let repeated = try TranscriptTimingParser.annotate(value, source: "codex")
                    try require(repeated.events.map(\.isError) == value.events.map(\.isError), "Repeated annotation changed failures")
                }
            }
        }
        await check("Codex errors: unmatched and ambiguous completions remain visible without blaming other calls") {
            let call = record("response_item", 100, ["type": "function_call", "call_id": "same", "name": "exec", "arguments": "pwd"])
            let completion = event("item_completed", 105, ["item": ["type": "CommandExecution", "id": "same", "status": "Failed"]])
            let ambiguous = try decode("codex", [call, call, completion])
            try require(ambiguous.events.filter { $0.kind == .tool }.allSatisfy { !$0.isError }, "Ambiguous status attached to an arbitrary call")
            let errors = try TranscriptSearchResult.evaluate(.init(transcript: ambiguous, filter: .errors))
            try require(errors.eventCount == 1 && errors.rows.first?.isContext == true, "Unmatched failure hidden behind service-event toggle")
            var decoder = TranscriptDecoder(source: "codex")
            decoder.origin = "parent"; decoder.append(call)
            decoder.origin = "child"; decoder.append(call); decoder.append(completion)
            let scoped = try TranscriptTimingParser.annotate(.init(events: decoder.finish()), source: "codex")
            try require(scoped.events.filter { $0.kind == .tool }.map(\.isError) == [false, true], "Failure crossed log boundaries")
        }
        await check("Timing: exact Codex turn, independent message span, TTFT and scoped output rate") {
            let value = try decode("codex", [
                event("task_started", 100, ["turn_id": "t", "started_at": 100]),
                message("user", "u", 101),
                event("item_completed", 105, ["turn_id": "t", "started_at_ms": 103000, "completed_at_ms": 105000,
                    "item": ["type": "AgentMessage", "id": "a"]]),
                message("assistant", "a", 105, "Answer"),
                event("token_count", 105, ["info": ["last_token_usage": ["input_tokens": 100, "output_tokens": 20]]]),
                record("token_usage_record", 105, ["turn_id": "t", "turn_token_usage": ["output_tokens": 20], "thread_token_usage": ["output_tokens": 99999]]),
                record("token_usage_record", 106, ["turn_id": "t", "turn_token_usage": ["output_tokens": 20]]),
                event("task_complete", 110, ["turn_id": "t", "started_at": 100, "completed_at": 110, "duration_ms": 10000, "time_to_first_token_ms": 2500])
            ])
            let user = value.events.first { $0.kind == .user }!.timing!
            let answer = value.events.first { $0.kind == .assistant && !$0.isUsageOnly }!.timing!
            try require(user.duration == 10 && user.timeToFirstToken == 2.5 && user.outputTokens == 20 && user.tokensPerSecond == 2, "Turn metrics or token scope incorrect")
            try require(answer.duration == 2 && answer.timeToFirstToken == nil && answer.tokensPerSecond == nil, "Turn metrics leaked into message generation")
            try require(value.requests.count == 1 && value.requests[0].usage.total == 120, "Timing changed billing")
            let again = try TranscriptTimingParser.annotate(value, source: "codex")
            try require(again.events.map(\.timing) == value.events.map(\.timing), "Reannotation changed timing")
            try require(value.exportText.contains("TTFT: ") && value.exportText.components(separatedBy: "\"time_to_first_token_ms\"").count == 2, "Export lost timing or repeated raw record")
        }
        await check("Timing: late terminal events stay with their original turn; open turn has no total") {
            let value = try decode("codex", [
                event("task_started", 100, ["turn_id": "one"]), message("user", "u1", 101, "Repeat"),
                message("assistant", "a1", 105),
                event("task_started", 200, ["turn_id": "two"]), message("user", "u2", 201, "Repeat"),
                event("task_complete", 210, ["turn_id": "one", "duration_ms": 10000, "completed_at": 110]),
                message("assistant", "a2", 215)
            ])
            let users = value.events.filter { $0.kind == .user }
            try require(users.count == 2 && users[0].timing?.duration == 10, "Late completion assigned to new user")
            try require(users[1].timing?.status == .incomplete && users[1].timing?.duration == nil, "Open turn gained fabricated total")
        }
        await check("Timing: interrupted Codex turn preserves elapsed time without a completion throughput") {
            let value = try decode("codex", [event("task_started", 100, ["turn_id": "t"]), message("user", "u", 101),
                record("token_usage_record", 105, ["turn_id": "t", "turn_token_usage": ["output_tokens": 10]]),
                event("turn_aborted", 107, ["turn_id": "t"])])
            let timing = value.events.first { $0.kind == .user }!.timing!
            try require(timing.status == .interrupted && timing.duration == 7 && timing.tokensPerSecond == nil, "Interrupted turn misrepresented")
        }
        await check("Timing: parallel tools use their own result boundaries and do not add their durations") {
            let value = try decode("claude", [
                ["type": "assistant", "timestamp": 100, "message": ["role": "assistant", "content": [
                    ["type": "tool_use", "id": "a", "name": "Read", "input": [:]], ["type": "tool_use", "id": "b", "name": "Read", "input": [:]]]]],
                ["type": "user", "timestamp": 103, "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "b", "content": "B"]]]],
                ["type": "user", "timestamp": 107, "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "a", "content": "A"]]]]
            ])
            let tools = value.events.filter { $0.kind == .tool }
            try require(tools.map { $0.timing?.duration } == [7, 3], "Parallel tool durations were combined or mismatched")
            try require(tools.allSatisfy { $0.timing?.evidence == .timestamps }, "Estimated tool time labelled as measured")
        }
        await check("Timing: tool call IDs and turn IDs are isolated across subagent logs") {
            var decoder = TranscriptDecoder(source: "codex")
            for origin in ["parent", "child"] {
                decoder.origin = origin
                decoder.append(event("task_started", 100, ["turn_id": "same"]))
                decoder.append(message("user", "same-user", 101))
                decoder.append(record("response_item", 102, ["type": "function_call", "call_id": "same", "name": "exec", "arguments": "pwd"]))
                if origin == "child" {
                    decoder.append(record("response_item", 105, ["type": "function_call_output", "call_id": "same", "output": "child"]))
                    decoder.append(event("task_complete", 110, ["turn_id": "same", "duration_ms": 10000]))
                }
            }
            decoder.origin = "parent"
            decoder.append(record("response_item", 109, ["type": "function_call_output", "call_id": "same", "output": "parent"]))
            let value = try TranscriptTimingParser.annotate(.init(events: decoder.finish()), source: "codex")
            let tools = value.events.filter { $0.kind == .tool }
            try require(tools.map(\.output) == ["parent", "child"] && tools.map { $0.timing?.duration } == [7, 3], "Cross-log tool result association")
            let users = value.events.filter { $0.kind == .user }
            try require(users[0].timing?.status == .incomplete && users[1].timing?.duration == 10, "Cross-log turn association")
        }
        await check("Timing: Codex measured tool duration wins over log latency and keeps nanoseconds") {
            let value = try decode("codex", [
                record("response_item", 100, ["type": "function_call", "call_id": "tool", "name": "mcp", "arguments": "{}"]),
                record("response_item", 105, ["type": "function_call_output", "call_id": "tool", "output": "done"]),
                event("item_completed", 105, ["started_at_ms": 100000, "completed_at_ms": 105000,
                    "item": ["type": "McpToolCall", "id": "tool", "duration": ["secs": 0, "nanos": 250000000]]])])
            let timing = value.events.first { $0.kind == .tool }!.timing!
            try require(timing.duration == 0.25 && timing.evidence == .recorded && timing.start == Date(timeIntervalSince1970: 100), "Measured duration lost precision or got overwritten")
        }
        await check("Timing: Gemini inline result and adjacent messages do not invent generation time") {
            let value = try decode("gemini", [
                ["type": "user", "timestamp": 100, "content": "Prompt"],
                ["type": "gemini", "id": "m", "timestamp": 200, "content": "Answer", "tokens": ["input": 10, "output": 20],
                 "toolCalls": [["id": "t", "name": "read", "args": [:], "result": "done"]]]])
            try require(value.events.allSatisfy { $0.timing?.duration == nil }, "Inline result became zero or adjacent gap became generation time")
            try require(value.events.first { $0.kind == .tool }?.timing?.status == .complete, "Inline completion lost")
        }
        await check("Timing: malformed, reversed, equal timestamps and invalid TTFT remain unavailable") {
            let bad = try decode("codex", [
                event("task_started", 110, ["turn_id": "t"]), message("user", "u", 110),
                event("task_complete", 100, ["turn_id": "t", "duration_ms": true, "time_to_first_token_ms": -1]),
                message("assistant", "a", 110),
                event("item_completed", 110, ["started_at_ms": 110000, "completed_at_ms": 110000,
                    "item": ["type": "AgentMessage", "id": "a"]])])
            try require(bad.events.allSatisfy { $0.timing?.duration == nil && $0.timing?.timeToFirstToken == nil }, "Invalid time was fabricated")
            let ttft = TranscriptTiming(kind: .processing, duration: 1, timeToFirstToken: 2, outputTokens: 10)
            try require(ttft.timeToFirstToken == nil, "TTFT longer than entire turn")
            try require(TranscriptTiming(kind: .processing, duration: .infinity).duration == nil, "Infinite duration accepted")
            try require(TranscriptTiming(kind: .processing, duration: 0, outputTokens: 10).tokensPerSecond == nil, "Division by zero")
        }
        await check("Timing: Claude explicit turn duration takes precedence; late completion follows parent UUID") {
            let value = try decode("claude", [
                ["type": "user", "timestamp": 100, "message": ["role": "user", "content": "First"]],
                ["type": "assistant", "uuid": "a", "timestamp": 108, "message": ["role": "assistant", "content": "Answer", "stop_reason": "end_turn"]],
                ["type": "user", "timestamp": 200, "message": ["role": "user", "content": "Second"]],
                ["type": "system", "timestamp": 210, "subtype": "turn_duration", "parentUuid": "a", "durationMs": 6500],
                ["type": "system", "timestamp": 211, "subtype": "turn_duration", "durationMs": 99999]
            ])
            let users = value.events.filter { $0.kind == .user }
            try require(users[0].timing?.duration == 6.5 && users[0].timing?.evidence == .recorded, "Explicit duration lost or assigned to next prompt")
            try require(users[1].timing == nil, "Orphan duration attributed to unanswered prompt")
        }
        await check("Timing: Claude end_turn estimates processing only; tool_use is not completion") {
            let value = try decode("claude", [
                ["type": "user", "timestamp": 100, "message": ["role": "user", "content": "First"]],
                ["type": "assistant", "timestamp": 110, "message": ["role": "assistant", "content": "Answer", "stop_reason": "end_turn"]],
                ["type": "user", "timestamp": 200, "message": ["role": "user", "content": "Second"]],
                ["type": "assistant", "timestamp": 220, "message": ["role": "assistant", "content": "Working", "stop_reason": "tool_use"]]
            ])
            let users = value.events.filter { $0.kind == .user }
            try require(users[0].timing?.duration == 10 && users[0].timing?.evidence == .timestamps && users[1].timing == nil, "Unfinished Claude turn counted")
            try require(value.events.filter { $0.kind == .assistant }.allSatisfy { $0.timing == nil }, "Processing interval labelled as generation")
        }
        await check("Timing: ambiguous wire IDs do not transfer timing to an arbitrary message") {
            let value = try decode("codex", [message("assistant", "a", 100, "First"), message("assistant", "a", 110, "Second"),
                event("item_completed", 112, ["started_at_ms": 110000, "completed_at_ms": 112000,
                    "item": ["type": "AgentMessage", "id": "a"]])])
            try require(value.events.filter { $0.kind == .assistant }.allSatisfy { $0.timing == nil }, "Ambiguous ID was guessed")
            try require(value.events.first { $0.kind == .context }?.timing?.duration == 2, "Unmatched measured service event lost")
        }
        await check("Timing: service operations retain measured span without assigning system instruction time") {
            let value = try decode("codex", [message("developer", "d", 100, "Instructions"),
                event("item_completed", 120, ["started_at_ms": 110000, "completed_at_ms": 120000,
                    "item": ["type": "ContextCompaction", "id": "compact"]])])
            try require(value.events[0].timing == nil && value.events[1].timing?.duration == 10, "System prompt got fabricated timing")
        }
        await check("Timing: both Codex message streams retain their wire ID in either order") {
            for fallbackFirst in [true, false] {
                let fallback = event("agent_message", 104, ["message": "Answer"])
                let response = message("assistant", "a", 105, "Answer")
                let value = try decode("codex", (fallbackFirst ? [fallback, response] : [response, fallback]) + [
                    event("item_completed", 105, ["started_at_ms": 102000, "completed_at_ms": 105000,
                        "item": ["type": "AgentMessage", "id": "a"]])])
                let answers = value.events.filter { $0.kind == .assistant }
                try require(answers.count == 1 && answers[0].timing?.duration == 3, "Deduplicated response lost wire timing")
            }
        }
        await check("Timing: overlapping calls with a duplicated call ID remain unpaired") {
            let call = record("response_item", 100, ["type": "function_call", "call_id": "a", "name": "exec", "arguments": "pwd"])
            let value = try decode("codex", [call, call,
                record("response_item", 105, ["type": "function_call_output", "call_id": "a", "output": "Ambiguous"])] )
            let calls = value.events.filter { $0.kind == .tool && !$0.isToolResultOnly }
            try require(calls.count == 2 && calls.allSatisfy { !$0.hasResult && $0.timing?.duration == nil }, "Ambiguous result assigned arbitrarily")
            try require(value.events.contains { $0.isToolResultOnly && $0.output == "Ambiguous" }, "Unmatched result discarded")
        }
        await check("Timing: reset or damaged output counters do not claim reliable throughput") {
            let value = try decode("codex", [event("task_started", 100, ["turn_id": "t"]), message("user", "u", 101),
                record("token_usage_record", 102, ["turn_id": "t", "turn_token_usage": ["output_tokens": 20]]),
                record("token_usage_record", 104, ["turn_id": "t", "turn_token_usage": ["output_tokens": 5]]),
                event("task_complete", 105, ["turn_id": "t", "duration_ms": 5000])])
            let timing = value.events.first { $0.kind == .user }!.timing!
            try require(timing.duration == 5 && timing.tokensPerSecond == nil, "Counter reset silently inflated throughput")
            try require(TranscriptJSON.date(true) == nil && TranscriptJSON.date(Double.infinity) == nil, "Invalid timestamp accepted")
        }
        await check("Timing: day and search filters preserve cross-midnight duration and usage") {
            let day = UsageDay(date: ISO8601DateFormatter().date(from: "2026-10-02T00:00:00Z")!, timezone: "UTC")
            let start = day.date.timeIntervalSince1970 - 5
            let value = try decode("codex", [event("task_started", start, ["turn_id": "t"]), message("user", "u", start),
                message("assistant", "a", start + 10, "Answer"),
                event("item_completed", start + 10, ["started_at_ms": (start + 2) * 1000, "completed_at_ms": (start + 10) * 1000,
                    "item": ["type": "AgentMessage", "id": "a"]]),
                event("token_count", start + 10, ["info": ["last_token_usage": ["input_tokens": 10, "output_tokens": 5]]]),
                event("task_complete", start + 15, ["turn_id": "t", "duration_ms": 15000])])
            let daily = try TranscriptSearchResult.evaluate(.init(transcript: value, day: day))
            let search = try TranscriptSearchResult.evaluate(.init(transcript: value, query: "Answer", day: day))
            try require(daily.rows.flatMap(\.events).first { $0.kind == .user }?.timing?.duration == 15, "Midnight clipped processing time")
            try require(search.rows.flatMap(\.events).first?.timing?.duration == 8, "Search changed event interval")
            try require(daily.analysis?.reported.total == search.analysis?.reported.total, "Timing/filtering changed billing")
            let tools = try decode("codex", [
                record("response_item", start, ["type": "function_call", "call_id": "t", "name": "exec", "arguments": "pwd"]),
                record("response_item", start + 10, ["type": "function_call_output", "call_id": "t", "output": "done"])])
            let nextDay = try TranscriptSearchResult.evaluate(.init(transcript: tools, day: day, filter: .tools))
            try require(nextDay.rows.first?.events.first?.timing?.duration == 10, "Cross-midnight tool disappeared without billing data")
        }
        await check("Timing: localized units, rounding boundaries and unknown values") {
            let saved = L10n.preference
            defer { L10n.preference = saved }
            L10n.preference = .english
            try require(TranscriptTimingFormat.duration(0.0001) == "<1 ms" && TranscriptTimingFormat.duration(0.125) == "125 ms", "Subsecond units")
            try require(TranscriptTimingFormat.duration(59.99) == "1 min 0.0 s" && TranscriptTimingFormat.duration(3600) == "1 h 0 min", "Duration rounding overflow")
            try require(TranscriptTimingFormat.rate(12.5) == "12.5 tokens/s", "English throughput")
            L10n.preference = .russian
            try require(TranscriptTimingFormat.rate(12.5) == "12,5 токенов/с" && TranscriptTimingFormat.duration(1.5) == "1,5 с", "Russian throughput")
        }
    }
}
