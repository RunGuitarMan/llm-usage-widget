import Foundation
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#elseif !PORTABLE_CHECKS
@testable import LLMUsage
#endif

private struct ServiceEventFailure: Error, CustomStringConvertible { var description: String }

@MainActor enum TranscriptServiceScenarios {
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw ServiceEventFailure(description: message) }
    }
    private static func decode(_ records: [[String: Any]]) -> SessionTranscript {
        var decoder = TranscriptDecoder(source: "claude")
        decoder.origin = "fixture.jsonl"
        records.forEach { decoder.append($0) }
        return .init(events: decoder.finish())
    }
    private static func system(_ subtype: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        fields.merging(["type": "system", "subtype": subtype, "timestamp": "2026-10-08T10:00:00Z"]) { _, new in new }
    }
    private static func attachment(_ subtype: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        ["type": "attachment", "timestamp": "2026-10-08T10:00:01Z", "attachment": fields.merging(["type": subtype]) { _, new in new }]
    }
    static func run(check: (String, () async throws -> Void) async -> Void) async {
        await check("Service events: visible individually, hidden metadata stays grouped, errors and tools stay precise") {
            let transcript = decode([
                system("compact_boundary", ["compactMetadata": ["trigger": "auto", "preTokens": 237943, "postTokens": 13493, "durationMs": 154217]]),
                system("api_error", ["cause": ["code": "ECONNRESET"], "retryAttempt": 1, "maxRetries": 10, "retryInMs": 503.1]),
                attachment("hook_blocking_error", ["hookEvent": "Stop", "blockingError": ["blockingError": "Run the tests", "command": "check.sh"]]),
                attachment("hook_additional_context", ["content": ["Use schema.ts", "Regenerate the output"]]),
                attachment("diagnostics", ["files": [["filePath": "src/a.swift", "diagnostics": [["severity": "Warning", "message": "Unused value"]]]]]),
                system("turn_duration", ["durationMs": 5000]), system("unknown"), attachment("hook_success")
            ])
            let normal = try TranscriptSearchResult.evaluate(.init(transcript: transcript))
            try require(normal.eventCount == 5 && normal.rows.count == 5 && normal.rows.allSatisfy { !$0.isContext }, "Useful service events hidden or merged")
            let errors = try TranscriptSearchResult.evaluate(.init(transcript: transcript, filter: .errors))
            try require(errors.rows.flatMap(\.events).map { $0.service?.kind } == [.apiError, .hookBlocked], "API/hook errors missing or warnings treated as errors")
            let tools = try TranscriptSearchResult.evaluate(.init(transcript: transcript, filter: .tools))
            try require(tools.eventCount == 0, "Service event treated as tool call")
            let all = try TranscriptSearchResult.evaluate(.init(transcript: transcript, showContext: true))
            try require(all.eventCount == 8 && all.rows.count == 6 && all.rows.last?.events.count == 3, "Fallback records lost context grouping")
            let events = transcript.events
            try require(events[0].service?.tokensBefore == 237943 && events[0].service?.tokensAfter == 13493 && events[0].service?.duration == 154.217, "Compaction metadata lost")
            try require(events[1].text == "ECONNRESET" && events[1].service?.retryDelay == 0.5031, "Cause or fractional retry delay lost")
            try require(events[2].text == "Run the tests" && events[2].service?.hook == "check.sh", "Blocking reason/command lost")
            try require(events[3].text == "Use schema.ts\n\nRegenerate the output", "Hook context array lost")
            try require(transcript.messageCount == 0 && transcript.toolCount == 0, "Service events inflated conversation counts")
            try require(transcript.exportText.contains("compactMetadata") && transcript.exportText.contains("hook_success"), "Export discarded original records")
        }
        await check("Service events: search and day filters include readable details and unknown raw fields") {
            let long = String(repeating: "context ", count: 200) + "needle-at-end"
            let transcript = decode([attachment("hook_additional_context", ["content": long]),
                                     system("api_error", ["error": ["error": ["type": "overloaded_error", "message": "Try later"]], "opaque": "raw-only"]),
                                     system("unknown", ["opaque": "hidden-only"])])
            for query in ["needle-at-end", "Try later", "raw-only", "hidden-only"] {
                let result = try TranscriptSearchResult.evaluate(.init(transcript: transcript, query: query))
                try require(result.eventCount == 1, "Search failed for \(query)")
            }
            let day = UsageDay(date: TranscriptJSON.date("2026-10-08T12:00:00Z")!, timezone: "UTC")
            let today = try TranscriptSearchResult.evaluate(.init(transcript: transcript, day: day))
            let tomorrow = UsageDay(date: day.end, timezone: "UTC")
            let other = try TranscriptSearchResult.evaluate(.init(transcript: transcript, day: tomorrow, filter: .errors))
            try require(today.eventCount == 2 && other.eventCount == 0, "Service events escaped selected day")
            try require(TranscriptTextPreview(transcript.events[0].text).isTruncated && transcript.events[0].text.hasSuffix("needle-at-end"), "Long context lost content")
        }
        await check("Service events: incomplete and malformed optional fields never fabricate metrics") {
            let transcript = decode([
                system("compact_boundary"),
                system("compact_boundary", ["compactMetadata": ["preTokens": true, "postTokens": -1, "durationMs": "bad"]]),
                system("compact_boundary", ["compactMetadata": ["trigger": "manual", "preTokens": 100]]),
                system("api_error", ["retryAttempt": 1.5, "maxRetries": false, "retryInMs": -10]),
                attachment("hook_non_blocking_error", ["stderr": "script failed"]),
                attachment("hook_additional_context", ["additionalContext": "Instructions"])
            ])
            try require(transcript.events[0].service?.facts.isEmpty == true && transcript.events[1].service?.facts.isEmpty == true, "Missing fields became fake metrics")
            try require(transcript.events[2].service?.tokensAfter == nil && transcript.events[2].service?.trigger == "manual", "Manual compaction guessed an after count")
            try require(transcript.events[3].isError && transcript.events[3].service?.facts.isEmpty == true, "Malformed API metrics hid the error")
            try require(transcript.events[4].text == "script failed" && transcript.events[4].isError, "Nonblocking hook failure lost")
            try require(transcript.events[5].text == "Instructions", "Additional context field lost")
        }
        await check("Service events: diagnostics tolerate object codes and unknown payload shapes") {
            let transcript = decode([attachment("diagnostics", ["files": [["filePath": "a.md", "diagnostics": [
                ["severity": "Error", "message": "Missing heading", "code": ["value": "MD022", "target": ["path": "/rule"]], "range": ["start": ["line": 6, "character": 0]]],
                ["severity": 1, "message": "Numeric severity", "code": 42], ["unknown": "preserved"]]]]])])
            let event = transcript.events[0]
            try require(event.isError && event.text.contains("a.md") && event.text.contains("MD022") && event.text.contains("preserved") && event.text.contains("42"), "Diagnostic content or severity lost")
            try require(event.raw.contains("target") && event.origin == "fixture.jsonl", "Raw diagnostics/origin lost")
        }
        await check("Service events: localization preserves payloads and timing annotation") {
            let saved = L10n.preference
            defer { L10n.preference = saved }
            for language in [InterfaceLanguage.russian, .english] {
                L10n.preference = language
                let transcript = decode([
                    ["type": "user", "uuid": "u", "message": ["role": "user", "content": "Hello"]],
                    ["type": "assistant", "uuid": "a", "parentUuid": "u", "message": ["role": "assistant", "content": "Done"]],
                    system("turn_duration", ["parentUuid": "a", "durationMs": 6500]),
                    system("api_error", ["cause": ["code": "ECONNRESET"]]),
                    system("compact_boundary", ["compactMetadata": ["trigger": "auto", "preTokens": 100, "postTokens": 20]])
                ])
                let annotated = try TranscriptTimingParser.annotate(TranscriptUsageParser.annotate(transcript, source: "claude"), source: "claude")
                try require(annotated.events.first?.timing?.duration == 6.5, "Turn duration no longer attributes to user")
                try require(annotated.events[3].isError && annotated.events[3].text == "ECONNRESET", "Annotation erased service error")
                try require(annotated.events[4].title == (language == .russian ? "Контекст сжат автоматически" : "Context compacted automatically"), "Title not localized")
                try require(annotated.events[4].service?.facts.first?.contains(language == .russian ? "токенов" : "tokens") == true, "Metrics not localized")
            }
        }
    }
}
