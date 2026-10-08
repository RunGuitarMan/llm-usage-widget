import Foundation
import CryptoKit

/// Only tariff options are archived. Source paths, credentials and arbitrary
/// CLI options never travel into an isolated per-request calculation.
struct TranscriptPricingArchive: Sendable {
    var directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LLMUsage/Pricing/Reports", isDirectory: true)

    func save(configuration: Data, environment: [String: String] = [:], engineID: String? = nil) throws -> String {
        var archive = try Self.configurations(configuration: configuration, environment: environment)
        archive["_engineID"] = engineID
        let data = try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys])
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(key + ".json")
        // Existence alone cannot guarantee that a content-addressed receipt is intact.
        if (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) != data.count
            || (try? Data(contentsOf: file)) != data {
            try data.write(to: file, options: .atomic)
        }
        return key
    }

    static func configurations(configuration: Data, environment: [String: String] = [:]) throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] ?? [:]
        var archive: [String: Any] = [:]
        for source in TranscriptUsageParser.supportedSources {
            var maps = [TranscriptJSON.object(root["defaults"])]
            let commands = TranscriptJSON.object(root["commands"])
            if source == "claude" {
                maps += [TranscriptJSON.object(commands["claude session"]), TranscriptJSON.object(commands["session"]),
                         TranscriptJSON.object(commands["claude:session"])]
                let claude = TranscriptJSON.object(root["claude"])
                maps += [TranscriptJSON.object(claude["defaults"]), TranscriptJSON.object(TranscriptJSON.object(claude["commands"])["session"])]
            } else { maps.append(TranscriptJSON.object(commands["session"])) }
            var overrides: [String: [String: Any]] = [:]
            var options: [String: Any] = [:]
            for map in maps {
                for (model, value) in TranscriptJSON.object(map["pricingOverrides"]) {
                    overrides[model] = (overrides[model] ?? [:]).merging(TranscriptJSON.object(value)) { _, new in new }
                }
                if let speed = map["speed"] as? String, ["auto", "standard", "fast"].contains(speed) { options["speed"] = speed }
            }
            options["pricingOverrides"] = overrides
            var config: [String: Any] = ["defaults": options]
            if source == "codex" { config["llmUsageFallbackTier"] = Self.codexFallbackTier(environment: environment) }
            archive[source] = config
        }
        return archive
    }

    static func codexFallbackTier(environment: [String: String]) -> String {
        guard !environment.isEmpty else { return "standard" }
        let home = URL(fileURLWithPath: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
        for root in TranscriptService(home: home, environment: environment).roots(for: "codex") {
            let file = root.appendingPathComponent("config.toml")
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                  let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Deliberately mirror ccusage 20.0.26 speed.rs, including its line-based
            // lookup. Do not copy the user's configuration into the pricing sandbox.
            for line in content.split(separator: "\n") {
                let setting = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                let parts = setting.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "service_tier" else { continue }
                let tier = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if ["fast", "priority"].contains(tier) { return "fast" }
            }
        }
        return "standard"
    }

    func configuration(key: String, source: String, expectedEngineID: String? = nil) throws -> Data {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw URLError(.cannotParseResponse) }
        let file = directory.appendingPathComponent(key + ".json")
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= ClaudePricingCache.maximumBytes else { throw UsageError.outputTooLarge }
        let data = try Data(contentsOf: file)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == key,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let config = root[source] else { throw URLError(.cannotParseResponse) }
        if let expectedEngineID, root["_engineID"] as? String != expectedEngineID {
            throw UsageError.runtimeUnavailable
        }
        return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    }
}

struct TranscriptCostService: Sendable {
    var runtime: CCUsageRuntime? = .shared
    var archive = TranscriptPricingArchive()
    var resolver = CCUsageExecutableResolver()
    var runner = ProcessRunner(timeout: 90)
    var telemetryStore: ClaudeTelemetryStore?

    func price(_ original: SessionTranscript, source: String, customPath: String, pricingKey: String?) async throws -> SessionTranscript {
        guard original.usageSupported, !original.requests.isEmpty || (source == "claude" && original.claudeSessionID != nil) else { return original }
        if let runtime {
            return try await runtime.withExecutable { executable in
                try await price(original, source: source, pricingKey: pricingKey, executable: executable)
            }
        }
        return try await price(original, source: source, pricingKey: pricingKey, executable: try await resolver.resolve(customPath: customPath))
    }
    private func price(_ original: SessionTranscript, source: String, pricingKey: String?, executable: URL) async throws -> SessionTranscript {
        var transcript = original
        if source == "claude", !transcript.imported, let sid = transcript.claudeSessionID,
           let store = telemetryStore ?? (runtime == nil ? nil : .shared) {
            do {
                let events = try await store.events(sessionID: sid)
                transcript = ClaudeTelemetryAccounting.recover(transcript, sessionID: sid, events: events)
            } catch is CancellationError { throw CancellationError() }
            catch { transcript.usageUncertain = true }
        }
        guard !transcript.requests.isEmpty else { return transcript }
        let configuration: Data
        if let pricingKey, let saved = try? archive.configuration(key: pricingKey, source: source, expectedEngineID: runtime == nil ? nil : CCUsageManifest.bundled?.engineID) {
            configuration = saved
        } else {
            // Old snapshots have no tariff receipt. They remain readable, but a
            // calculation at today's rates cannot claim to verify an old report.
            let prices = try await ClaudePricingCache(includeTranscriptModels: true).refresh()
            let config = try CCUsagePricingConfiguration.contents(prices: prices, environment: (runtime == nil ? ProcessRunner.environment(for: executable) : CCUsageRuntime.environment()))
            let key = try archive.save(configuration: config, environment: (runtime == nil ? ProcessRunner.environment(for: executable) : CCUsageRuntime.environment()), engineID: runtime == nil ? nil : CCUsageManifest.bundled?.engineID)
            configuration = try archive.configuration(key: key, source: source)
            transcript.usageUncertain = true
            transcript.notices.append(L10n.text("Версия расчёта или тарифы исходного отчёта отличаются. Стоимость пересчитана; обновите статистику для сверки."))
        }
        if let root = try? JSONSerialization.jsonObject(with: configuration) as? [String: Any],
           let speed = (root["defaults"] as? [String: Any])?["speed"] as? String, ["auto", "standard", "fast"].contains(speed) {
            transcript.telemetryPricingSpeed = speed
        }
        transcript.telemetryRates = ClaudeTelemetryReconciler.rates(configuration)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("llmusage-chat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let requests = transcript.requests.filter { !$0.isReplay && !$0.model.isEmpty }
        guard requests.count <= TranscriptUsageParser.maximumRequests else { throw UsageError.outputTooLarge }
        let preparation = Task.detached(priority: .userInitiated) {
            try Self.prepare(requests, source: source, root: root, configuration: configuration)
        }
        try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
        try Task.checkCancellation()
        var environment = (runtime == nil ? ProcessRunner.environment(for: executable) : CCUsageRuntime.environment())
        environment[TranscriptSource.all[source]!.variable] = root.path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
        var arguments = [source, "session", "--json", "--offline", "--timezone", "UTC", "--config", root.appendingPathComponent("ccusage.json").path]
        if source != "codex" { arguments += ["--mode", "calculate"] }
        let output = try await runner.run(executable: executable, arguments: arguments, environment: environment)
        let prices = try Self.decode(output.stdout, source: source)
        for index in transcript.requests.indices {
            guard let usage = prices[transcript.requests[index].id] else { continue }
            transcript.requests[index].usage = usage
            transcript.requests[index].priced = true
        }
        transcript.id = UUID()
        return transcript
    }

    static func prepare(_ requests: [TranscriptRequest], source: String, root: URL, configuration: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try configuration.write(to: root.appendingPathComponent("ccusage.json"), options: .atomic)
        if source == "codex" {
            let config = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] ?? [:]
            let tier = config["llmUsageFallbackTier"] as? String == "fast" ? "fast" : "standard"
            try Data("service_tier = \"\(tier)\"\n".utf8).write(to: root.appendingPathComponent("config.toml"))
        }
        let directory = root.appendingPathComponent(source == "claude" ? "projects/chat" : source == "codex" ? "sessions" : "chats")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for request in requests {
            try Task.checkCancellation()
            let date = formatter.string(from: request.timestamp ?? Date(timeIntervalSince1970: 0))
            let rows: [[String: Any]]
            if source == "claude" {
                var usage = request.billing.tokens.mapValues { $0 as Any }
                if let speed = request.billing.speed { usage["speed"] = speed }
                if !request.billing.cacheCreation.isEmpty { usage["cache_creation"] = request.billing.cacheCreation }
                rows = [["type": "assistant", "timestamp": date, "sessionId": request.id, "requestId": request.id,
                         "message": ["id": request.id, "model": request.model, "role": "assistant", "usage": usage]]]
            } else if source == "codex" {
                var context: [String: Any] = ["model": request.model]
                if let speed = request.billing.speed { context["service_tier"] = speed }
                var tokens = request.billing.tokens
                tokens["cache_write_input_tokens"] = tokens.removeValue(forKey: "cache_creation_tokens")
                rows = [["type": "session_meta", "timestamp": date, "payload": ["id": request.id]],
                        ["type": "turn_context", "timestamp": date, "payload": context],
                        ["type": "event_msg", "timestamp": date, "payload": ["type": "thread_settings_applied", "thread_settings": context]],
                        ["type": "event_msg", "timestamp": date, "payload": ["type": "token_count", "info": ["last_token_usage": tokens]]]]
            } else {
                rows = [["sessionId": request.id, "messages": [["type": "gemini", "id": request.id, "timestamp": date,
                         "model": request.model, "tokens": request.billing.tokens]]]]
            }
            let contents = try rows.reduce(into: Data()) { result, row in
                result += try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); result.append(10)
            }
            try contents.write(to: directory.appendingPathComponent(request.id + (source == "gemini" ? ".json" : ".jsonl")))
        }
    }

    static func decode(_ data: Data, source: String) throws -> [String: TokenUsage] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["sessions"] as? [[String: Any]] else { throw UsageError.malformedJSON("Missing per-request sessions") }
        var result: [String: TokenUsage] = [:]
        for row in rows {
            guard let rawID = row["sessionId"] as? String else { throw UsageError.malformedJSON("Missing request identity") }
            let id = URL(fileURLWithPath: rawID).deletingPathExtension().lastPathComponent
            guard id.hasPrefix("request-"), result[id] == nil else { throw UsageError.malformedJSON("Unexpected request identity") }
            func tokens(_ key: String) throws -> Int64 {
                guard let value = row[key] else { return 0 }
                guard let value = TranscriptUsageParser.number(value) else { throw UsageError.malformedJSON("Invalid request tokens") }
                return value
            }
            let input = try tokens("inputTokens"), output = try tokens("outputTokens")
            let create = try tokens("cacheCreationTokens"), read = try tokens("cacheReadTokens")
            let total = try tokens("totalTokens")
            guard total >= input + output + create + read else { throw UsageError.malformedJSON("Invalid request total") }
            let amount = (row["totalCost"] ?? row["costUSD"]) as? Double
            if let amount, !amount.isFinite || amount < 0 || amount > 1e12 { throw UsageError.malformedJSON("Invalid request cost") }
            let breakdown = row["modelBreakdowns"] as? [[String: Any]] ?? Array((row["models"] as? [String: [String: Any]] ?? [:]).values)
            let missing = amount == nil || breakdown.contains { $0["missingPricing"] as? Bool == true }
            result[id] = .init(input: input, output: output, cacheCreate: create, cacheRead: read, cost: amount ?? 0,
                              additional: total - input - output - create - read, costIsIncomplete: missing)
        }
        return result
    }
}
