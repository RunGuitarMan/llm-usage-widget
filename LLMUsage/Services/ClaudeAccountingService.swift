import Foundation

/// Reconcile the CLI baseline with validated snapshots and local API telemetry.
/// Only numeric requests enter the isolated pricing invocation.
struct ClaudeAccountingService: Sendable {
    var environment: [String: String]
    var runner = ProcessRunner(timeout: 90)
    var telemetryEvents: [String: [ClaudeTelemetryEvent]] = [:]
    var telemetryFailed = false

    func reconcile(_ original: UsageSnapshot, executable: URL, configuration: Data) async throws -> UsageSnapshot {
        var result = original
        let reader = TranscriptService(environment: environment)
        let roots = reader.roots(for: "claude")
        let datedTelemetry = Set(telemetryEvents.compactMap { sid, events in
            ClaudeTelemetrySanitizer.session(sid) == sid && events.contains(where: {
                $0.sessionID == sid && $0.kind == .apiRequest && $0.timestamp.map { $0 >= original.day.date && $0 < original.day.end } == true
            }) ? sid : nil
        })
        let originalIDs = Set(original.sessions.filter { $0.sourceID == "claude" }.map(\.rawID))
        let files = try await Self.background { () -> [String: [URL]] in
            var files: [String: [URL]] = [:]
            let wanted = originalIDs.union(datedTelemetry)
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
        // A resumed session can have API charges on a day with no JSONL usage.
        // Still require its transcript so request identity/snapshot overlap can
        // be checked before adding it to this day's otherwise empty CLI report.
        for sid in datedTelemetry.subtracting(originalIDs).sorted() where files[sid]?.count == 1 {
            result.sessions.append(.init(id: UsageSource.sessionID(agent: "claude", rawID: sid), models: [], usage: .zero,
                lastActivity: telemetryEvents[sid]?.compactMap(\.timestamp).max(), agent: "claude", originalID: sid))
        }
        var requests: [TranscriptRequest] = []
        var owners: [String: Int] = [:]
        var replacements = Set<Int>()
        var incomplete = Set<Int>()
        for index in result.sessions.indices where result.sessions[index].sourceID == "claude" {
            try Task.checkCancellation()
            let session = result.sessions[index]
            if telemetryFailed { result.sessions[index].usage.costIsIncomplete = true }
            guard let paths = files[session.rawID] else { continue }
            guard paths.count == 1 else { result.sessions[index].usage.costIsIncomplete = true; continue }
            let parsed: SessionTranscript?
            let events = telemetryEvents[session.rawID.lowercased()] ?? []
            do {
                if events.isEmpty {
                    parsed = try await Self.background { try Self.read(paths[0], sessionID: session.rawID) }
                } else {
                    // Include subagent files, just as the CLI and chat reader do.
                    parsed = try await reader.load(session: session)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { result.sessions[index].usage.costIsIncomplete = true; continue }
            guard var transcript = parsed else { continue }
            if transcript.usageUncertain { result.sessions[index].usage.costIsIncomplete = true }
            let main = transcript.requests.filter { !$0.isSupplemental && !$0.isReplay && $0.belongs(to: original.day)
                && $0.billing.tokens["input_tokens"] != nil && $0.billing.tokens["output_tokens"] != nil }
            let observed = Dictionary(grouping: main, by: \.modelForAccounting).mapValues { $0.reduce(TokenUsage.zero) { $0 + $1.usage } }.filter { $0.value.total > 0 }
            let reported = Dictionary(grouping: session.modelBreakdowns, by: \.id).mapValues { $0.reduce(TokenUsage.zero) { $0 + $1.usage } }.filter { $0.value.total > 0 }
            guard Set(observed.keys) == Set(reported.keys), observed.allSatisfy({ name, value in
                guard let other = reported[name] else { return false }
                return TokenCategory.allCases.allSatisfy { value.value(for: $0) == other.value(for: $0) }
            }) else { result.sessions[index].usage.costIsIncomplete = true; continue }
            if !events.isEmpty {
                transcript = ClaudeTelemetryAccounting.recover(transcript, sessionID: session.rawID, events: events)
                replacements.insert(index)
            }
            if transcript.usageUncertain { incomplete.insert(index) }
            for var request in transcript.requests where !request.isReplay && (replacements.contains(index) || request.isSupplemental) {
                if !request.belongs(to: original.day) {
                    if (request.accountingIntervalStart ?? .distantFuture) < original.day.end,
                       (request.accountingIntervalEnd ?? .distantPast) >= original.day.date {
                        result.sessions[index].usage.costIsIncomplete = true
                        incomplete.insert(index)
                    }
                    continue
                }
                guard request.billing.tokens["input_tokens"] != nil, request.billing.tokens["output_tokens"] != nil else {
                    incomplete.insert(index); continue
                }
                request.id = "request-" + UUID().uuidString
                owners[request.id] = index
                requests.append(request)
            }
        }
        guard !requests.isEmpty else {
            for index in incomplete { result.sessions[index].usage.costIsIncomplete = true }
            return result
        }
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
            // Replacements are atomic per session. A missing helper result must
            // not erase the CLI baseline or publish half a recalculated session.
            let groups = Dictionary(grouping: requests, by: { owners[$0.id]! })
            var failed = Set<Int>()
            for (index, rows) in groups where replacements.contains(index) {
                guard rows.allSatisfy({ request in
                    guard let usage = prices[request.id] else { return false }
                    return TokenCategory.allCases.allSatisfy { usage.value(for: $0) == request.usage.value(for: $0) }
                }) else { failed.insert(index); result.sessions[index].usage.costIsIncomplete = true; continue }
                result.sessions[index].usage = .zero
                result.sessions[index].modelBreakdowns = []
                result.sessions[index].models = []
            }
            for request in requests {
                guard let index = owners[request.id] else { continue }
                guard !failed.contains(index) else { continue }
                guard let usage = prices[request.id], TokenCategory.allCases.allSatisfy({ usage.value(for: $0) == request.usage.value(for: $0) }) else {
                    result.sessions[index].usage.costIsIncomplete = true; continue
                }
                result.sessions[index].usage = result.sessions[index].usage + usage
                if let model = result.sessions[index].modelBreakdowns.firstIndex(where: { $0.id == request.modelForAccounting }) {
                    result.sessions[index].modelBreakdowns[model].usage = result.sessions[index].modelBreakdowns[model].usage + usage
                } else {
                    result.sessions[index].modelBreakdowns.append(.init(id: request.modelForAccounting, usage: usage))
                    if !result.sessions[index].models.contains(request.modelForAccounting) { result.sessions[index].models.append(request.modelForAccounting) }
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { for index in Set(owners.values) { result.sessions[index].usage.costIsIncomplete = true } }
        for index in incomplete { result.sessions[index].usage.costIsIncomplete = true }
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
