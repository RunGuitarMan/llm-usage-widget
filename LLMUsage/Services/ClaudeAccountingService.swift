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
        func mark(_ index: Int, _ reason: UsageCostReason) {
            result.sessions[index].usage.costIsIncomplete = true
            let reasons = (result.sessions[index].costReasons ?? []) + [reason]
            result.sessions[index].costReasons = Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
            incomplete.insert(index)
        }
        for index in result.sessions.indices where result.sessions[index].sourceID == "claude" {
            try Task.checkCancellation()
            let session = result.sessions[index]
            if telemetryFailed { mark(index, .telemetryUnavailable) }
            guard let paths = files[session.rawID] else { continue }
            guard paths.count == 1 else { mark(index, .ambiguousSource); continue }
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
            catch {
                switch error {
                case UsageError.outputTooLarge, TranscriptError.tooLarge: mark(index, .sourceTooLarge)
                default: mark(index, .sourceUnavailable)
                }
                continue
            }
            guard var transcript = parsed else { continue }
            let sourceUncertain = transcript.usageIsUncertain(on: original.day)
            if sourceUncertain { mark(index, .sourceIncomplete) }
            let main = transcript.requests.filter { !$0.isSupplemental && !$0.isReplay && $0.belongs(to: original.day)
                && $0.billing.tokens["input_tokens"] != nil && $0.billing.tokens["output_tokens"] != nil }
            let observed = Dictionary(grouping: main, by: \.modelForAccounting).mapValues { $0.reduce(TokenUsage.zero) { $0 + $1.usage } }.filter { $0.value.total > 0 }
            let reported = Dictionary(grouping: session.modelBreakdowns, by: \.id).mapValues { $0.reduce(TokenUsage.zero) { $0 + $1.usage } }.filter { $0.value.total > 0 }
            guard Set(observed.keys) == Set(reported.keys), observed.allSatisfy({ name, value in
                guard let other = reported[name] else { return false }
                return TokenCategory.allCases.allSatisfy { value.value(for: $0) == other.value(for: $0) }
            }) else { mark(index, .sourceMismatch); continue }
            if !events.isEmpty {
                transcript = ClaudeTelemetryAccounting.recover(transcript, sessionID: session.rawID, events: events, day: original.day)
                replacements.insert(index)
            }
            if !sourceUncertain, transcript.usageIsUncertain(on: original.day) { mark(index, .telemetryAmbiguous) }
            for var request in transcript.requests where !request.isReplay && (replacements.contains(index) || request.isSupplemental) {
                if !request.belongs(to: original.day) {
                    if (request.accountingIntervalStart ?? .distantFuture) < original.day.end,
                       (request.accountingIntervalEnd ?? .distantPast) >= original.day.date {
                        mark(index, .dayBoundary)
                    }
                    continue
                }
                guard request.billing.tokens["input_tokens"] != nil, request.billing.tokens["output_tokens"] != nil else {
                    mark(index, .sourceIncomplete); continue
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
                }) else { failed.insert(index); mark(index, .calculationFailed); continue }
                result.sessions[index].usage = .zero
                result.sessions[index].costReasons?.removeAll { $0 == .missingPrice }
                result.sessions[index].modelBreakdowns = []
                result.sessions[index].models = []
            }
            for request in requests {
                guard let index = owners[request.id] else { continue }
                guard !failed.contains(index) else { continue }
                guard let usage = prices[request.id], TokenCategory.allCases.allSatisfy({ usage.value(for: $0) == request.usage.value(for: $0) }) else {
                    mark(index, .calculationFailed); continue
                }
                if usage.costIsIncomplete == true { mark(index, .missingPrice) }
                result.sessions[index].usage = result.sessions[index].usage + usage
                if let model = result.sessions[index].modelBreakdowns.firstIndex(where: { $0.id == request.modelForAccounting }) {
                    result.sessions[index].modelBreakdowns[model].usage = result.sessions[index].modelBreakdowns[model].usage + usage
                } else {
                    result.sessions[index].modelBreakdowns.append(.init(id: request.modelForAccounting, usage: usage))
                    if !result.sessions[index].models.contains(request.modelForAccounting) { result.sessions[index].models.append(request.modelForAccounting) }
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { for index in Set(owners.values) { mark(index, .calculationFailed) } }
        for index in incomplete { result.sessions[index].usage.costIsIncomplete = true }
        return result
    }

    private static func background<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    /// Read bounded chunks and retain accounting fields only. Large message/tool
    /// bodies must not impose the old 32 MiB whole-file limit on daily accounting.
    static func read(_ file: URL, sessionID: String) throws -> SessionTranscript? {
        let maximumBytes = TranscriptService.maximumBytes
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes else { throw UsageError.outputTooLarge }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var pending = Data(), readBytes = 0, retainedBytes = 0
        var events: [TranscriptEvent] = []
        var hasSnapshot = false
        func consume(_ line: Data) throws {
            try Task.checkCancellation()
            guard !line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) else { return }
            guard let root = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if root["modelUsage"] != nil {
                guard root["sessionId"] as? String == sessionID else { throw UsageError.malformedJSON("Session accounting identity mismatch") }
                hasSnapshot = true
            }
            let keys = Set(["type", "timestamp", "created_at", "sessionId", "requestId", "clientRequestId", "client_request_id", "uuid", "parentUuid", "isSidechain", "isApiErrorMessage", "modelUsage", "role", "model", "usage"])
            var row = root.filter { keys.contains($0.key) }
            if let attachment = root["attachment"] as? [String: Any] { row["attachment"] = attachment.filter { $0.key == "type" } }
            if let message = root["message"] as? [String: Any] {
                var safe = message.filter { ["id", "role", "model", "usage"].contains($0.key) }
                if let blocks = message["content"] as? [[String: Any]] {
                    safe["content"] = blocks.map { $0.filter { ["type", "id", "tool_use_id"].contains($0.key) } }
                }
                row["message"] = safe
            }
            let bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            retainedBytes += bytes.count
            guard retainedBytes <= 32 * 1024 * 1024, events.count < 200_000 else { throw UsageError.outputTooLarge }
            let record = TranscriptRecord(text: String(decoding: bytes, as: UTF8.self), sequence: events.count, origin: file.path)
            var event = TranscriptEvent(id: "accounting-\(events.count)", kind: .context, title: "")
            event.attach(record)
            events.append(event)
        }
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            readBytes += chunk.count
            guard readBytes <= maximumBytes else { throw UsageError.outputTooLarge }
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 10) {
                guard newline - start <= 16 * 1024 * 1024 else { throw UsageError.outputTooLarge }
                try consume(Data(pending[start..<newline]))
                start = newline + 1
            }
            pending = Data(pending[start...])
            guard pending.count <= 16 * 1024 * 1024 else { throw UsageError.outputTooLarge }
        }
        if !pending.isEmpty { try consume(pending) }
        guard hasSnapshot else { return nil }
        return try TranscriptUsageParser.annotate(.init(events: events), source: "claude")
    }
}
