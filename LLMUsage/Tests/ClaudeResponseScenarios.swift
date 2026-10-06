import Foundation
import CryptoKit
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#endif

private struct ClaudeResponseFailure: Error { var message: String }
private struct ResponseFixturePricing: ClaudePricingProviding {
    func refresh() async throws -> ClaudePricingOverrides {
        ["claude-response-fixture": ["inputCostPerToken": 0.000002, "outputCostPerToken": 0.00001,
            "cacheCreationInputTokenCost": 0.0000025, "cacheReadInputTokenCost": 0.0000002]]
    }
}

enum ClaudeResponseScenarios {
    private static func fixtures() throws -> [[String: Any]] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-response-boundaries.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
    }
    private static func text(_ fixture: [String: Any]) throws -> String {
        try (fixture["records"] as! [[String: Any]]).map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n")
    }
    private static func expected(_ fixture: [String: Any]) -> TokenUsage {
        let value = fixture["expected"] as! [String: Int64]
        let input = value["inputTokens"]!, output = value["outputTokens"]!
        let create = value["cacheCreationTokens"]!, read = value["cacheReadTokens"]!
        return .init(input: input, output: output, cacheCreate: create, cacheRead: read,
                     cost: Double(input) * 0.000002 + Double(output) * 0.00001 + Double(create) * 0.0000025 + Double(read) * 0.0000002)
    }
    private static func require(_ actual: TokenUsage, _ expected: TokenUsage, _ name: String, priced: Bool) throws {
        guard TokenCategory.allCases.allSatisfy({ actual.value(for: $0) == expected.value(for: $0) }),
              !priced || abs(actual.cost - expected.cost) < 1e-10 else {
            throw ClaudeResponseFailure(message: "\(name): \(actual), expected \(expected)")
        }
    }
    @MainActor static func run(check: (String, () async throws -> Void) async -> Void) async {
        await check("Claude: linked streams and reused gateway IDs have distinct response boundaries") {
            for fixture in try fixtures() {
                let transcript = try TranscriptUsageScenarios.decode("claude", text(fixture))
                let actual = TranscriptUsageSummary(transcript: transcript, day: nil, policy: .init()).reported
                try require(actual, expected(fixture), fixture["name"] as! String, priced: false)
            }
        }
    }
    @MainActor static func liveCheck(executablePath: String) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ClaudeResponseChecks-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let project = root.appendingPathComponent("claude/projects/project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        var environment = ["HOME": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LOG_LEVEL": "0",
                           "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                           "XDG_DATA_HOME": root.appendingPathComponent("data").path,
                           "XDG_CACHE_HOME": root.appendingPathComponent("cache").path]
        for (source, spec) in TranscriptSource.all { environment[spec.variable] = root.appendingPathComponent(source).path }
        let archive = TranscriptPricingArchive(directory: root.appendingPathComponent("receipts"))
        let service = CCUsageService(runtime: nil, pricing: ResponseFixturePricing(), pricingArchive: archive, environment: environment)
        let costService = TranscriptCostService(runtime: nil, archive: archive)
        for fixture in try fixtures() {
            let raw = try text(fixture)
            try Data(raw.utf8).write(to: project.appendingPathComponent("s.jsonl"))
            let transcript = try TranscriptUsageScenarios.decode("claude", raw)
            for mode in [UsageUpdateMode.claudeOnly, .allAgents] {
                var total = TokenUsage.zero
                for date in ["2026-10-03T00:00:00Z", "2026-10-04T00:00:00Z"] {
                    let day = UsageDay(date: ISO8601DateFormatter().date(from: date)!, timezone: "UTC")
                    let snapshot = try await service.fetch(day: day, customPath: executablePath, mode: mode)
                    let priced = try await costService.price(transcript, source: "claude", customPath: executablePath, pricingKey: snapshot.pricingKey)
                    let summary = TranscriptUsageSummary(transcript: priced, day: day, policy: .init())
                    try require(snapshot.totals, summary.reported, "\(fixture["name"]!) \(mode) \(date)", priced: true)
                    total = total + snapshot.totals
                }
                try require(total, expected(fixture), "\(fixture["name"]!) \(mode)", priced: true)
            }
        }
    }
}
