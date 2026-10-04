import Foundation
import CoreFoundation

typealias ClaudePricingOverrides = [String: [String: Double]]

protocol ClaudePricingProviding: Sendable {
    func refresh() async throws -> ClaudePricingOverrides
}

struct PricingResponse: Sendable {
    var status: Int
    var data: Data
    var etag: String?
}

/// Persist rates, not report totals: new usage can still be calculated offline.
actor ClaudePricingCache: ClaudePricingProviding {
    static let endpoint = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    static let maximumBytes = 16 * 1_024 * 1_024
    static let filename = "claude-pricing-v1.json"
    typealias Fetch = @Sendable (String?) async throws -> PricingResponse

    private struct Saved: Codable {
        var schemaVersion = 1
        var refreshedAt: Date
        var etag: String?
        var prices: ClaudePricingOverrides
    }

    private let directory: URL
    private let fetch: Fetch
    private let includeTranscriptModels: Bool
    private var cacheFilename: String { includeTranscriptModels ? "chat-pricing-v1.json" : Self.filename }
    private var saved: Saved?
    private var loaded = false
    private var pending: Task<ClaudePricingOverrides, Error>?

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LLMUsage/Pricing", isDirectory: true),
         includeTranscriptModels: Bool = false,
         fetch: @escaping Fetch = { try await ClaudePricingCache.download(etag: $0) }) {
        self.directory = directory
        self.fetch = fetch
        self.includeTranscriptModels = includeTranscriptModels
    }

    func refresh() async throws -> ClaudePricingOverrides {
        try Task.checkCancellation()
        if let pending {
            let result = try await pending.value
            try Task.checkCancellation()
            return result
        }
        let task = Task { try await self.update() }
        pending = task
        defer { pending = nil }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    private func update() async throws -> ClaudePricingOverrides {
        if !loaded {
            loaded = true
            let url = directory.appendingPathComponent(cacheFilename)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size <= Self.maximumBytes, let data = try? Data(contentsOf: url) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let value = try? decoder.decode(Saved.self, from: data), value.schemaVersion == 1,
                   Self.validates(value.prices, includeTranscriptModels: includeTranscriptModels) { saved = value }
            }
            // Upgrade without losing Claude tariffs on the first offline launch.
            if saved == nil, includeTranscriptModels,
               let data = try? Data(contentsOf: directory.appendingPathComponent(Self.filename)) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                if var value = try? decoder.decode(Saved.self, from: data), value.schemaVersion == 1, Self.validates(value.prices) {
                    value.etag = nil; saved = value
                }
            }
        }
        let response: PricingResponse
        do { response = try await fetch(saved?.etag) }
        catch { return saved?.prices ?? [:] }
        if response.status == 304, var value = saved {
            value.refreshedAt = Date()
            persist(value)
            return value.prices
        }
        guard response.status == 200, let fresh = try? Self.parse(response.data, includeTranscriptModels: includeTranscriptModels), !fresh.isEmpty else {
            return saved?.prices ?? [:]
        }
        // A removed or malformed entry must not erase a previously usable tariff.
        let prices = (saved?.prices ?? [:]).merging(fresh) { _, new in new }
        let value = Saved(refreshedAt: Date(), etag: response.etag, prices: prices)
        persist(value)
        return prices
    }

    private func persist(_ value: Saved) {
        // A failed optional cache write must not discard usable network prices.
        // Keep them in memory and retry persistence on the next revalidation.
        saved = value
        try? SnapshotFiles.write(value, name: cacheFilename, directory: directory)
    }

    static func download(etag: String?) async throws -> PricingResponse {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { return .init(status: http.statusCode, data: Data(), etag: nil) }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw UsageError.outputTooLarge }
        return .init(status: http.statusCode, data: try Data(contentsOf: file), etag: http.value(forHTTPHeaderField: "ETag"))
    }

    private static let fields = [
        ("input_cost_per_token", "inputCostPerToken"),
        ("output_cost_per_token", "outputCostPerToken"),
        ("cache_creation_input_token_cost", "cacheCreationInputTokenCost"),
        ("cache_read_input_token_cost", "cacheReadInputTokenCost"),
        ("input_cost_per_token_above_200k_tokens", "inputCostPerTokenAbove200kTokens"),
        ("output_cost_per_token_above_200k_tokens", "outputCostPerTokenAbove200kTokens"),
        ("cache_creation_input_token_cost_above_200k_tokens", "cacheCreationInputTokenCostAbove200kTokens"),
        ("cache_read_input_token_cost_above_200k_tokens", "cacheReadInputTokenCostAbove200kTokens"),
        ("max_input_tokens", "maxInputTokens")
    ]

    static func parse(_ data: Data, includeTranscriptModels: Bool = false) throws -> ClaudePricingOverrides {
        guard data.count <= maximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        var result: ClaudePricingOverrides = [:]
        for (model, raw) in root where accepts(model, includeTranscriptModels: includeTranscriptModels) {
            guard let entry = raw as? [String: Any] else { continue }
            var rates: [String: Double] = [:]
            var invalid = false
            for (key, field) in fields {
                guard let value = entry[key], !(value is NSNull) else { continue }
                guard let rate = number(value) else { invalid = true; break }
                if field == "maxInputTokens", rate.rounded(.down) != rate || rate > Double(UInt64.max) {
                    invalid = true; break
                }
                rates[field] = rate
            }
            if let value = (entry["provider_specific_entry"] as? [String: Any])?["fast"], !(value is NSNull) {
                if let rate = number(value), rate > 0 { rates["fastMultiplier"] = rate }
                else { invalid = true }
            }
            guard !invalid, let input = rates["inputCostPerToken"], rates["outputCostPerToken"] != nil else { continue }
            // These are ccusage's LiteLLM defaults, including for models absent from its binary.
            rates["cacheCreationInputTokenCost"] = rates["cacheCreationInputTokenCost"] ?? input * 1.25
            rates["cacheReadInputTokenCost"] = rates["cacheReadInputTokenCost"] ?? input * 0.1
            guard rates.values.allSatisfy(\.isFinite) else { continue }
            result[model] = rates
        }
        return result
    }

    private static func number(_ value: Any) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }
        return value.doubleValue
    }

    private static func accepts(_ model: String, includeTranscriptModels: Bool) -> Bool {
        let name = model.lowercased()
        return name.contains("claude") || (includeTranscriptModels &&
            (name.contains("gpt-") || name.contains("gemini") || name.range(of: #"(?:^|/)o[1-9](?:$|-)"#, options: .regularExpression) != nil))
    }

    private static func validates(_ prices: ClaudePricingOverrides, includeTranscriptModels: Bool = false) -> Bool {
        let allowed = Set(fields.map(\.1) + ["fastMultiplier"])
        return !prices.isEmpty && prices.count <= 100_000 && prices.allSatisfy { model, rates in
            accepts(model, includeTranscriptModels: includeTranscriptModels) && rates["inputCostPerToken"] != nil
                && rates["outputCostPerToken"] != nil && rates["cacheCreationInputTokenCost"] != nil
                && rates["cacheReadInputTokenCost"] != nil && rates.allSatisfy { key, value in
                    allowed.contains(key) && value.isFinite && value >= 0
                }
        }
    }
}

enum CCUsagePricingConfiguration {
    /// Match ccusage 20's first-valid-config discovery without changing the user's file.
    static func contents(prices: ClaudePricingOverrides, environment: [String: String],
                         workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> Data {
        let home = URL(fileURLWithPath: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
        let directories: [URL]
        if let configured = environment["CLAUDE_CONFIG_DIR"] {
            directories = configured.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0, relativeTo: workingDirectory) }
        } else {
            directories = [home.appendingPathComponent(".config/claude"), home.appendingPathComponent(".claude")]
        }
        let paths = [workingDirectory.appendingPathComponent(".ccusage/ccusage.json")]
            + directories.map { $0.appendingPathComponent("ccusage.json") }
        var root = paths.lazy.compactMap { url -> [String: Any]? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }.first ?? [:]
        var defaults = root["defaults"] as? [String: Any] ?? [:]
        var overrides = prices.mapValues { $0 as [String: Any] }
        for (model, value) in defaults["pricingOverrides"] as? [String: Any] ?? [:] {
            guard let rates = value as? [String: Any] else { continue }
            overrides[model] = (overrides[model] ?? [:]).merging(rates) { _, user in user }
        }
        defaults["pricingOverrides"] = overrides
        root["defaults"] = defaults
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
