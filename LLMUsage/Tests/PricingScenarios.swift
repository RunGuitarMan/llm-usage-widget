import Foundation
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#elseif !PORTABLE_CHECKS
@testable import LLMUsage
#endif

struct EmptyPricingFixture: ClaudePricingProviding {
    func refresh() async throws -> ClaudePricingOverrides { [:] }
}

private struct PricingFailure: Error, CustomStringConvertible { var description: String }
private func requirePricing(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw PricingFailure(description: message) }
}

private actor PricingServer {
    var replies: [PricingResponse]
    var etags: [String?] = []
    init(_ replies: [PricingResponse]) { self.replies = replies }
    nonisolated var fetch: ClaudePricingCache.Fetch { { try await self.respond($0) } }
    func respond(_ etag: String?) throws -> PricingResponse {
        etags.append(etag)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        return replies.removeFirst()
    }
}

enum PricingScenarios {
    static let model = "claude-pricing-fixture-999"
    static let catalog = Data(#"{"claude-pricing-fixture-999":{"input_cost_per_token":0.000002,"output_cost_per_token":0.00001,"cache_creation_input_token_cost":0.0000025,"cache_read_input_token_cost":0.0000002,"input_cost_per_token_above_200k_tokens":0.000004,"output_cost_per_token_above_200k_tokens":0.00002,"cache_creation_input_token_cost_above_200k_tokens":0.000005,"cache_read_input_token_cost_above_200k_tokens":0.0000004,"provider_specific_entry":{"fast":2},"max_input_tokens":1000000},"gpt-fixture":{"input_cost_per_token":1,"output_cost_per_token":2}}"#.utf8)
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LLM Usage Pricing \(UUID().uuidString)")
    }

    @MainActor static func run(check: (String, () async throws -> Void) async -> Void) async {
        await check("Pricing: unwritable cache retains fetched rates in memory and recovers on revalidation") {
            let directory = directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            // A regular file in place of the cache directory fails regardless of test-user privileges.
            try Data("blocked".utf8).write(to: directory)
            let server = PricingServer([.init(status: 200, data: catalog, etag: "v1"),
                .init(status: 304, data: Data(), etag: nil)])
            let cache = ClaudePricingCache(directory: directory, fetch: server.fetch)
            let fresh = try await cache.refresh()
            try FileManager.default.removeItem(at: directory)
            let revalidated = try await cache.refresh()
            let offline = try await cache.refresh()
            let restarted = try await ClaudePricingCache(directory: directory, fetch: server.fetch).refresh()
            try requirePricing(!fresh.isEmpty && fresh == revalidated && fresh == offline && fresh == restarted,
                               "An optional disk cache failure lost usable prices or prevented recovery")
        }
        await check("Pricing: failed 304 persistence preserves previously loaded prices") {
            let directory = directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let server = PricingServer([.init(status: 200, data: catalog, etag: "v1"),
                .init(status: 304, data: Data(), etag: nil)])
            let cache = ClaudePricingCache(directory: directory, fetch: server.fetch)
            let fresh = try await cache.refresh()
            let file = directory.appendingPathComponent(ClaudePricingCache.filename)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            let revalidated = try await cache.refresh()
            let offline = try await cache.refresh()
            try requirePricing(fresh == revalidated && fresh == offline, "A failed metadata write aborted usable pricing")
        }
        await check("Pricing: persisted Claude rates survive restart and a network failure") {
            let directory = directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let server = PricingServer([.init(status: 200, data: catalog, etag: "v1")])
            let online = try await ClaudePricingCache(directory: directory, fetch: server.fetch).refresh()
            let offline = try await ClaudePricingCache(directory: directory, fetch: server.fetch).refresh()
            try requirePricing(online == offline && online.count == 1, "Restart lost prices or changed other providers")
            try requirePricing(offline[model]?["cacheReadInputTokenCostAbove200kTokens"] == 0.0000004
                && offline[model]?["fastMultiplier"] == 2, "A rate component was dropped")
            let requests = await server.etags
            try requirePricing(requests.count == 2 && requests[0] == nil && requests[1] == "v1", "ETag not persisted")
        }
        await check("Pricing: each refresh revalidates and newer prices replace cached values") {
            let directory = directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let updated = Data(#"{"claude-pricing-fixture-999":{"input_cost_per_token":0.000003,"output_cost_per_token":0.00002}}"#.utf8)
            let server = PricingServer([.init(status: 200, data: catalog, etag: "v1"),
                .init(status: 304, data: Data(), etag: nil), .init(status: 200, data: updated, etag: "v2")])
            let cache = ClaudePricingCache(directory: directory, fetch: server.fetch)
            let first = try await cache.refresh()
            let revalidated = try await cache.refresh()
            let second = try await cache.refresh()
            let reopened = try await ClaudePricingCache(directory: directory, fetch: server.fetch).refresh()
            try requirePricing(first == revalidated && second == reopened && first != second, "Prices did not refresh/revalidate")
            try requirePricing(second[model]?["inputCostPerToken"] == 0.000003
                && second[model]?["cacheCreationInputTokenCost"] == 0.000003 * 1.25, "New tariff or defaults were lost")
            let requests = await server.etags
            try requirePricing(requests == [nil, "v1", "v1", "v2"], "Refresh skipped the network or reused the wrong validator")
        }
        await check("Pricing: HTTP errors and malformed rates never overwrite a good cache") {
            let directory = directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let invalidBodies = ["<html>unavailable</html>", "{}", "null",
                #"{"claude-pricing-fixture-999":{"input_cost_per_token":true,"output_cost_per_token":1}}"#,
                #"{"claude-pricing-fixture-999":{"input_cost_per_token":-1,"output_cost_per_token":1}}"#,
                #"{"claude-pricing-fixture-999":{"input_cost_per_token":1,"output_cost_per_token":1,"max_input_tokens":1.5}}"#]
            let replies = [.init(status: 200, data: catalog, etag: "good")] as [PricingResponse]
            let server = PricingServer(replies + invalidBodies.map { .init(status: 200, data: Data($0.utf8), etag: "bad") }
                + [.init(status: 503, data: catalog, etag: "bad")])
            let cache = ClaudePricingCache(directory: directory, fetch: server.fetch)
            let good = try await cache.refresh()
            for _ in 0...invalidBodies.count {
                let current = try await cache.refresh()
                try requirePricing(current == good, "Invalid refresh destroyed the cached tariff")
            }
            let persisted = try await ClaudePricingCache(directory: directory, fetch: server.fetch).refresh()
            try requirePricing(persisted == good, "Invalid response was persisted")
        }
        await check("Pricing: first offline launch and corrupt cache safely use CLI fallback") {
            let directory = directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let server = PricingServer([])
            let empty = try await ClaudePricingCache(directory: directory, fetch: server.fetch).refresh()
            try requirePricing(empty.isEmpty, "Invented prices without a cache")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("broken".utf8).write(to: directory.appendingPathComponent(ClaudePricingCache.filename))
            let corrupt = try await ClaudePricingCache(directory: directory, fetch: server.fetch).refresh()
            try requirePricing(corrupt.isEmpty, "Corrupt cache was trusted")
            let recovery = PricingServer([.init(status: 200, data: catalog, etag: nil)])
            let recovered = try await ClaudePricingCache(directory: directory, fetch: recovery.fetch).refresh()
            try requirePricing(!recovered.isEmpty, "Corrupt cache could not recover")
        }
        await check("Pricing: disappeared models retain their last valid rates") {
            let directory = directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let newer = Data(#"{"claude-another-fixture":{"input_cost_per_token":0,"output_cost_per_token":0}}"#.utf8)
            let server = PricingServer([.init(status: 200, data: catalog, etag: nil), .init(status: 200, data: newer, etag: nil)])
            let cache = ClaudePricingCache(directory: directory, fetch: server.fetch)
            let first = try await cache.refresh()
            let second = try await cache.refresh()
            try requirePricing(second[model] == first[model] && second["claude-another-fixture"]?["inputCostPerToken"] == 0,
                               "A removed model vanished or a legitimate zero price was rejected")
        }
        await check("Pricing: concurrent reports share one atomic refresh") {
            let directory = directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let server = PricingServer([.init(status: 200, data: catalog, etag: "v1")])
            let cache = ClaudePricingCache(directory: directory) { etag in
                try await Task.sleep(nanoseconds: 50_000_000)
                return try await server.respond(etag)
            }
            async let first = cache.refresh()
            async let second = cache.refresh()
            let values = try await (first, second)
            let requests = await server.etags
            try requirePricing(values.0 == values.1 && !values.0.isEmpty && requests.count == 1,
                               "Concurrent reports raced or fetched different prices")
        }
        await check("Pricing: generated config preserves user overrides, source options and stores") {
            let directory = directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let user = directory.appendingPathComponent("custom claude")
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            let original = Data(#"{"defaults":{"timezone":"Europe/Moscow","pricingOverrides":{"claude-pricing-fixture-999":{"inputCostPerToken":0.5},"private":{"outputCostPerToken":0.9}}},"claude":{"commands":{"session":{"pricingOverrides":{"claude-pricing-fixture-999":{"outputCostPerToken":0.7}}}}},"pi":{"stores":[{"name":"omp","path":"/fixture"}]}}"#.utf8)
            let file = user.appendingPathComponent("ccusage.json")
            try original.write(to: file)
            let data = try CCUsagePricingConfiguration.contents(prices: ClaudePricingCache.parse(catalog),
                environment: ["HOME": directory.path, "CLAUDE_CONFIG_DIR": " /missing, \(user.path) "], workingDirectory: directory)
            let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let defaults = root["defaults"] as! [String: Any]
            let overrides = defaults["pricingOverrides"] as! [String: [String: Double]]
            try requirePricing(overrides[model]?["inputCostPerToken"] == 0.5
                && overrides[model]?["outputCostPerToken"] == 0.00001
                && overrides["private"]?["outputCostPerToken"] == 0.9, "User tariffs were replaced")
            try requirePricing(root["claude"] != nil && root["pi"] != nil && defaults["timezone"] as? String == "Europe/Moscow",
                               "Config lost source options or named stores")
            let unchanged = try Data(contentsOf: file)
            try requirePricing(unchanged == original, "User configuration was modified")
            let local = directory.appendingPathComponent(".ccusage")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try Data(#"{"defaults":{"timezone":"UTC"}}"#.utf8).write(to: local.appendingPathComponent("ccusage.json"))
            let localData = try CCUsagePricingConfiguration.contents(prices: [:], environment: ["CLAUDE_CONFIG_DIR": user.path], workingDirectory: directory)
            let localRoot = try JSONSerialization.jsonObject(with: localData) as! [String: Any]
            try requirePricing((localRoot["defaults"] as? [String: Any])?["timezone"] as? String == "UTC" && localRoot["pi"] == nil,
                               "Config precedence differs from ccusage")
        }
    }

    /// Uses the installed CLI but only synthetic logs; proxy failure affects this child alone.
    static func liveCheck() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try await CCUsageExecutableResolver().resolve(customPath: "")
        let claude = directory.appendingPathComponent("claude")
        let project = claude.appendingPathComponent("projects/fixture")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let wrapper = directory.appendingPathComponent("ccusage")
        let script = """
        #!/bin/sh
        export CLAUDE_CONFIG_DIR=\(quote(claude.path))
        export XDG_CACHE_HOME=\(quote(directory.appendingPathComponent("http").path))
        export PATH=\(quote(executable.deletingLastPathComponent().path)):$PATH
        export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9
        export https_proxy=$HTTPS_PROXY http_proxy=$HTTP_PROXY all_proxy=$ALL_PROXY NO_PROXY= no_proxy=
        exec \(quote(executable.path)) "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        func entry(_ index: Int, model: String = model, input: Int = 1000, fast: Bool = false, oneHour: Bool = false) throws -> Data {
            var usage: [String: Any] = ["input_tokens": input, "output_tokens": 1000,
                                      "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 1000]
            if fast { usage["speed"] = "fast" }
            if oneHour { usage["cache_creation"] = ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 1000] }
            let json: [String: Any] = ["type": "assistant", "timestamp": "2026-09-29T12:00:00Z",
                "sessionId": "pricing-\(index)", "requestId": "request-\(index)",
                "message": ["id": "message-\(index)", "model": model, "usage": usage]]
            return try JSONSerialization.data(withJSONObject: json) + Data([10])
        }
        let log = project.appendingPathComponent("pricing.jsonl")
        try entry(1).write(to: log)
        let day = UsageDay(date: ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!, timezone: "UTC")
        let server = PricingServer([.init(status: 200, data: catalog, etag: "v1")])
        let cacheDirectory = directory.appendingPathComponent("pricing")
        let service = CCUsageService(pricing: ClaudePricingCache(directory: cacheDirectory, fetch: server.fetch))
        let first = try await service.fetch(day: day, customPath: wrapper.path)
        try requirePricing(abs(first.totals.cost - 0.0147) < 0.0000001 && first.totals.costIsIncomplete != true,
                           "Real CLI ignored cached base/cache-read/cache-write rates")
        let restarted = CCUsageService(pricing: ClaudePricingCache(directory: cacheDirectory, fetch: server.fetch))
        let offline = try await restarted.fetch(day: day, customPath: wrapper.path)
        try requirePricing(offline.totals == first.totals, "Offline restart changed identical usage")
        try (entry(1) + entry(2)).write(to: log)
        let growing = try await restarted.fetch(day: day, customPath: wrapper.path)
        try requirePricing(growing.totals.total == first.totals.total * 2 && abs(growing.totals.cost - 0.0294) < 0.0000001,
                           "New offline usage was frozen at the last report's cost")
        try entry(3, input: 300_000, fast: true).write(to: log)
        let longFast = try await restarted.fetch(day: day, customPath: wrapper.path)
        try requirePricing(abs(longFast.totals.cost - 1.6254) < 0.0000001, "Cached long-context/Fast rates changed CLI calculation")
        try entry(4, oneHour: true).write(to: log)
        let oneHour = try await restarted.fetch(day: day, customPath: wrapper.path)
        try requirePricing(abs(oneHour.totals.cost - 0.0162) < 0.0000001, "One-hour cache-write pricing was lost")
        print("  cached pricing: 4,000 tokens = $0.0147; offline restart unchanged; 8,000 tokens = $0.0294")

        // Reproduce #10 with the actual public catalog, then block both price fetch paths.
        try (entry(5, model: "claude-sonnet-5-5") + entry(6, model: "claude-sonnet-4-6")).write(to: log)
        var environment = ProcessRunner.environment(for: executable)
        environment["CLAUDE_CONFIG_DIR"] = claude.path
        environment["XDG_CACHE_HOME"] = directory.appendingPathComponent("http-online").path
        let baseline = try await ProcessRunner().run(executable: executable,
            arguments: CCUsageService.arguments(for: day, report: .claude), environment: environment)
        let online = try CCUsageDecoder.decode(baseline.stdout, day: day, report: .claude)
        try requirePricing(online.totals.costIsIncomplete != true, "Live baseline has no prices; cannot verify parity")
        let liveDirectory = directory.appendingPathComponent("live-pricing")
        let liveCache = ClaudePricingCache(directory: liveDirectory)
        let live = try await CCUsageService(pricing: liveCache).fetch(day: day, customPath: wrapper.path)
        let noNetwork = ClaudePricingCache(directory: liveDirectory) { _ in throw URLError(.notConnectedToInternet) }
        let liveOffline = try await CCUsageService(pricing: noNetwork).fetch(day: day, customPath: wrapper.path)
        try requirePricing(live.totals == liveOffline.totals && live.totals.total == online.totals.total
            && abs(live.totals.cost - online.totals.cost) < 0.0000001 && liveOffline.totals.costIsIncomplete != true,
                           "Online CLI and persisted public Claude tariffs disagree")
        print("  live catalog: \(online.totals.total) tokens, online $\(online.totals.cost), offline $\(liveOffline.totals.cost)")
    }
}
