import Foundation
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#endif

private struct RecoveryFailure: Error, CustomStringConvertible { var description: String }
private struct RecoveryPrices: ClaudePricingProviding {
    var multiplier = 1.0
    func refresh() async throws -> ClaudePricingOverrides {
        [ClaudeTelemetryAccountingScenarios.model: ["inputCostPerToken": 4e-6, "outputCostPerToken": 2e-5,
            "cacheReadInputTokenCost": 2e-7, "cacheCreationInputTokenCost": 5e-6].mapValues { $0 * multiplier }]
    }
}

enum ClaudeTelemetryAccountingScenarios {
    static let sid = "00000000-0000-4000-8000-000000000162"
    static let other = "00000000-0000-4000-8000-000000000163"
    static let model = "claude-opus-5-5"
    static let date = TranscriptJSON.date("2026-10-07T12:00:00Z")!
    static let fields = ClaudeTelemetryAccounting.fields

    struct Fixture: Decodable {
        struct Baseline: Decodable { var id: String; var tokens: [Int64]; var known: Bool; var file: Int }
        struct Event: Decodable { var id: String; var tokens: [Int64]; var source: String }
        var baseline: [Baseline]
        var events: [Event]
        var expectedTokens: [Int64]
        var expectedCost: Double
        var baselineCost: Double
    }
    static func fixture() throws -> Fixture {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/claude-telemetry-accounting.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw RecoveryFailure(description: message) }
    }
    static func row(_ id: String, tokens: [Int64]?, at: Date = date) -> [String: Any] {
        var usage: [String: Any] = [:]
        if let tokens { usage = Dictionary(uniqueKeysWithValues: zip(fields, tokens.map { $0 as Any })); usage["speed"] = "standard" }
        return ["type": "assistant", "sessionId": sid, "requestId": id, "timestamp": at.ISO8601Format(),
            "message": ["id": id, "role": "assistant", "model": model, "usage": usage,
                "content": [["type": "text", "text": "Synthetic fixture"]]]]
    }
    static func event(_ id: String, tokens: [Int64] = [100, 20, 300, 0], at: Date = date) -> ClaudeTelemetryEvent {
        .init(sessionID: sid, kind: .apiRequest, requestID: id, timestamp: at, receivedAt: at,
            model: model, input: tokens[0], output: tokens[1], cacheRead: tokens[2], cacheWrite: tokens[3],
            costUSD: "999", speed: .normal, source: .other)
    }
    static func decode(_ rows: [[String: Any]]) throws -> SessionTranscript {
        var result = try ClaudeAccountingScenarios.decode(rows)
        result.claudeSessionID = sid
        return result
    }
    static func total(_ value: SessionTranscript) -> TokenUsage { value.requests.reduce(.zero) { $0 + $1.usage } }
    static func tokens(_ usage: TokenUsage) -> [Int64] { [usage.input, usage.output, usage.cacheRead, usage.cacheCreate] }
    static func events(_ fixture: Fixture) -> [ClaudeTelemetryEvent] {
        fixture.events.enumerated().map { index, row in
            var result = event(row.id, tokens: row.tokens, at: date.addingTimeInterval(Double(index)))
            result.source = .init(rawValue: row.source)
            return result
        }
    }

    /// Four LLM Usage 1.6.3 diagnostic archives: transcript counters as parsed
    /// then (placeholders included) and every Claude API event of the session.
    static func capturedSessions() throws -> [[String: Any]] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/claude-telemetry-sessions.json")
        return (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any])["sessions"] as! [[String: Any]]
    }
    static func captured(_ session: [String: Any]) throws -> (SessionTranscript, [ClaudeTelemetryEvent], [String: Double]) {
        let model = session["model"] as! String
        let rows: [[String: Any]] = (session["transcript"] as! [[String: Any]]).map { request in
            let tokens = request["tokens"] as! [Int]
            var usage: [String: Any] = Dictionary(uniqueKeysWithValues: zip(fields, tokens.map { $0 as Any }))
            var message: [String: Any] = ["id": request["id"]!, "role": "assistant", "model": model, "content": [["type": "text", "text": "Synthetic fixture"]]]
            if request["placeholder"] as? Bool != true {
                usage["speed"] = "standard"; usage["service_tier"] = "standard"; message["stop_reason"] = "end_turn"
                if let split = request["split"] as? [Int] { usage["cache_creation"] = ["ephemeral_5m_input_tokens": split[0], "ephemeral_1h_input_tokens": split[1]] }
            }
            message["usage"] = usage
            return ["type": "assistant", "sessionId": sid, "requestId": request["id"]!, "timestamp": request["at"]!, "message": message]
        }
        let events: [ClaudeTelemetryEvent] = (session["events"] as! [[String: Any]]).map { row in
            let at = TelemetryJSON.date(row["at"] as! String)!
            var value = event(row["id"] as! String, tokens: (row["tokens"] as? [Int])?.map(Int64.init) ?? [0, 0, 0, 0], at: at)
            value.model = model
            value.costUSD = row["cost"] as? String
            value.source = .init(rawValue: row["source"] as! String)
            if row["error"] as? Bool == true { value.kind = .apiError; value.input = nil; value.output = nil; value.cacheRead = nil; value.cacheWrite = nil; value.costUSD = nil }
            return value
        }
        return (try decode(rows), events, session["rates"] as! [String: Double])
    }

    static func runCaptured(check: (String, () async throws -> Void) async -> Void) async {
        await check("Telemetry accounting: four captured sessions reach /usage with cache-write TTL solved from Claude's cost") {
            for session in try capturedSessions() {
                let name = session["name"] as! String
                let (baseline, events, rates) = try captured(session)
                let recovered = ClaudeTelemetryAccounting.recover(baseline, sessionID: sid, events: events, rates: [session["model"] as! String: rates])
                let expected = (session["expectedTokens"] as! [Int]).map(Int64.init)
                try require(tokens(total(recovered)) == expected, "\(name): tokens \(tokens(total(recovered))) differ from \(expected)")
                let cost = ClaudeAccountingScenarios.claudeCost(recovered, rates: rates)
                try require(cost.map { abs($0 - (session["expectedCost"] as! Double)) < 1e-6 } == true, "\(name): cost \(String(describing: cost)) differs")
                let unknown = recovered.requests.filter { $0.countersUnknown }.count
                try require(unknown == session["unknownPlaceholders"] as! Int, "\(name): \(unknown) placeholders left unknown")
                try require(!recovered.usageUncertain && recovered.hasUnknownCounters(on: nil) == (unknown > 0), "\(name): completeness misreported")
                // Without tariffs the TTL stays unknown: the earlier conservative result.
                let conservative = ClaudeTelemetryAccounting.recover(baseline, sessionID: sid, events: events)
                try require(conservative.usageUncertain && total(conservative).cacheCreate < total(recovered).cacheCreate, "\(name): TTL invented without tariffs")
            }
        }
        await check("Telemetry accounting: a positive cache write recovers only when Claude's cost fixes its TTL") {
            let original = try decode([row("call", tokens: nil)])
            let rates = ["inputCostPerToken": 4e-6, "outputCostPerToken": 2e-5, "cacheReadInputTokenCost": 2e-7, "cacheCreationInputTokenCost": 5e-6]
            var cached = event("call", tokens: [100, 20, 300, 1000])
            cached.costUSD = "0.00706" // 100*4e-6 + 20*2e-5 + 300*2e-7 + 600*5e-6 + 400*8e-6
            let recovered = ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [cached], rates: [model: rates])
            try require(!recovered.usageUncertain && recovered.requests[0].billing.cacheCreation == ["ephemeral_5m_input_tokens": 600, "ephemeral_1h_input_tokens": 400],
                        "Mixed TTL not recovered from cost")
            cached.costUSD = "0.0055"
            let contradictory = ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [cached], rates: [model: rates])
            try require(contradictory.usageUncertain && total(contradictory).total == 0, "Unsolvable cost produced a tariff")
            var fast = cached; fast.speed = .fast; fast.costUSD = "0.00706"
            try require(ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [fast], rates: [model: rates]).usageUncertain, "Fast TTL guessed")
        }
        await check("Telemetry accounting: a session total owns earlier calls and placeholders; later calls stay billable") {
            let sidRows: [[String: Any]] = [
                row("main", tokens: [1, 10, 0, 0]),
                ["type": "assistant", "sessionId": sid, "requestId": "agent", "timestamp": date.addingTimeInterval(5).ISO8601Format(), "isSidechain": true,
                 "message": ["id": "agent", "role": "assistant", "model": model, "content": [["type": "text", "text": "Synthetic fixture"]],
                             "usage": ["input_tokens": 0, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0]]],
                ["type": "cost-state", "sessionId": sid, "modelUsage": [model: ["inputTokens": 21, "outputTokens": 30, "cacheReadInputTokens": 0,
                    "cacheCreationInputTokens": 0, "costUSD": 0.000684, "webSearchRequests": 0]]],
                ["type": "user", "sessionId": sid, "timestamp": date.addingTimeInterval(600).ISO8601Format(), "message": ["role": "user", "content": "Synthetic"]],
                row("later", tokens: nil, at: date.addingTimeInterval(601))]
            let original = try decode(sidRows)
            try require(original.claudeSnapshotValidated && !original.hasUnknownCounters(on: nil), "Session total did not cover the placeholder")
            let recovered = ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [
                event("agent", tokens: [20, 20, 0, 0], at: date.addingTimeInterval(5)), event("title", tokens: [5, 1, 0, 0], at: date.addingTimeInterval(1)),
                event("later", tokens: [7, 3, 0, 0], at: date.addingTimeInterval(601)), event("between", tokens: [9, 9, 0, 0], at: date.addingTimeInterval(300))])
            try require(tokens(total(recovered)) == [28, 33, 0, 0], "Covered calls double billed or later call lost: \(tokens(total(recovered)))")
            try require(recovered.usageUncertain, "A call between the total and the next row was silently assigned")
        }
    }

    static func run(check: (String, () async throws -> Void) async -> Void) async {
        await runCaptured(check: check)
        await check("Telemetry accounting: captured 114 incomplete and 84 absent requests plus service call") {
            let fixture = try fixture()
            let baseline = try decode(fixture.baseline.map { row($0.id, tokens: $0.known ? $0.tokens : nil) })
            try require(tokens(total(baseline)) == [491413, 275953, 32931328, 0], "Captured baseline changed")
            let recovered = ClaudeTelemetryAccounting.recover(baseline, sessionID: sid, events: events(fixture))
            try require(recovered.requests.count == 343 && tokens(total(recovered)) == fixture.expectedTokens, "Captured API costs remain missing")
            try require(recovered.requests.filter { $0.telemetryRecovery == "completed" }.count == 114, "Wrong completion count")
            try require(recovered.requests.filter { $0.telemetryRecovery == "added" }.count == 85, "Wrong additional count")
            try require(!recovered.usageUncertain, "Unambiguous zero-write fixture became uncertain")
            let repeated = ClaudeTelemetryAccounting.recover(recovered, sessionID: sid, events: events(fixture) + events(fixture))
            try require(repeated.requests.count == 343 && tokens(total(repeated)) == fixture.expectedTokens, "Retry doubled costs")
            try require(recovered.requests.filter { $0.telemetryRecovery == "added" }.allSatisfy { $0.eventIDs.isEmpty && $0.userEventID == nil }, "Invented visible message ownership")
        }
        await check("Telemetry accounting: missing counters and explicit zeros both recover with provenance") {
            for originalTokens: [Int64]? in [nil, [0, 0, 0, 0]] {
                let original = try decode([row("call", tokens: originalTokens)])
                let recovered = ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [event("call")])
                try require(tokens(total(recovered)) == [100, 20, 300, 0], "Incomplete call not repaired")
                try require(recovered.requests[0].telemetryOriginalTokens == (originalTokens == nil ? [:] : Dictionary(uniqueKeysWithValues: zip(fields, originalTokens!))), "Original missing/zero distinction lost")
                try require(recovered.requests[0].eventIDs == original.requests[0].eventIDs, "Message links changed")
            }
            var synthetic = row("failure", tokens: [0, 0, 0, 0])
            synthetic["isApiErrorMessage"] = true
            let failureTranscript = try decode([synthetic])
            try require(failureTranscript.requests.isEmpty, "Error placeholder billed")
        }
        await check("Telemetry accounting: wrong session, errors, missing identity/time/counters and fast unknowns") {
            let original = try decode([row("call", tokens: nil)])
            var foreign = event("call"); foreign.sessionID = other
            var error = event("call"); error.kind = .apiError
            try require(total(ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [foreign, error])).total == 0, "Foreign/error charged")
            for mode in 0..<4 {
                var malformed = event("call")
                if mode == 0 { malformed.requestID = nil }
                if mode == 1 { malformed.timestamp = nil }
                if mode == 2 { malformed.output = nil }
                if mode == 3 { malformed.speed = nil }
                let recovered = ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [malformed])
                try require(total(recovered).total == 0 && recovered.usageUncertain, "Incomplete API evidence silently charged")
            }
            var imported = original; imported.imported = true
            try require(total(ClaudeTelemetryAccounting.recover(imported, sessionID: sid, events: [event("call")])).total == 0, "Imported log combined with local telemetry")
        }
        await check("Telemetry accounting: conflicting deliveries, identities, models and positive input are rejected") {
            let original = try decode([row("call", tokens: nil)])
            var conflicting = event("call"); conflicting.output = 99
            let conflicted = ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [event("call"), conflicting])
            try require(total(conflicted).total == 0 && conflicted.usageUncertain, "Conflicting call charged")
            var complete = try decode([row("call", tokens: [100, 1, 300, 0])])
            complete.requests[0].telemetryIdentity?.clientRequestID = "client-a"
            var mismatched = event("call"); mismatched.clientRequestID = "client-b"
            try require(total(ClaudeTelemetryAccounting.recover(complete, sessionID: sid, events: [mismatched])).output == 1, "Client conflict ignored")
            mismatched = event("call"); mismatched.model = "claude-sonnet-5-5"
            try require(total(ClaudeTelemetryAccounting.recover(complete, sessionID: sid, events: [mismatched])).output == 1, "Model conflict ignored")
            mismatched = event("call"); mismatched.input = 101
            try require(total(ClaudeTelemetryAccounting.recover(complete, sessionID: sid, events: [mismatched])).output == 1, "Positive input conflict ignored")
            let grown = ClaudeTelemetryAccounting.recover(complete, sessionID: sid, events: [event("call")])
            try require(total(grown).output == 20, "Final streamed output not recovered")
        }
        await check("Telemetry accounting: requestless rows and alias ambiguity cannot become duplicate calls") {
            var requestless = row("call", tokens: [100, 20, 300, 0]); requestless.removeValue(forKey: "requestId")
            let original = try decode([requestless])
            let recovered = ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [event("unknown")])
            try require(recovered.requests.count == 1 && recovered.usageUncertain, "Requestless duplicate billed")
            var aliased = try decode([row("call", tokens: nil)])
            aliased.requests[0].model = "anthropic/claude-opus-5.5"
            var api = event("call"); api.model = "claude-opus-5-5[1m]"
            let normalized = ClaudeTelemetryAccounting.recover(aliased, sessionID: sid, events: [api])
            try require(normalized.requests[0].model == "anthropic/claude-opus-5.5" && total(normalized).input == 100, "Original tariff alias not retained")
        }
        await check("Telemetry accounting: cache-write TTL stays explicit and fast tier is preserved") {
            let original = try decode([row("call", tokens: nil)])
            var cached = event("call"); cached.cacheWrite = 10
            let unknown = ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [cached])
            try require(total(unknown).total == 0 && unknown.usageUncertain, "Invented cache-write TTL")
            var split = original; split.requests[0].billing.cacheCreation = ["ephemeral_1h_input_tokens": 10]
            let known = ClaudeTelemetryAccounting.recover(split, sessionID: sid, events: [cached])
            try require(total(known).cacheCreate == 10 && known.requests[0].billing.cacheCreation["ephemeral_1h_input_tokens"] == 10, "1h cache split lost")
            var fast = event("call"); fast.speed = .fast
            let expedited = ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [fast])
            try require(expedited.requests[0].billing.speed == "fast" && expedited.requests[0].modelForAccounting == model + "-fast", "Fast request became standard")
        }
        await check("Telemetry accounting: cumulative snapshot owns covered calls; later calls remain billable") {
            let snapshot: [String: Any] = ["sessionId": sid, "timestamp": date.addingTimeInterval(60).ISO8601Format(),
                "modelUsage": [model: ["inputTokens": 110, "outputTokens": 22, "cacheReadInputTokens": 300,
                    "cacheCreationInputTokens": 0, "costUSD": 123, "webSearchRequests": 0]]]
            let original = try decode([row("main", tokens: [100, 20, 300, 0]), snapshot])
            try require(original.claudeSnapshotValidated, "Snapshot fixture not accepted")
            let recovered = ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [event("overhead", tokens: [10, 2, 0, 0]),
                event("later", tokens: [7, 3, 0, 0], at: date.addingTimeInterval(120))])
            try require(tokens(total(recovered)) == [117, 25, 300, 0], "Snapshot overlap double billed or later call erased")
            var noBoundary = original; noBoundary.claudeAccountingCoverage[0].through = nil
            let conservative = ClaudeTelemetryAccounting.recover(noBoundary, sessionID: sid, events: [event("overhead", tokens: [10, 2, 0, 0])])
            try require(total(conservative).input == 110 && conservative.usageUncertain, "Guessed unknown snapshot boundary")
        }
        await check("Telemetry accounting: repaired calls retain their original day; additional calls use API event time") {
            let before = TranscriptJSON.date("2026-10-07T23:59:59Z")!, after = before.addingTimeInterval(2)
            let original = try decode([row("call", tokens: nil, at: before)])
            let recovered = ClaudeTelemetryAccounting.recover(original, sessionID: sid,
                events: [event("call", at: after), event("new", tokens: [1, 2, 3, 0], at: after)])
            let previous = TranscriptUsageSummary(transcript: recovered, day: UsageDay(date: before, timezone: "UTC"), policy: .init())
            let next = TranscriptUsageSummary(transcript: recovered, day: UsageDay(date: after, timezone: "UTC"), policy: .init())
            try require(previous.reported.input == 100 && next.reported.input == 1, "Costs moved across midnight")
        }
        await check("Telemetry accounting: daily uncertainty excludes unrelated dates but retains late completions and conflicts") {
            let day = UsageDay(date: date, timezone: "UTC")
            let original = try decode([row("call", tokens: [100, 20, 300, 0])])
            var malformed = event("unrelated", at: date.addingTimeInterval(86400)); malformed.speed = nil
            let earlier = ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [malformed], day: day)
            try require(!earlier.usageIsUncertain(on: day), "Next-day telemetry contaminated a complete prior day")
            malformed.timestamp = date
            try require(ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [malformed], day: day).usageIsUncertain(on: day), "Same-day ambiguity was hidden")
            let partial = try decode([row("call", tokens: nil)])
            let completion = event("call", at: date.addingTimeInterval(86400))
            let repaired = ClaudeTelemetryAccounting.recover(partial, sessionID: sid, events: [completion], day: day)
            try require(total(repaired).input == 100 && repaired.requests[0].timestamp == date, "Late completion lost the original billing day")
            var conflict = completion; conflict.input = 101
            let conflicted = ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [event("call"), conflict], day: day)
            try require(conflicted.usageIsUncertain(on: day), "Date filtering concealed a conflicting delivery")
            let invalidRow = row("bad", tokens: [-1, 2, 3, 0], at: date.addingTimeInterval(86400))
            let transcript = try decode([row("call", tokens: [100, 20, 300, 0]), invalidRow])
            try require(transcript.usageUncertain && !transcript.usageIsUncertain(on: day)
                && transcript.usageIsUncertain(on: day.adding(days: 1)), "Malformed dated source rows lost their actual scope")
        }
        await check("Telemetry accounting: export distinguishes missing values, explicit zeros and recovered counters") {
            let original = try decode([row("call", tokens: nil)])
            let api = event("call")
            let selection = TelemetryExportSelection(timezone: "UTC")
            for recovered in [false, true] {
                let transcript = recovered ? ClaudeTelemetryAccounting.recover(original, sessionID: sid, events: [api]) : original
                let archive = try ClaudeTelemetryExporter.make(snapshot: .init(sessions: [sid: [api]]), selection: selection,
                    transcripts: [sid: transcript], appVersion: "1.6.2", helperVersion: nil, contract: nil)
                let bytes = String(decoding: archive.bytes, as: UTF8.self)
                try require(bytes.contains("\"missingCounters\":"), "Missing counters lost in export")
                if recovered {
                    try require(bytes.contains("\"telemetryRecovery\":\"completed\"") && bytes.contains("\"transcriptCountersBeforeRecovery\":{}"), "Recovery provenance missing")
                } else { try require(bytes.contains("\"missingCounters\":[\"input_tokens\",\"output_tokens\""), "Unknown counters exported as known zeros") }
                try require(!bytes.contains("Synthetic fixture"), "Transcript content leaked into export")
            }
        }
    }

    static func liveCheck(executablePath: String) async throws {
        let fixture = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("llmusage-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let logs = root.appendingPathComponent("claude/projects/synthetic")
        try FileManager.default.createDirectory(at: logs.appendingPathComponent(sid + "/subagents"), withIntermediateDirectories: true)
        for (file, rows) in Dictionary(grouping: fixture.baseline, by: \.file) {
            let contents = try rows.reduce(into: Data()) { result, request in
                result += try JSONSerialization.data(withJSONObject: row(request.id, tokens: request.known ? request.tokens : nil), options: [.sortedKeys])
                result.append(10)
            }
            let path = file == 0 ? sid + ".jsonl" : sid + "/subagents/agent-\(file).jsonl"
            try contents.write(to: logs.appendingPathComponent(path))
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent("claude").path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
        let wrapper = root.appendingPathComponent("ccusage-test")
        let quoted = "'" + executablePath.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let script = "#!/bin/sh\ncase \"$1\" in\n session) printf '%s\\n' '{\"session\":[]}' ;;\n --version) exec " + quoted + " \"$@\" ;;\n *) exec " + quoted + " \"$@\" --offline ;;\nesac\n"
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let store = ClaudeTelemetryStore(directory: root.appendingPathComponent("telemetry"))
        try await store.setCollecting(true, now: date)
        try await store.accept(.init(events: events(fixture)), now: date)
        let archive = TranscriptPricingArchive(directory: root.appendingPathComponent("receipts"))
        let day = UsageDay(date: date, timezone: "UTC")
        let baseline = CCUsageService(runtime: nil, pricing: RecoveryPrices(), pricingArchive: archive, environment: environment)
        let old = try await baseline.fetch(day: day, customPath: wrapper.path)
        try require(abs(old.totals.cost - fixture.baselineCost) < 1e-9, "Real helper baseline does not reproduce captured costs")
        for mode in [UsageUpdateMode.claudeOnly, .allAgents] {
            let service = CCUsageService(runtime: nil, pricing: RecoveryPrices(), pricingArchive: archive, environment: environment, telemetryStore: store)
            let report = try await service.fetch(day: day, customPath: wrapper.path, mode: mode)
            try require(report.sessions.count == 1 && abs(report.totals.cost - fixture.expectedCost) < 1e-9,
                "Recovered report differs: \(report.totals.cost), expected \(fixture.expectedCost)")
            try require(tokens(report.totals) == fixture.expectedTokens && report.totals.costIsIncomplete != true, "Recovered report is incomplete or tokens differ")
            let transcript = try await TranscriptService(environment: environment).load(session: report.sessions[0])
            let priced = try await TranscriptCostService(runtime: nil, archive: archive, telemetryStore: store)
                .price(transcript, source: "claude", customPath: wrapper.path, pricingKey: report.pricingKey)
            let summary = TranscriptUsageSummary(transcript: priced, day: day, policy: .init())
            try require(summary.reconciles(with: report.totals, transcript: priced), "Chat/report accounting diverged")
        }
        let doubled = CCUsageService(runtime: nil, pricing: RecoveryPrices(multiplier: 2), pricingArchive: archive, environment: environment, telemetryStore: store)
        let override = try await doubled.fetch(day: day, customPath: wrapper.path)
        try require(abs(override.totals.cost - 2 * fixture.expectedCost) < 1e-9, "Recovery copied telemetry costUSD instead of using configured tariffs")
        let excluded = override.applyingExclusions(.init(overrides: [model: false]))
        try require(excluded.totals.cost == 0, "Recovered charges bypass model exclusions")

        let tomorrow = date.addingTimeInterval(86400)
        try await store.accept(.init(events: [event("next-day", at: tomorrow)]), now: tomorrow)
        let service = CCUsageService(runtime: nil, pricing: RecoveryPrices(), pricingArchive: archive, environment: environment, telemetryStore: store)
        let nextDay = try await service.fetch(day: UsageDay(date: tomorrow, timezone: "UTC"), customPath: wrapper.path)
        try require(nextDay.sessions.count == 1 && tokens(nextDay.totals) == [100, 20, 300, 0]
            && abs(nextDay.totals.cost - 0.00086) < 1e-10, "A day with only telemetry disappeared from the report")

        var malformed = event("unrelated-future", at: tomorrow.addingTimeInterval(86400)); malformed.speed = nil
        try await store.accept(.init(events: [malformed]), now: tomorrow)
        let unaffected = try await service.fetch(day: day, customPath: wrapper.path)
        try require(unaffected.totals.costIsIncomplete != true && abs(unaffected.totals.cost - fixture.expectedCost) < 1e-9,
            "Unrelated future telemetry tainted the real daily report")

        let failing = "#!/bin/sh\ncase \"$CLAUDE_CONFIG_DIR\" in */llmusage-accounting-*) printf '%s\\n' '{\"sessions\":[]}' ; exit 0 ;; esac\n" + script
        try Data(failing.utf8).write(to: wrapper)
        let failed = try await service.fetch(day: day, customPath: wrapper.path)
        try require(abs(failed.totals.cost - fixture.baselineCost) < 1e-9 && failed.totals.costIsIncomplete == true,
            "Missing pricing results erased the baseline or published a partial replacement")
    }
}
