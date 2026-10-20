import Foundation
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#endif

private struct AccountingFailure: Error, CustomStringConvertible { var description: String }
struct AccountingFixturePrices: ClaudePricingProviding {
    var multiplier = 1.0
    func refresh() async throws -> ClaudePricingOverrides {
        let normal = ["inputCostPerToken": 2e-6, "outputCostPerToken": 1e-5,
                      "cacheCreationInputTokenCost": 2.5e-6, "cacheReadInputTokenCost": 2e-7].mapValues { $0 * multiplier }
        return ["openrouter/anthropic/claude-sonnet-5.5": normal,
                "openrouter/anthropic/claude-sonnet-5.5:batch": normal.mapValues { $0 / 2 }]
    }
}

struct CostStatePrices: ClaudePricingProviding {
    func refresh() async throws -> ClaudePricingOverrides {
        [ClaudeAccountingScenarios.costStateModel: ClaudeAccountingScenarios.costStateRates]
    }
}

enum ClaudeAccountingScenarios {
    static func fixtures() throws -> [[String: Any]] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/claude-cost-parity.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
    }
    static func decode(_ rows: [[String: Any]]) throws -> SessionTranscript {
        var decoder = TranscriptDecoder(source: "claude")
        for row in rows { decoder.append(row) }
        return try TranscriptUsageParser.annotate(.init(events: decoder.finish()), source: "claude")
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AccountingFailure(description: message) }
    }

    // MARK: Claude Code 2.1.280 cost-state sessions

    static let costStateModel = "claude-opus-4-6"
    static let costStateRates: [String: Double] = ["inputCostPerToken": 5e-6, "outputCostPerToken": 2.5e-5,
                                                   "cacheReadInputTokenCost": 5e-7, "cacheCreationInputTokenCost": 6.25e-6]
    static func costStateSessions() throws -> [String: [[[String: Any]]]] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/claude-cost-state.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var result: [String: [[[String: Any]]]] = [:]
        for (index, session) in (root["sessions"] as! [[String: Any]]).enumerated() {
            let sid = String(format: "00000000-0000-4000-8000-%012d", 200 + index)
            result[session["name"] as! String] = (session["files"] as! [[String: Any]]).map { file in
                (file["rows"] as! [[String: Any]]).map { costStateRow($0, sessionID: sid) }
            }
        }
        return result
    }
    static func costStateID(_ files: [[[String: Any]]]) -> String { files[0].compactMap { $0["sessionId"] as? String }.first! }
    /// Expands the compact fixture into Claude Code's own row shapes.
    static func costStateRow(_ row: [String: Any], sessionID sid: String) -> [String: Any] {
        switch row["t"] as! String {
        case "c":
            let totals = row["mu"] as! [[String: Any]]
            return ["type": "cost-state", "sessionId": sid, "modelUsage": totals.isEmpty ? [:] : [costStateModel: totals[0]]]
        case "u": return ["type": "user", "sessionId": sid, "timestamp": row["at"]!, "message": ["role": "user", "content": "Synthetic prompt"]]
        case "s": return ["type": "system", "sessionId": sid, "timestamp": row["at"]!]
        default:
            let counts = row["u"] as! [Int]
            var usage: [String: Any] = ["input_tokens": counts[0], "output_tokens": counts[1],
                                        "cache_creation_input_tokens": counts[2], "cache_read_input_tokens": counts[3]]
            if row["p"] == nil {
                usage["speed"] = "standard"; usage["service_tier"] = "standard"
                if let split = row["x"] as? [Int] { usage["cache_creation"] = ["ephemeral_5m_input_tokens": split[0], "ephemeral_1h_input_tokens": split[1]] }
            }
            var message: [String: Any] = ["id": row["m"]!, "role": "assistant", "model": row["y"] == nil ? costStateModel : "<synthetic>",
                                          "content": [["type": "text", "text": "Synthetic response"]], "usage": usage]
            if let stop = row["r"] { message["stop_reason"] = stop }
            var result: [String: Any] = ["type": "assistant", "sessionId": sid, "timestamp": row["at"]!, "requestId": row["q"]!,
                                         "isSidechain": row["sc"] != nil, "message": message]
            if row["e"] != nil { result["isApiErrorMessage"] = true }
            return result
        }
    }
    static func decode(files: [[[String: Any]]]) throws -> SessionTranscript {
        var decoder = TranscriptDecoder(source: "claude")
        for (index, rows) in files.enumerated() {
            decoder.origin = index == 0 ? nil : "subagents/agent-\(index).jsonl"
            for row in rows { decoder.append(row) }
        }
        var transcript = try TranscriptUsageParser.annotate(.init(events: decoder.finish()), source: "claude")
        transcript.claudeSessionID = costStateID(files)
        return transcript
    }
    /// Claude's own price of the visible requests, with resolved TTL splits.
    static func claudeCost(_ transcript: SessionTranscript, rates: [String: Double], day: UsageDay? = nil) -> Double? {
        var total = 0.0
        for request in transcript.requests where !request.isReplay && (day.map { request.belongs(to: $0) } ?? true) {
            guard let cost = ClaudeCacheTTL.cost(request, rates: rates) else { return nil }
            total += cost
        }
        return total
    }
    static func tokens(_ usage: TokenUsage) -> [Int64] { [usage.input, usage.output, usage.cacheRead, usage.cacheCreate] }
    static func snapshotTokens(_ files: [[[String: Any]]], index: Int) -> [Int64] {
        let totals = files[0].filter { $0["type"] as? String == "cost-state" }.map { ($0["modelUsage"] as! [String: [String: Any]])[costStateModel]! }
        let value = totals[index]
        return ["inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"].map { Int64(value[$0] as! Int) }
    }
    static func placeholder(_ id: String, at: String, sid: String = "00000000-0000-4000-8000-000000000299") -> [String: Any] {
        ["type": "assistant", "sessionId": sid, "requestId": id, "timestamp": at, "isSidechain": true,
         "message": ["id": "msg-" + id, "role": "assistant", "model": costStateModel, "content": [["type": "text", "text": "Synthetic"]],
                     "usage": ["input_tokens": 0, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0]]]
    }
    static func response(_ id: String, at: String, tokens: [Int], sid: String = "00000000-0000-4000-8000-000000000299") -> [String: Any] {
        ["type": "assistant", "sessionId": sid, "requestId": id, "timestamp": at,
         "message": ["id": "msg-" + id, "role": "assistant", "model": costStateModel, "stop_reason": "end_turn",
                     "content": [["type": "text", "text": "Synthetic"]],
                     "usage": ["input_tokens": tokens[0], "output_tokens": tokens[1], "cache_read_input_tokens": tokens[2],
                               "cache_creation_input_tokens": tokens[3], "speed": "standard", "service_tier": "standard"]]]
    }
    static func total(_ sid: String = "00000000-0000-4000-8000-000000000299", models: [String: [String: Any]]) -> [String: Any] {
        ["type": "cost-state", "sessionId": sid, "modelUsage": models]
    }
    static func modelTotal(_ tokens: [Int], cost: Double) -> [String: Any] {
        ["inputTokens": tokens[0], "outputTokens": tokens[1], "cacheReadInputTokens": tokens[2], "cacheCreationInputTokens": tokens[3],
         "thinkingTokens": 0, "webSearchRequests": 0, "costUSD": cost]
    }
    static func price(_ tokens: [Int], hour: Int = 0) -> Double {
        Double(tokens[0]) * 5e-6 + Double(tokens[1]) * 2.5e-5 + Double(tokens[2]) * 5e-7 + Double(tokens[3] - hour) * 6.25e-6 + Double(hour) * 1e-5
    }

    static func runCostState(check: (String, () async throws -> Void) async -> Void) async {
        await check("Claude accounting: subagent placeholders are unknown, never free, and real counters replace them") {
            let main = response("main", at: "2026-10-07T10:00:00Z", tokens: [2, 10, 0, 100])
            var value = try decode(files: [[main], [placeholder("agent", at: "2026-10-07T10:00:01Z"), placeholder("agent", at: "2026-10-07T10:00:02Z")]])
            let agent = value.requests.first { $0.telemetryIdentity?.requestID == "agent" }
            try require(value.requests.count == 2 && agent?.countersUnknown == true && agent?.usage.total == 0, "Placeholder became a known zero")
            try require(value.hasUnknownCounters(on: nil) && !value.usageUncertain, "Unknown subagent counters hidden or misreported")
            value = try decode(files: [[main], [placeholder("agent", at: "2026-10-07T10:00:01Z"),
                response("agent", at: "2026-10-07T10:00:03Z", tokens: [1, 5, 100, 20]), placeholder("agent", at: "2026-10-07T10:00:04Z")]])
            try require(!value.hasUnknownCounters(on: nil) && tokens(value.requests.reduce(.zero) { $0 + $1.usage }) == [3, 15, 100, 120],
                        "Final subagent counters lost to a placeholder")
            let zero = try decode(files: [[response("main", at: "2026-10-07T10:00:00Z", tokens: [0, 0, 0, 0])]])
            try require(!zero.hasUnknownCounters(on: nil), "A real zero response marked unknown")
            let parsed = TranscriptUsageParser.isPlaceholder(["input_tokens": 0, "output_tokens": 0], message: ["stop_reason": "end_turn"])
            try require(!parsed, "A finished response counted as a placeholder")
        }
        await check("Claude accounting: cost-state equals /usage including placeholders and background calls") {
            let files = try costStateSessions()["single"]!
            var value = try decode(files: files)
            try require(value.claudeSnapshotValidated && !value.usageUncertain && !value.hasUnknownCounters(on: nil), "Session total rejected")
            try require(value.requests.filter(\.isSupplemental).count == 1 && tokens(value.requests.reduce(.zero) { $0 + $1.usage }) == snapshotTokens(files, index: 0),
                        "Session tokens differ from /usage")
            ClaudeSessionAccounting.resolveCacheTTL(&value, rates: [costStateModel: costStateRates])
            let remainder = value.requests.first(where: \.isSupplemental)!
            try require(remainder.billing.cacheCreation == ["ephemeral_5m_input_tokens": 89362, "ephemeral_1h_input_tokens": 0], "Remainder TTL not solved")
            let cost = claudeCost(value, rates: costStateRates)
            try require(cost.map { abs($0 - 3.090241) < 1e-6 } == true, "Session cost \(String(describing: cost)) differs from /usage $3.090241")
        }
        await check("Claude accounting: a resumed session keeps each day's total and the final cumulative total") {
            let files = try costStateSessions()["resumed"]!
            var value = try decode(files: files)
            ClaudeSessionAccounting.resolveCacheTTL(&value, rates: [costStateModel: costStateRates])
            try require(value.claudeSnapshotValidated && !value.usageUncertain && !value.hasUnknownCounters(on: nil), "Resumed totals rejected")
            let first = UsageDay(date: TranscriptJSON.date("2026-10-03T12:00:00Z")!, timezone: "UTC")
            let summary = TranscriptUsageSummary(transcript: value, day: first, policy: .init())
            try require(tokens(summary.reported) == snapshotTokens(files, index: 0) && summary.unknownDates == 0, "First day differs from its /usage")
            try require(claudeCost(value, rates: costStateRates, day: first).map { abs($0 - 16.065282) < 1e-6 } == true, "First day cost differs from $16.07")
            let whole = TranscriptUsageSummary(transcript: value, day: nil, policy: .init())
            try require(tokens(whole.reported) == snapshotTokens(files, index: 1), "Cumulative total lost across the resume")
            try require(claudeCost(value, rates: costStateRates).map { abs($0 - 43.2710545) < 1e-6 } == true, "Cumulative cost differs")
            for offset in 1...2 {
                let later = TranscriptUsageSummary(transcript: value, day: first.adding(days: offset), policy: .init())
                try require(later.unknownDates == 0 && later.reported.total > 0, "Resumed day lost or left unassigned")
            }
        }
        await check("Claude accounting: a restarted counter keeps its segment unknown and later totals exact") {
            let files = try costStateSessions()["restarted"]!
            let value = try decode(files: files)
            let day = UsageDay(date: TranscriptJSON.date("2026-10-06T12:00:00Z")!, timezone: "UTC")
            try require(value.claudeSnapshotValidated && value.requests.allSatisfy { !$0.isSupplemental }, "Restarted counter invented a remainder")
            try require(value.usageIsUncertain(on: day) && value.hasUnknownCounters(on: day), "Unexplained segment presented as complete")
            try require(value.requests.contains { $0.snapshotCovered } && value.requests.contains { $0.countersUnknown && !$0.snapshotCovered },
                        "Later segment not covered or earlier placeholders resolved")
        }
        await check("Claude accounting: totals without calls, background-only models and repeated totals") {
            let empty = try decode(files: [[response("main", at: "2026-10-07T10:00:00Z", tokens: [0, 0, 0, 0]), total(models: [:])]])
            try require(!empty.usageUncertain && empty.claudeSnapshotValidated && empty.requests.allSatisfy { !$0.isSupplemental }, "Empty total rejected")
            let haiku = "claude-haiku-4-5-20251001"
            let rows = [response("main", at: "2026-10-07T10:00:00Z", tokens: [2, 10, 0, 100]),
                        total(models: [costStateModel: modelTotal([2, 10, 0, 100], cost: price([2, 10, 0, 100])), haiku: modelTotal([700, 30, 0, 0], cost: 0.00085)])]
            let background = try decode(files: [rows, []])
            let extra = background.requests.filter(\.isSupplemental)
            try require(!background.usageUncertain && extra.count == 1 && extra[0].model == haiku && extra[0].usage.input == 700, "Background-only model lost")
            let repeated = try decode(files: [rows + [rows[1], rows[1]]])
            try require(repeated.requests.filter(\.isSupplemental).count == 1 && !repeated.usageUncertain, "Repeated cumulative total billed twice")
        }
        await check("Claude accounting: cache-write TTL is solved from Claude's cost, otherwise disclosed") {
            let rates = costStateRates
            try require(ClaudeCacheTTL.split(cost: price([1, 2, 3, 100]), input: 1, output: 2, read: 3, write: 100, rates: rates)
                == ["ephemeral_5m_input_tokens": 100, "ephemeral_1h_input_tokens": 0], "5-minute write not recognised")
            try require(ClaudeCacheTTL.split(cost: price([1, 2, 3, 100], hour: 40), input: 1, output: 2, read: 3, write: 100, rates: rates)
                == ["ephemeral_5m_input_tokens": 60, "ephemeral_1h_input_tokens": 40], "Mixed TTL not solved")
            try require(ClaudeCacheTTL.split(cost: price([1, 2, 3, 100]) + 0.0001234, input: 1, output: 2, read: 3, write: 100, rates: rates) == nil,
                        "Inconsistent cost produced a TTL")
            var tiered = rates; tiered["inputCostPerTokenAbove200kTokens"] = 1e-5
            try require(ClaudeCacheTTL.split(cost: price([1, 2, 3, 100]), input: 1, output: 2, read: 3, write: 100, rates: tiered) == nil, "Tiered tariff solved from an aggregate")
            let main = [1, 10, 0, 100]
            let rows = [response("main", at: "2026-10-07T10:00:00Z", tokens: main), placeholder("agent", at: "2026-10-07T10:00:05Z"),
                        total(models: [costStateModel: modelTotal([101, 20, 0, 1100], cost: price(main) + price([100, 10, 0, 1000], hour: 400))]),
                        response("after", at: "2026-10-07T10:01:00Z", tokens: [1, 1, 0, 0])]
            var value = try decode(files: [rows])
            ClaudeSessionAccounting.resolveCacheTTL(&value, rates: [costStateModel: rates])
            let remainder = value.requests.first(where: \.isSupplemental)
            try require(remainder?.billing.cacheCreation == ["ephemeral_5m_input_tokens": 600, "ephemeral_1h_input_tokens": 400], "Remainder 1h writes priced at 5m")
            try require(!value.notices.contains(L10n.text("Для записи кэша без разбивки TTL применена ставка 5 минут.")), "Solved TTL still disclosed as fallback")
            var unpriced = try decode(files: [rows])
            ClaudeSessionAccounting.resolveCacheTTL(&unpriced, rates: [:])
            try require(unpriced.notices.contains(L10n.text("Для записи кэша без разбивки TTL применена ставка 5 минут.")), "Unsolved TTL not disclosed")
        }
    }
    static func run(check: (String, () async throws -> Void) async -> Void) async {
        await check("Claude accounting: both captured regressions retain cache writes and deduplicate fragments") {
            for fixture in try fixtures() {
                let value = try decode(fixture["records"] as! [[String: Any]])
                let main = value.requests.filter { !$0.isSupplemental }
                let totals = main.reduce(TokenUsage.zero) { $0 + $1.usage }
                try require(main.count == 24 && totals.input == 48, "Fragment deduplication changed")
                try require(totals.cacheCreate == (fixture["name"] as? String == "telemetry" ? 133835 : 133967), "Cache writes lost")
                let supplemental = value.requests.filter(\.isSupplemental)
                if fixture["name"] as? String == "telemetry" {
                    try require(supplemental.count == 1 && supplemental[0].usage.input == 2470
                        && supplemental[0].usage.output == 190 && supplemental[0].eventIDs.isEmpty
                        && supplemental[0].userEventID == nil, "Background costs lost or attached to a user message")
                } else { try require(supplemental.isEmpty, "Invented overhead without a snapshot") }
            }
        }
        await check("Claude accounting: repeated snapshots replace totals; old snapshots do not erase new calls") {
            var rows = try fixtures()[1]["records"] as! [[String: Any]]
            rows.append(rows.last!)
            var value = try decode(rows)
            try require(value.requests.filter(\.isSupplemental).count == 1, "Repeated total billed twice")
            var later = rows[1]
            later["requestId"] = "later-request"; later["uuid"] = "later-fragment"
            var message = later["message"] as! [String: Any]; message["id"] = "later-message"
            message["usage"] = ["input_tokens": 3, "output_tokens": 7]
            later["message"] = message; later["timestamp"] = "2026-10-07T13:00:00Z"
            rows.append(later)
            value = try decode(rows)
            try require(value.requests.filter { !$0.isSupplemental }.count == 25
                && value.requests.filter(\.isSupplemental).first?.usage.input == 2470, "Stale snapshot replaced newer usage")
        }
        await check("Claude accounting: supplemental pricing strips filters and unrelated configuration") {
            let raw: [String: Any] = ["defaults": ["since": "2099-01-01", "config": "/private/example",
                "pricingOverrides": ["model": ["inputCostPerToken": 2]]],
                "claude": ["commands": ["session": ["pricingOverrides": ["model": ["outputCostPerToken": 10]]]]]]
            let configs = try TranscriptPricingArchive.configurations(configuration: JSONSerialization.data(withJSONObject: raw))
            let claude = configs["claude"] as! [String: Any], options = claude["defaults"] as! [String: Any]
            let rates = options["pricingOverrides"] as! [String: [String: Any]]
            try require(options.count == 1 && rates["model"]?.count == 2, "Filters leaked or command tariffs lost")
        }
        await check("Claude accounting: foreign, malformed and incompatible snapshot counters cannot add charges") {
            let source = try fixtures()[1]["records"] as! [[String: Any]]
            for mode in 0..<4 {
                var rows = source
                var snapshot = rows.removeLast()
                if mode == 0 { snapshot["sessionId"] = "another-session" }
                else {
                    var models = snapshot["modelUsage"] as! [String: [String: Any]]
                    let key = models.keys.first!
                    models[key]![mode == 1 ? "inputTokens" : mode == 2 ? "cacheReadInputTokens" : "webSearchRequests"] = mode == 1 ? -1 : 1
                    snapshot["modelUsage"] = models
                }
                rows.append(snapshot)
                let value = try decode(rows)
                try require(value.requests.allSatisfy { !$0.isSupplemental } && value.usageUncertain, "Unvalidated snapshot accepted")
            }
        }
        await check("Claude accounting: large logs stream accounting fields without retaining message bodies") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("accounting-large-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("accounting-fixture.jsonl")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            let payload = String(repeating: "large-private-tool-body", count: 50_000)
            var large = try JSONSerialization.data(withJSONObject: ["type": "progress", "data": payload]); large.append(10)
            for _ in 0..<34 { try handle.write(contentsOf: large) }
            let rows = try fixtures()[1]["records"] as! [[String: Any]]
            for row in rows {
                var data = try JSONSerialization.data(withJSONObject: row); data.append(10)
                try handle.write(contentsOf: data)
            }
            try handle.close()
            let expected = try decode(rows)
            let parsed = try ClaudeAccountingService.read(file, sessionID: "accounting-fixture")!
            try require(parsed.requests.count == expected.requests.count && !parsed.usageUncertain,
                        "A valid log larger than 32 MiB became incomplete")
            try require(parsed.requests.reduce(TokenUsage.zero) { $0 + $1.usage } == expected.requests.reduce(TokenUsage.zero) { $0 + $1.usage },
                        "Streaming changed accounting totals")
            try require(!TranscriptUsageParser.records(parsed).contains { $0.text.contains("large-private-tool-body") }, "Accounting retained message bodies")
        }
        await check("Claude accounting: cumulative overhead crossing midnight stays out of arbitrary daily buckets") {
            var rows = try fixtures()[1]["records"] as! [[String: Any]]
            rows[0]["timestamp"] = "2026-10-06T23:59:00Z"
            let value = try decode(rows)
            let day = UsageDay(date: TranscriptJSON.date("2026-10-07T12:00:00Z")!, timezone: "UTC")
            let summary = TranscriptUsageSummary(transcript: value, day: day, policy: .init())
            try require(summary.reported.input == 48 && summary.unknownDates == 1, "Whole cumulative overhead assigned to final day")
            let whole = TranscriptUsageSummary(transcript: value, day: nil, policy: .init())
            try require(whole.reported.input == 2518, "Full session overhead was lost")
        }
        await runCostState(check: check)
    }

    static func liveCheck(executablePath: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("llmusage-accounting-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("claude/projects/synthetic")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent("claude").path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
        // The focused report and pricing use the real helper. The unrelated
        // source scan is stubbed, so --all cannot inspect personal agent logs.
        let wrapper = root.appendingPathComponent("ccusage-test")
        let quoted = "'" + executablePath.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let script = "#!/bin/sh\ncase \"$1\" in\n session) printf '%s\\n' '{\"session\":[]}' ;;\n --version) exec " + quoted + " \"$@\" ;;\n *) exec " + quoted + " \"$@\" --offline ;;\nesac\n"
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let day = UsageDay(date: TranscriptJSON.date("2026-10-07T12:00:00Z")!, timezone: "UTC")
        for fixture in try fixtures() {
            let rows = fixture["records"] as! [[String: Any]]
            let data = try rows.reduce(into: Data()) { result, row in
                result += try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); result.append(10)
            }
            try data.write(to: logs.appendingPathComponent("accounting-fixture.jsonl"))
            let archive = TranscriptPricingArchive(directory: root.appendingPathComponent("receipts"))
            let service = CCUsageService(runtime: nil, pricing: AccountingFixturePrices(), pricingArchive: archive, environment: environment)
            for mode in [UsageUpdateMode.claudeOnly, .allAgents] {
                let report = try await service.fetch(day: day, customPath: wrapper.path, mode: mode)
                let expected = fixture["expectedSessionCost"] as! Double
                try require(report.sessions.count == 1, "Synthetic session missing")
                let session = report.sessions[0]
                try require(abs(session.usage.cost - expected) < 1e-10 && session.usage.costIsIncomplete != true,
                            "Session total mismatch: \(session.usage) != \(expected)")
                var transcript = try decode(rows)
                let pricing = TranscriptCostService(runtime: nil, archive: archive)
                transcript = try await pricing.price(transcript, source: "claude", customPath: wrapper.path, pricingKey: report.pricingKey)
                let summary = TranscriptUsageSummary(transcript: transcript, day: day, policy: .init())
                try require(summary.reconciles(with: session.usage, transcript: transcript), "Chat and report do not reconcile")
            }
            // Prices come from the same configured tariff, not snapshot costUSD.
            let overridden = CCUsageService(runtime: nil, pricing: AccountingFixturePrices(multiplier: 2), pricingArchive: archive, environment: environment)
            let report = try await overridden.fetch(day: day, customPath: wrapper.path)
            try require(abs(report.sessions[0].usage.cost - 2 * (fixture["expectedSessionCost"] as! Double)) < 1e-10,
                        "Snapshot cost bypassed custom tariffs")
        }
        try await costStateLiveCheck(executablePath: executablePath)
    }

    /// Daily reports of real Claude Code 2.1.280 sessions without telemetry:
    /// cost-state totals, subagent placeholders, resume and a restarted counter.
    static func costStateLiveCheck(executablePath: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("llmusage-cost-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("claude/projects/synthetic")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent("claude").path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
        let wrapper = root.appendingPathComponent("ccusage-test")
        let quoted = "'" + executablePath.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let script = "#!/bin/sh\ncase \"$1\" in\n session) printf '%s\\n' '{\"session\":[]}' ;;\n --version) exec " + quoted + " \"$@\" ;;\n *) exec " + quoted + " \"$@\" --offline ;;\nesac\n"
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let sessions = try costStateSessions()
        for files in sessions.values {
            let sid = costStateID(files)
            for (index, rows) in files.enumerated() {
                let data = try rows.reduce(into: Data()) { result, row in
                    result += try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); result.append(10)
                }
                let file = index == 0 ? logs.appendingPathComponent(sid + ".jsonl")
                    : logs.appendingPathComponent(sid + "/subagents/agent-\(index).jsonl")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
            }
        }
        let archive = TranscriptPricingArchive(directory: root.appendingPathComponent("receipts"))
        let service = CCUsageService(runtime: nil, pricing: CostStatePrices(), pricingArchive: archive, environment: environment)
        for (name, date, cost, snapshot) in [("single", "2026-10-07T12:00:00Z", 3.090241, 0), ("resumed", "2026-10-03T12:00:00Z", 16.065282, 0)] {
            let day = UsageDay(date: TranscriptJSON.date(date)!, timezone: "UTC")
            let files = sessions[name]!
            for mode in [UsageUpdateMode.claudeOnly, .allAgents] {
                let report = try await service.fetch(day: day, customPath: wrapper.path, mode: mode)
                guard let session = report.sessions.first(where: { $0.rawID == costStateID(files) }) else { throw AccountingFailure(description: "\(name): session missing") }
                try require(abs(session.usage.cost - cost) < 1e-6 && session.usage.costIsIncomplete != true,
                            "\(name): daily total \(session.usage.cost) differs from /usage \(cost); reasons \(session.costReasons ?? [])")
                try require(tokens(session.usage) == snapshotTokens(files, index: snapshot), "\(name): daily tokens differ from /usage")
            }
            let report = try await service.fetch(day: day, customPath: wrapper.path)
            let session = report.sessions.first { $0.rawID == costStateID(files) }!
            let transcript = try await TranscriptService(environment: environment).load(session: session)
            let priced = try await TranscriptCostService(runtime: nil, archive: archive).price(transcript, source: "claude", customPath: wrapper.path, pricingKey: report.pricingKey)
            let summary = TranscriptUsageSummary(transcript: priced, day: day, policy: .init())
            try require(summary.reconciles(with: session.usage, transcript: priced),
                        "\(name): chat and daily report diverged: chat \(tokens(summary.reported)) $\(summary.reported.cost) incomplete=\(summary.reported.costIsIncomplete ?? false) uncertain=\(priced.usageUncertain) undated=\(summary.unknownDates); report \(tokens(session.usage)) $\(session.usage.cost)")
        }
        let restarted = sessions["restarted"]!
        let report = try await service.fetch(day: UsageDay(date: TranscriptJSON.date("2026-10-06T12:00:00Z")!, timezone: "UTC"), customPath: wrapper.path)
        let session = report.sessions.first { $0.rawID == costStateID(restarted) }
        try require(session?.usage.costIsIncomplete == true && session?.costReasons?.contains(.countersMissing) == true,
                    "Unknown subagent counters published as a complete day")
    }
}
