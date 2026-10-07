import Foundation

/// Reconcile the CLI's visible-message report with validated session snapshots.
/// Only sanitized supplemental counters enter the isolated pricing invocation.
struct ClaudeAccountingService: Sendable {
    var environment: [String: String]
    var runner = ProcessRunner(timeout: 90)

    func reconcile(_ original: UsageSnapshot, executable: URL, configuration: Data) async throws -> UsageSnapshot {
        var result = original
        let reader = TranscriptService(environment: environment)
        let roots = reader.roots(for: "claude")
        let files = try await Self.background { () -> [String: [URL]] in
            var files: [String: [URL]] = [:]
            let wanted = Set(original.sessions.filter { $0.sourceID == "claude" }.map(\.rawID))
            for root in roots {
                let projects = root.appendingPathComponent("projects")
                let directories = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
                for project in directories.prefix(30_000) {
                    try Task.checkCancellation()
                    let entries = (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? []
                    for file in entries where file.pathExtension == "jsonl" {
                        let id = file.deletingPathExtension().lastPathComponent
                        if wanted.contains(id) { files[id, default: []].append(file) }
                    }
                }
            }
            return files
        }
        var requests: [TranscriptRequest] = []
        var owners: [String: Int] = [:]
        for index in result.sessions.indices where result.sessions[index].sourceID == "claude" {
            try Task.checkCancellation()
            let session = result.sessions[index]
            guard let paths = files[session.rawID] else { continue }
            guard paths.count == 1 else { result.sessions[index].usage.costIsIncomplete = true; continue }
            let parsed: SessionTranscript?
            do {
                parsed = try await Self.background {
                    try Self.read(paths[0], sessionID: session.rawID)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { result.sessions[index].usage.costIsIncomplete = true; continue }
            guard let transcript = parsed else { continue }
            if transcript.usageUncertain { result.sessions[index].usage.costIsIncomplete = true }
            let main = transcript.requests.filter { !$0.isSupplemental && !$0.isReplay && $0.belongs(to: original.day) }
            let observed = Dictionary(grouping: main, by: \.modelForAccounting).mapValues { $0.reduce(TokenUsage.zero) { $0 + $1.usage } }
            let reported = Dictionary(grouping: session.modelBreakdowns, by: \.id).mapValues { $0.reduce(TokenUsage.zero) { $0 + $1.usage } }
            guard Set(observed.keys) == Set(reported.keys), observed.allSatisfy({ name, value in
                guard let other = reported[name] else { return false }
                return TokenCategory.allCases.allSatisfy { value.value(for: $0) == other.value(for: $0) }
            }) else { result.sessions[index].usage.costIsIncomplete = true; continue }
            for var request in transcript.requests where request.isSupplemental {
                if !request.belongs(to: original.day) {
                    if (request.accountingIntervalStart ?? .distantFuture) < original.day.end,
                       (request.accountingIntervalEnd ?? .distantPast) >= original.day.date {
                        result.sessions[index].usage.costIsIncomplete = true
                    }
                    continue
                }
                request.id = "request-" + UUID().uuidString
                owners[request.id] = index
                requests.append(request)
            }
        }
        guard !requests.isEmpty else { return result }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("llmusage-accounting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let configs = try TranscriptPricingArchive.configurations(configuration: configuration)
            let tariff = try JSONSerialization.data(withJSONObject: configs["claude"] ?? [:], options: [.sortedKeys])
            try TranscriptCostService.prepare(requests, source: "claude", root: root, configuration: tariff)
            var env = environment
            env["CLAUDE_CONFIG_DIR"] = root.path
            env["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
            let output = try await runner.run(executable: executable, arguments: ["claude", "session", "--json", "--offline",
                "--mode", "calculate", "--timezone", "UTC", "--config", root.appendingPathComponent("ccusage.json").path], environment: env)
            let prices = try TranscriptCostService.decode(output.stdout, source: "claude")
            for request in requests {
                guard let index = owners[request.id] else { continue }
                guard let usage = prices[request.id], TokenCategory.allCases.allSatisfy({ usage.value(for: $0) == request.usage.value(for: $0) }) else {
                    result.sessions[index].usage.costIsIncomplete = true; continue
                }
                result.sessions[index].usage = result.sessions[index].usage + usage
                if let model = result.sessions[index].modelBreakdowns.firstIndex(where: { $0.id == request.modelForAccounting }) {
                    result.sessions[index].modelBreakdowns[model].usage = result.sessions[index].modelBreakdowns[model].usage + usage
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { for index in Set(owners.values) { result.sessions[index].usage.costIsIncomplete = true } }
        return result
    }

    private static func background<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    static func read(_ file: URL, sessionID: String) throws -> SessionTranscript? {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024 else {
            throw UsageError.outputTooLarge
        }
        let data = try Data(contentsOf: file)
        guard data.count <= 32 * 1024 * 1024 else { throw UsageError.outputTooLarge }
        guard data.range(of: Data("\"modelUsage\"".utf8)) != nil else { return nil }
        var decoder = TranscriptDecoder(source: "claude")
        decoder.origin = file.path
        for line in data.split(separator: 10) where !line.isEmpty {
            try Task.checkCancellation()
            guard let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if row["modelUsage"] != nil, row["sessionId"] as? String != sessionID {
                throw UsageError.malformedJSON("Session accounting identity mismatch")
            }
            decoder.append(row)
        }
        return try TranscriptUsageParser.annotate(.init(events: decoder.finish()), source: "claude")
    }
}
