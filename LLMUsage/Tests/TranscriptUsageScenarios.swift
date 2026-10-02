import Foundation
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#elseif !PORTABLE_CHECKS
@testable import LLMUsage
#endif

private struct TranscriptUsageFailure: Error, CustomStringConvertible { var description: String }

@MainActor enum TranscriptUsageScenarios {
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw TranscriptUsageFailure(description: message) }
    }
    static let date = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
    static func decode(_ source: String, _ text: String, parent: SessionTranscript? = nil) throws -> SessionTranscript {
        var decoder = TranscriptDecoder(source: source)
        for line in text.split(separator: "\n") {
            decoder.append(try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any])
        }
        return try TranscriptUsageParser.annotate(.init(events: decoder.finish()), source: source, parent: parent)
    }
    static let claude = #"""
    {"type":"assistant","timestamp":"2026-10-01T12:00:00Z","requestId":"a","message":{"id":"m","role":"assistant","model":"claude-chat-fixture","content":[{"type":"text","text":"Private content never sent to cost process"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/secret/a"}},{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/secret/b"}}],"usage":{"input_tokens":100,"output_tokens":10,"cache_creation_input_tokens":40,"cache_read_input_tokens":20}}}
    {"type":"assistant","timestamp":"2026-10-01T12:00:01Z","requestId":"a","message":{"id":"m","role":"assistant","model":"claude-chat-fixture","content":[{"type":"text","text":"Completed"}],"usage":{"input_tokens":100,"output_tokens":30,"cache_creation_input_tokens":40,"cache_read_input_tokens":20}}}
    {"type":"user","timestamp":"2026-10-01T12:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"Private result"},{"type":"tool_result","tool_use_id":"t1","content":"Other result"}]}}
    """#
    static let codex = #"""
    {"type":"turn_context","payload":{"model":"gpt-chat-fixture","service_tier":"priority"}}
    {"type":"event_msg","timestamp":"2026-10-01T12:00:00Z","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"priority"}}}
    {"type":"response_item","timestamp":"2026-10-01T12:00:00Z","payload":{"type":"function_call","name":"exec","call_id":"t","arguments":"pwd"}}
    {"type":"event_msg","timestamp":"2026-10-01T12:00:01Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100,"reasoning_output_tokens":80,"total_tokens":1100},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100,"reasoning_output_tokens":80,"total_tokens":1100}}}}
    {"type":"event_msg","timestamp":"2026-10-01T12:00:02Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100,"reasoning_output_tokens":80,"total_tokens":1100},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100,"reasoning_output_tokens":80,"total_tokens":1100}}}}
    {"type":"response_item","timestamp":"2026-10-01T12:00:03Z","payload":{"type":"function_call_output","call_id":"t","output":"Private tool result"}}
    {"type":"turn_context","payload":{"model":"gpt-chat-fixture","service_tier":"standard"}}
    {"type":"event_msg","timestamp":"2026-10-01T12:00:03Z","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"standard"}}}
    {"type":"response_item","timestamp":"2026-10-01T12:00:04Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}
    {"type":"event_msg","timestamp":"2026-10-01T12:00:05Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1600,"cached_input_tokens":500,"output_tokens":150,"reasoning_output_tokens":100,"total_tokens":1750}}}}
    """#
    static let gemini = #"""
    {"type":"gemini","id":"g","timestamp":"2026-10-01T12:00:00Z","model":"gemini-chat-fixture","content":"Answer","tokens":{"input":1000,"cached":400,"output":100,"thoughts":50,"total":1150},"toolCalls":[{"id":"s","name":"Skill","args":{"skill":"review"},"result":"done"}]}
    """#

    static func run(check: (String, () async throws -> Void) async -> Void) async {
        await check("User usage: Claude tools and streams share one prompt without duplicate charges") {
            let value = try decode("claude", #"{"type":"user","message":{"role":"user","content":"First prompt"}}"# + "\n" + claude + "\n" + #"""
            {"type":"assistant","message":{"id":"next","role":"assistant","model":"claude-chat-fixture","content":"After tools","usage":{"input_tokens":50,"output_tokens":10}}}
            {"type":"user","message":{"role":"user","content":"Unanswered prompt"}}
            """#)
            let users = value.events.filter { $0.kind == .user }
            let result = try TranscriptSearchResult.evaluate(.init(transcript: value))
            try require(users.count == 2 && value.requests.count == 2, "Tool result became a prompt or stream duplicated")
            try require(value.requests.allSatisfy { $0.userEventID == users[0].id }, "Tool continuation lost the original prompt")
            try require(result.requestsByUserID[users[0].id]?.reduce(0, { $0 + $1.usage.total }) == 250, "Prompt total differs from unique requests")
            try require(result.requestsByUserID[users[1].id] == nil, "Unanswered prompt inherited a charge")
            try require(result.analysis?.reported.total == 250 && users.allSatisfy { $0.requestIDs.isEmpty }, "Prompt charge counted twice")
            let again = try TranscriptUsageParser.annotate(value, source: "claude")
            try require(again.requests.map(\.userEventID) == value.requests.map(\.userEventID), "Reannotation changed prompt ownership")
        }
        await check("User usage: Codex deduplicated prompts, explicit turns and aborted responses") {
            let value = try decode("codex", #"""
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"one"}}
            {"type":"turn_context","payload":{"model":"gpt-chat-fixture","turn_id":"one"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"Repeat"}}
            {"type":"response_item","payload":{"role":"user","content":"Repeat"}}
            {"type":"response_item","payload":{"role":"user","content":"<environment_context>settings</environment_context>"}}
            {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10}}}}
            {"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"one"}}
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"two"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"Repeat"}}
            {"type":"response_item","payload":{"role":"user","content":"Repeat"}}
            {"type":"event_msg","payload":{"type":"token_count","turn_id":"one","info":{"last_token_usage":{"input_tokens":20,"output_tokens":5}}}}
            {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"output_tokens":20}}}}
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"two"}}
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"three"}}
            {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":1}}}}
            """#)
            let users = value.events.filter { $0.kind == .user }
            try require(users.count == 2, "Repeated prompt collapsed or environment counted")
            try require(value.requests.map(\.userEventID) == [users[0].id, users[0].id, users[1].id, nil], "Late, aborted or unattended request attributed to wrong prompt")
            try require(value.requests.allSatisfy { $0.anchorID != $0.userEventID }, "Usage-only response anchor replaced by prompt")
        }
        await check("User usage: late streamed usage stays with its original message") {
            let value = try decode("claude", #"""
            {"type":"user","message":{"role":"user","content":"Old"}}
            {"type":"assistant","requestId":"r","message":{"id":"m","role":"assistant","content":"Streaming","usage":{"input_tokens":10,"output_tokens":1}}}
            {"type":"user","message":{"role":"user","content":"New"}}
            {"type":"assistant","requestId":"r","message":{"id":"m","role":"assistant","content":"Late completion","usage":{"input_tokens":10,"output_tokens":5}}}
            """#)
            try require(value.requests.count == 1 && value.requests[0].userEventID == value.events[0].id && value.requests[0].usage.total == 15,
                        "Late stream update moved cost to the next prompt")
        }
        await check("User usage: older Codex logs may place prompts before turn context") {
            let value = try decode("codex", #"""
            {"type":"response_item","payload":{"role":"user","content":"First"}}
            {"type":"turn_context","payload":{"model":"gpt-chat-fixture","turn_id":"one"}}
            {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":1}}}}
            {"type":"response_item","payload":{"role":"user","content":"Second"}}
            {"type":"event_msg","payload":{"type":"token_count","turn_id":"one","info":{"last_token_usage":{"input_tokens":5,"output_tokens":1}}}}
            {"type":"turn_context","payload":{"model":"gpt-chat-fixture","turn_id":"two"}}
            {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"output_tokens":2}}}}
            {"type":"turn_context","payload":{"model":"gpt-chat-fixture","turn_id":"unattended"}}
            {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"output_tokens":3}}}}
            """#)
            let users = value.events.filter { $0.kind == .user }
            try require(value.requests.map(\.userEventID) == [users[0].id, users[0].id, users[1].id, nil], "Prompt preceding turn context lost or inherited by autonomous turn")
        }
        await check("User usage: Gemini prompt changes delimit model and tool continuations") {
            let value = try decode("gemini", #"{"type":"user","content":"First"}"# + "\n" + gemini + "\n" + #"""
            {"type":"user","content":"Second"}
            {"type":"gemini","id":"next","model":"gemini-chat-fixture","content":"Answer","tokens":{"input":20,"output":5}}
            """#)
            let users = value.events.filter { $0.kind == .user }
            try require(value.requests.map(\.userEventID) == users.map { Optional($0.id) }, "Gemini prompt boundary lost")
        }
        await check("User usage: child logs cannot inherit the last main-log prompt") {
            var decoder = TranscriptDecoder(source: "claude")
            for (origin, text) in [(nil as String?, #"{"type":"user","message":{"role":"user","content":"Main"}}"#),
                                   ("child.jsonl", #"{"type":"assistant","message":{"id":"child","role":"assistant","usage":{"input_tokens":10,"output_tokens":5}}}"#)] {
                decoder.origin = origin
                decoder.append(try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
            }
            let value = try TranscriptUsageParser.annotate(.init(events: decoder.finish()), source: "claude")
            try require(value.requests.count == 1 && value.requests[0].userEventID == nil, "Unrelated child charged to main prompt")
        }
        await check("User usage: scope, replay, exclusions, search and unknown prices preserve accounting") {
            var value = try decode("claude", #"{"type":"user","message":{"role":"user","content":"Find this prompt"}}"# + "\n" + claude)
            let user = value.events.firstIndex { $0.kind == .user }!
            let userID = value.events[user].id
            let day = UsageDay(date: date, timezone: "UTC")
            value.events[user].timestamp = day.date.addingTimeInterval(-1)
            var next = value.requests[0]; next.id = "next-day"; next.timestamp = day.end
            var replay = value.requests[0]; replay.id = "replay"; replay.isReplay = true
            value.requests += [next, replay]
            let result = try TranscriptSearchResult.evaluate(.init(transcript: value, query: "Find this prompt", day: day,
                policy: .init(overrides: ["claude-chat-fixture": false])))
            try require(result.rows.count == 1 && result.rows[0].id == userID, "Prior-day prompt with current-day usage is hidden")
            try require(result.requestsByUserID[userID]?.map(\.id) == [value.requests[0].id], "Day boundary or replay counted in prompt cost")
            try require(result.requestsByUserID[userID]?.first?.usage.costIsIncomplete == true, "Unknown price became free")
            try require(result.analysis?.reported.total == 190 && result.analysis?.included.total == 0, "Exclusions or totals changed")
            let all = try TranscriptSearchResult.evaluate(.init(transcript: value))
            let tools = try TranscriptSearchResult.evaluate(.init(transcript: value, filter: .tools))
            try require(all.requestsByUserID[userID]?.count == 2 && tools.requestsByUserID[userID]?.count == 2, "Filter changed prompt accounting")
        }
        await check("Chat debug filters preserve billing totals and combine with search") {
            var transcript = try decode("claude", claude)
            let tool = transcript.events.firstIndex { $0.kind == .tool }!
            transcript.events[tool].isError = true
            transcript.events[tool].output = "Failure: permission denied"
            let all = try TranscriptSearchResult.evaluate(.init(transcript: transcript))
            let tools = try TranscriptSearchResult.evaluate(.init(transcript: transcript, filter: .tools))
            let errors = try TranscriptSearchResult.evaluate(.init(transcript: transcript, query: "permission", filter: .errors))
            try require(tools.rows.count == 2 && tools.rows.allSatisfy { $0.events[0].kind == .tool }, "Tool filter includes messages")
            try require(errors.rows.count == 1 && errors.rows[0].id == transcript.events[tool].id, "Error search lost its target")
            try require(all.analysis?.reported == tools.analysis?.reported && all.analysis?.reported == errors.analysis?.reported,
                        "Timeline filters changed session billing")
            let missing = try TranscriptSearchResult.evaluate(.init(transcript: transcript, query: "unmatched", filter: .errors))
            try require(missing.rows.isEmpty, "Error filter ignores the search query")
            try require(TranscriptSearchRequest(transcript: transcript) != .init(transcript: transcript, filter: .tools), "Filter changes do not refresh results")
        }
        await check("Chat usage: streamed Claude requests own parallel events once") {
            let value = try decode("claude", claude)
            try require(value.requests.count == 1 && value.requests[0].usage.total == 190, "Stream charged twice or final usage lost")
            try require(value.requests[0].eventIDs.count == 4, "Parallel tools not attributed to the same request")
            let summary = TranscriptUsageSummary(transcript: value, day: nil, policy: .init())
            try require(summary.tools.count == 1 && summary.tools[0].count == 2 && summary.tools[0].usage.total == 190, "Repeated tool charged twice")
        }
        await check("Chat usage: tool day follows its billable request when event time is absent") {
            var value = try decode("claude", claude)
            let day = UsageDay(date: date, timezone: "UTC")
            for index in value.events.indices where value.events[index].kind == .tool { value.events[index].timestamp = nil }
            let summary = TranscriptUsageSummary(transcript: value, day: day, policy: .init())
            try require(summary.tools.first?.count == 2 && summary.tools.first?.usage.total == 190, "Linked tools disappeared from the request day")
            let next = TranscriptUsageSummary(transcript: value, day: UsageDay(date: day.end, timezone: "UTC"), policy: .init())
            try require(next.tools.isEmpty, "Tool leaked into a day without its billable request")
        }
        await check("Chat usage: Codex counter duplicates, deltas, tiers and reasoning") {
            let value = try decode("codex", codex)
            try require(value.requests.count == 2, "Cumulative duplicate counted as a request")
            try require(value.requests[0].usage.input == 600 && value.requests[0].usage.cacheRead == 400 && value.requests[0].usage.total == 1100, "Cached/reasoning tokens duplicated")
            try require(value.requests[1].usage.total == 650 && value.requests[1].reasoning == 20 && value.requests[1].billing.speed == "standard", "Delta or changed tier lost")
            try require(value.requests[1].eventIDs.count == 1, "Tool result charged as a second tool invocation")
        }
        await check("Chat usage: Gemini cached overlap and explicitly recorded skills") {
            let value = try decode("gemini", gemini)
            try require(value.requests[0].usage.total == 1150 && value.requests[0].usage.input == 600 && value.requests[0].reasoning == 50, "Gemini token normalization")
            let summary = TranscriptUsageSummary(transcript: value, day: nil, policy: .init())
            try require(summary.tools.first?.id == "Skill: review", "Explicit skill identity lost")
            let exclusive = try decode("gemini", gemini.replacingOccurrences(of: "1150", with: "1550"))
            try require(exclusive.requests[0].usage.input == 1000 && exclusive.requests[0].usage.total == 1550, "Exclusive cache input changed")
        }
        await check("Chat usage: hidden reasoning-only request stays visible") {
            let value = try decode("codex", #"""
            {"type":"turn_context","payload":{"model":"gpt-chat-fixture"}}
            {"type":"event_msg","timestamp":"2026-10-01T12:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}
            """#)
            try require(value.requests.count == 1 && value.events.last?.isUsageOnly == true && value.messageCount == 0, "Billable hidden event disappeared or became a fake message")
            let search = try TranscriptSearchResult.evaluate(.init(transcript: value))
            try require(search.rows.count == 1, "Usage-only request hidden with system events")
        }
        await check("Chat usage: replayed Codex prefix excluded and missing parent is explicit") {
            let parent = try decode("codex", codex)
            let fork = #"{"type":"session_meta","payload":{"forked_from_id":"parent"}}"# + "\n" + codex
            let value = try decode("codex", fork, parent: parent)
            try require(value.requests.allSatisfy(\.isReplay), "Parent requests charged again")
            try require(TranscriptUsageSummary(transcript: value, day: nil, policy: .init()).reported.total == 0, "Replay leaks into total")
            let unknown = try decode("codex", fork)
            try require(unknown.usageUncertain && !unknown.notices.isEmpty, "Missing fork parent silently accepted")
        }
        await check("Chat usage: day boundaries, exclusion reference and strict reconciliation") {
            var value = try decode("claude", claude)
            value.requests[0].usage.cost = 0.00123
            value.requests[0].usage.costIsIncomplete = false
            let day = UsageDay(date: date, timezone: "Europe/Moscow")
            let summary = TranscriptUsageSummary(transcript: value, day: day, policy: .init(overrides: ["claude-chat-fixture": false]))
            try require(summary.included.total == 0 && summary.reported.total == 190, "Excluded reference amounts lost")
            try require(summary.reconciles(with: summary.reported, transcript: value), "Exact totals did not reconcile")
            var expected = summary.reported; expected.input += 1
            try require(!summary.reconciles(with: expected, transcript: value), "Token mismatch hidden")
            expected = summary.reported; expected.cost += 0.001
            try require(!summary.reconciles(with: expected, transcript: value), "Cost mismatch hidden")
            value.imported = true
            try require(!summary.reconciles(with: summary.reported, transcript: value), "Imported file claims report identity")
            value.requests[0].timestamp = day.end
            try require(TranscriptUsageSummary(transcript: value, day: day, policy: .init()).requests.isEmpty, "Upper day boundary included")
            value.requests[0].timestamp = nil
            let undated = TranscriptUsageSummary(transcript: value, day: day, policy: .init())
            try require(undated.requests.isEmpty && undated.unknownDates == 1, "Unknown date guessed into selected day")
        }
        await check("Chat usage: malformed usage never becomes a priced zero") {
            let value = try decode("claude", claude.replacingOccurrences(of: "\"input_tokens\":100", with: "\"input_tokens\":true"))
            try require(value.requests.isEmpty && value.usageUncertain, "Boolean accepted as a token")
            let unsupported = try decode("hermes", claude)
            try require(!unsupported.usageSupported && unsupported.requests.isEmpty, "Unsupported source fabricated usage")
        }
        await check("Chat usage: Claude replay priority, advisor calls and Fast exclusion identity") {
            let value = try decode("claude", #"""
            {"type":"assistant","timestamp":"2026-10-01T12:00:00Z","requestId":"parent","message":{"id":"a","role":"assistant","model":"claude-chat-fixture","content":"Answer","usage":{"input_tokens":100,"output_tokens":20,"speed":"fast","iterations":[{"type":"advisor_message","model":"claude-advisor","input_tokens":30,"output_tokens":10}]}}}
            {"type":"assistant","timestamp":"2026-10-01T12:00:00Z","isSidechain":true,"requestId":"copy","message":{"id":"a","role":"assistant","model":"claude-chat-fixture","content":"Copied answer","usage":{"input_tokens":99999,"output_tokens":20}}}
            """#)
            try require(value.requests.count == 2 && value.requests[0].usage.total == 120 && value.requests[1].usage.total == 40, "Replay replaced parent or advisor lost")
            let summary = TranscriptUsageSummary(transcript: value, day: nil, policy: .init(overrides: ["claude-chat-fixture-fast": false]))
            try require(summary.included.total == 40 && summary.reported.total == 160, "Fast model exclusion differs from CLI identity")
            let again = try TranscriptUsageParser.annotate(value, source: "claude")
            try require(again.requests.count == value.requests.count, "Repeated annotation duplicates charges")
        }
        await check("Chat usage: Codex aliases, cache writes and empty total normalization") {
            let value = try decode("codex", #"""
            {"type":"turn_context","payload":{"model":"gpt-chat-fixture"}}
            {"type":"event_msg","timestamp":"2026-10-01T12:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"prompt_tokens":1000,"cached_tokens":400,"cache_write_input_tokens":200,"completion_tokens":100,"reasoning_tokens":80,"total_tokens":0}}}}
            """#)
            try require(value.requests[0].usage.input == 400 && value.requests[0].usage.cacheCreate == 200 && value.requests[0].usage.total == 1100, "Alias/write tokens lost")
        }
        await check("Chat usage: three-source rates persist and upgrade offline Claude cache") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let catalog = Data(#"{"claude-fixture":{"input_cost_per_token":0.1,"output_cost_per_token":0.2},"gpt-fixture":{"input_cost_per_token":0.2,"output_cost_per_token":0.3},"gemini-fixture":{"input_cost_per_token":0.3,"output_cost_per_token":0.4}}"#.utf8)
            let legacy = ClaudePricingCache(directory: directory, fetch: { _ in .init(status: 200, data: catalog) })
            let first = try await legacy.refresh()
            let upgraded = ClaudePricingCache(directory: directory, includeTranscriptModels: true, fetch: { _ in throw URLError(.notConnectedToInternet) })
            let offline = try await upgraded.refresh()
            try require(offline == first && offline.count == 1, "Upgrade discarded cached Claude tariff offline")
            let online = ClaudePricingCache(directory: directory, includeTranscriptModels: true, fetch: { _ in .init(status: 200, data: catalog) })
            let all = try await online.refresh()
            let restarted = ClaudePricingCache(directory: directory, includeTranscriptModels: true, fetch: { _ in throw URLError(.notConnectedToInternet) })
            let restored = try await restarted.refresh()
            try require(all.count == 3 && all == restored, "Codex/Gemini tariffs lost after offline restart")
        }
        await check("Chat usage: pricing receipts freeze overrides without source paths") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let archive = TranscriptPricingArchive(directory: directory)
            let config = Data(#"{"defaults":{"pricingOverrides":{"m":{"inputCostPerToken":1}},"since":"19990101","secret":"private"},"commands":{"session":{"pricingOverrides":{"m":{"outputCostPerToken":2}}}},"claude":{"commands":{"session":{"pricingOverrides":{"m":{"inputCostPerToken":3}}}}},"pi":{"stores":[{"path":"/secret"}]}}"#.utf8)
            let key = try archive.save(configuration: config)
            let repeated = try archive.save(configuration: config)
            try require(key == repeated, "Identical rates did not share receipt")
            let claude = try archive.configuration(key: key, source: "claude")
            let codex = try archive.configuration(key: key, source: "codex")
            let text = String(decoding: claude, as: UTF8.self)
            try require(!text.contains("secret") && !text.contains("since") && !text.contains("stores"), "Non-pricing config leaked")
            func input(_ data: Data) throws -> Double {
                let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                return (TranscriptJSON.object(TranscriptJSON.object(TranscriptJSON.object(root["defaults"])["pricingOverrides"])["m"])["inputCostPerToken"] as! NSNumber).doubleValue
            }
            let claudeInput = try input(claude), codexInput = try input(codex)
            try require(claudeInput == 3 && codexInput == 1, "Focused/unified config priority changed")
        }
        await check("Chat usage: isolated billing contains no messages, arguments or results") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let value = try decode("claude", claude)
            try TranscriptCostService.prepare(value.requests, source: "claude", root: directory, configuration: Data("{}".utf8))
            let file = directory.appendingPathComponent("projects/chat/request-1.jsonl")
            let text = try String(contentsOf: file, encoding: .utf8)
            try require(!text.contains("Private") && !text.contains("secret") && !text.contains("tool_use") && text.contains("input_tokens"), "Transcript leaked into calculator")
        }
    }

    static func liveCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = TranscriptPricingArchive(directory: directory)
        let rates: [String: Double] = ["inputCostPerToken": 0.000001, "outputCostPerToken": 0.000002,
            "cacheCreationInputTokenCost": 0.00000125, "cacheReadInputTokenCost": 0.0000005, "fastMultiplier": 2,
            "inputCostPerTokenAbove200kTokens": 0.000002, "outputCostPerTokenAbove200kTokens": 0.000004]
        let models = ["claude-chat-fixture", "gpt-chat-fixture", "gemini-chat-fixture"]
        let config = try JSONSerialization.data(withJSONObject: ["defaults": ["pricingOverrides": Dictionary(uniqueKeysWithValues: models.map { ($0, rates) })]])
        let key = try archive.save(configuration: config)
        let service = TranscriptCostService(archive: archive)
        let cacheWrite = #"""
        {"type":"turn_context","payload":{"model":"gpt-chat-fixture"}}
        {"type":"event_msg","timestamp":"2026-10-01T12:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":200,"output_tokens":100,"total_tokens":1100}}}}
        """#
        let oneHour = #"{"type":"assistant","timestamp":"2026-10-01T12:00:00Z","message":{"id":"one","role":"assistant","model":"claude-chat-fixture","usage":{"input_tokens":100,"output_tokens":10,"speed":"fast","cache_creation_input_tokens":200,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":100}}}}"#
        let long = #"{"type":"assistant","timestamp":"2026-10-01T12:00:00Z","message":{"id":"long","role":"assistant","model":"claude-chat-fixture","usage":{"input_tokens":300000,"output_tokens":100,"speed":"fast"}}}"#
        for (source, fixture, expected) in [("claude", claude, 0.00022), ("codex", codex, 0.00265), ("gemini", gemini, 0.0011),
                                            ("codex", cacheWrite, 0.00105), ("claude", oneHour, 0.00089), ("claude", long, 0.8004)] {
            let original = try decode(source, #"{"role":"user","content":"Billing prompt"}"# + "\n" + fixture)
            let priced = try await service.price(original, source: source, customPath: "", pricingKey: key)
            let summary = TranscriptUsageSummary(transcript: priced, day: nil, policy: .init())
            let user = priced.events.first { $0.kind == .user }!
            let userRequests = try TranscriptSearchResult.evaluate(.init(transcript: priced)).requestsByUserID[user.id] ?? []
            try require(userRequests.count == priced.requests.count && userRequests.reduce(.zero, { $0 + $1.usage }) == summary.reported,
                        "\(source) pricing lost prompt ownership or changed its aggregate")
            if !priced.requests.allSatisfy(\.priced) {
                let debug = directory.appendingPathComponent("debug")
                try TranscriptCostService.prepare(original.requests, source: source, root: debug, configuration: archive.configuration(key: key, source: source))
                let executable = try await CCUsageExecutableResolver().resolve(customPath: "")
                var environment = ProcessRunner.environment(for: executable)
                environment[TranscriptSource.all[source]!.variable] = debug.path
                let result = try await ProcessRunner().run(executable: executable, arguments: [source, "session", "--json", "--offline", "--config", debug.appendingPathComponent("ccusage.json").path], environment: environment)
                print("  Diagnostic synthetic output: \(String(decoding: result.stdout, as: UTF8.self))")
                if source == "claude" { print(try String(contentsOf: debug.appendingPathComponent("projects/chat/request-1.jsonl"), encoding: .utf8)) }
            }
            try require(priced.requests.allSatisfy(\.priced) && summary.reported.costIsIncomplete != true,
                        "Missing per-request prices for \(source): \(priced.requests.map { "\($0.id) priced=\($0.priced) usage=\($0.usage)" })")
            try require(abs(summary.reported.cost - expected) < 1e-8, "Wrong \(source) cost: \(summary.reported.cost), expected \(expected)")
            try require(summary.reported.total == original.requests.reduce(0, { $0 + $1.usage.total }), "\(source) normalized tokens differ from CLI")
            print("  \(source): \(priced.requests.count) requests, \(summary.reported.total) tokens, $\(summary.reported.cost)")
            let reference = directory.appendingPathComponent("reference-" + source)
            let logs = reference.appendingPathComponent(source == "claude" ? "projects/chat" : source == "codex" ? "sessions" : "chats")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try Data(fixture.utf8).write(to: logs.appendingPathComponent("request-reference.jsonl"))
            let config = try archive.configuration(key: key, source: source)
            try config.write(to: reference.appendingPathComponent("ccusage.json"))
            let executable = try await CCUsageExecutableResolver().resolve(customPath: "")
            var environment = ProcessRunner.environment(for: executable)
            environment[TranscriptSource.all[source]!.variable] = reference.path
            var arguments = [source, "session", "--json", "--offline", "--config", reference.appendingPathComponent("ccusage.json").path]
            if source != "codex" { arguments += ["--mode", "calculate"] }
            let raw = try await ProcessRunner().run(executable: executable, arguments: arguments, environment: environment)
            let baseline = try TranscriptCostService.decode(raw.stdout, source: source).values.reduce(TokenUsage.zero, +)
            try require(TokenCategory.allCases.allSatisfy { baseline.value(for: $0) == summary.reported.value(for: $0) }
                        && abs(baseline.cost - summary.reported.cost) < 1e-9,
                        "\(source) request sum differs from whole original log")
        }
    }
}
