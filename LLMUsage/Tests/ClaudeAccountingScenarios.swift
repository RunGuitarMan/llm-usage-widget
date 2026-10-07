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
    }
}
