import Foundation
import zlib

struct TelemetryExportSelection: Sendable {
    var sessionIDs: Set<String>?
    var start: Date?
    var end: Date? // Exclusive, including DST-aware end of the selected day.
    var timezone: String
    func includes(_ event: ClaudeTelemetryEvent) -> Bool {
        (sessionIDs == nil || sessionIDs!.contains(event.sessionID)) && (start == nil || event.date >= start!) && (end == nil || event.date < end!)
    }
}

/// Export contains freshly constructed DTOs, never transcript.exportText, raw
/// records, a pricing receipt or a recursive copy of the telemetry directory.
enum ClaudeTelemetryExporter {
    struct Manifest: Codable {
        var schemaVersion = 1
        var appVersion: String
        var helperVersion: String?
        var accountingContract: Int?
        var claudeVersions: [String]
        var createdAt: Date
        var timezone: String
        var start: Date?
        var endExclusive: Date?
        var sessions: Int
        var events: Int
        var exactUTCTimestamps = true
        var indirectIdentificationPossible = true
        var coverageScope = "receiver_activity_not_selected_session_totals"
        var coverage: TelemetryCoverage
        var reasons: [String]
    }
    struct Accounting: Codable {
        struct Request: Codable {
            var requestID: String
            var clientRequestID: String?
            var model: String
            var timestamp: Date?
            var input: Int64
            var output: Int64
            var cacheRead: Int64
            var cacheWrite: Int64
            var cacheWrite5m: Int64?
            var cacheWrite1h: Int64?
            var speed: ClaudeTelemetryEvent.Speed?
            var appCost: Double?
            var cumulativeSessionContext: Bool
        }
        var schemaVersion = 1
        var sessionID: String
        var transcriptAvailable: Bool
        var requests: [Request]
        var rates: [String: [String: Double]]
        var rateCandidates: [String: [String]]
        var pricingSpeed: String?
        var rateUnit = "USD per token; fastMultiplier is dimensionless; maxInputTokens is a token limit"
    }
    struct Summary: Codable {
        struct Link: Codable { var requestID: String?; var match: String; var appCost: Double?; var claudeCost: String?; var priceDiffers: Bool }
        var sessionID: String
        var matched: Int
        var mainRequests: Int
        var claudeMatchedCost: String?
        var appMatchedCost: Double?
        var snapshotCountersMatch: Bool?
        var sessionClaudeCost: String?
        var sessionAppCost: Double?
        var cumulativeTotalsAreSessionContext = true
        var links: [Link]
        var reasons: [String]
    }
    struct Archive: Sendable { var bytes: Data; var sessionCount: Int; var eventCount: Int }

    static func make(snapshot: TelemetrySnapshot, selection: TelemetryExportSelection, transcripts: [String: SessionTranscript],
                     appVersion: String, helperVersion: String?, contract: Int?, now: Date = Date()) throws -> Archive {
        guard TimeZone(identifier: selection.timezone) != nil else { throw TelemetryFailure.export }
        let chosen = snapshot.sessions.mapValues { $0.filter(selection.includes) }.filter { !$0.value.isEmpty }
        var identities: [String: String] = [:]; var models: [String: String] = [:]
        func alias(_ id: String, domain: String) -> String {
            let key = domain + ":" + id
            if let existing = identities[key] { return existing }
            let value = domain == "session" ? "session-" + UUID().uuidString.lowercased() : "id-" + UUID().uuidString.lowercased()
            identities[key] = value; return value
        }
        func modelAlias(_ model: String) -> String {
            if let existing = models[model] { return existing }
            let value = "model-\(models.count + 1)"; models[model] = value; return value
        }
        func cost(_ value: Decimal?) -> String? { value.map { NSDecimalNumber(decimal: $0).stringValue } }
        var files: [(String, Data)] = []; var reasons = Set<String>()
        for sid in chosen.keys.sorted() {
            try Task.checkCancellation()
            let events = chosen[sid]!
            let sessionAlias = alias(sid, domain: "session")
            let transcript = transcripts[sid]
            let reconciliation = ClaudeTelemetryReconciler.reconcile(sessionID: sid, events: snapshot.sessions[sid] ?? [], transcript: transcript)
            reasons.formUnion(reconciliation.reasons)
            var lines = Data()
            for event in events {
                var copy = event
                copy.sessionID = sessionAlias
                copy.requestID = event.requestID.map { alias($0, domain: "request:" + sid) }
                copy.clientRequestID = event.clientRequestID.map { alias($0, domain: "client:" + sid) }
                copy.model = event.model.map(modelAlias)
                lines.append(try TelemetryJSON.encode(copy)); lines.append(10)
            }
            let selectedFingerprints = Set(events.map(\.fingerprint))
            let selectedRequests = Set(reconciliation.rows.filter { selectedFingerprints.contains($0.event.fingerprint) }.compactMap { $0.request?.id })
            let numericRequests = (transcript?.requests ?? []).filter { request in
                guard !request.isReplay else { return false }
                if request.isSupplemental { return true }
                if selection.start == nil && selection.end == nil { return true }
                return selectedRequests.contains(request.id) || request.timestamp.map { date in (selection.start == nil || date >= selection.start!) && (selection.end == nil || date < selection.end!) } == true
            }
            let requests: [Accounting.Request] = numericRequests.map { request in
                .init(requestID: alias(request.telemetryIdentity?.requestID ?? request.id, domain: "request:" + sid),
                      clientRequestID: request.telemetryIdentity?.clientRequestID.map { alias($0, domain: "client:" + sid) },
                      model: modelAlias(request.model), timestamp: request.timestamp,
                      input: request.usage.input, output: request.usage.output, cacheRead: request.usage.cacheRead, cacheWrite: request.usage.cacheCreate,
                      cacheWrite5m: request.billing.cacheCreation["ephemeral_5m_input_tokens"], cacheWrite1h: request.billing.cacheCreation["ephemeral_1h_input_tokens"],
                      speed: request.billing.speed.flatMap(ClaudeTelemetryEvent.Speed.init(rawValue:)),
                      appCost: request.priced && request.usage.cost.isFinite && request.usage.cost >= 0 ? request.usage.cost : nil,
                      cumulativeSessionContext: request.isSupplemental)
            }
            var rates: [String: [String: Double]] = [:]
            var candidates: [String: [String]] = [:]
            let usedModels = Set(numericRequests.map(\.model))
            for used in usedModels {
                let available = transcript?.telemetryRates ?? [:]
                let keys = available[used] != nil ? [used] : available.keys.filter { ClaudeTelemetryReconciler.modelsAgree($0, used) }.sorted()
                candidates[modelAlias(used)] = keys.map(modelAlias)
                for key in keys {
                    rates[modelAlias(key)] = available[key]!.filter { ClaudeTelemetryReconciler.rateKeys.contains($0.key) && $0.value.isFinite && $0.value >= 0 }
                }
            }
            let accounting = Accounting(sessionID: sessionAlias, transcriptAvailable: transcript != nil, requests: requests, rates: rates,
                rateCandidates: candidates, pricingSpeed: transcript?.telemetryPricingSpeed.flatMap { ["auto", "standard", "fast"].contains($0) ? $0 : nil })
            // Period comparison uses exactly the selected events, never a full-session
            // number disguised as a daily total. Full snapshot context stays labelled.
            let selectedRows = reconciliation.rows.filter { selectedFingerprints.contains($0.event.fingerprint) }
            let matched = selectedRows.filter { $0.match == .matched }
            let selectedMain = numericRequests.filter { !$0.isSupplemental }
            let summary = Summary(sessionID: sessionAlias, matched: matched.count, mainRequests: selectedMain.count,
                claudeMatchedCost: !matched.isEmpty && matched.allSatisfy({ $0.event.cost != nil }) ? cost(matched.reduce(Decimal(0)) { $0 + $1.event.cost! }) : nil,
                appMatchedCost: !matched.isEmpty && matched.allSatisfy({ $0.request?.priced == true }) ? matched.reduce(0) { $0 + $1.request!.usage.cost } : nil,
                snapshotCountersMatch: reconciliation.snapshotCountersMatch, sessionClaudeCost: cost(reconciliation.sessionClaudeCost), sessionAppCost: reconciliation.sessionAppCost,
                links: selectedRows.map { .init(requestID: $0.event.requestID.map { alias($0, domain: "request:" + sid) }, match: $0.match.rawValue,
                    appCost: $0.request?.priced == true ? $0.request?.usage.cost : nil, claudeCost: cost($0.event.cost), priceDiffers: $0.priceDiffers) }, reasons: reconciliation.reasons.sorted())
            let prefix = "sessions/" + sessionAlias + "/"
            files += [(prefix + "events.jsonl", lines), (prefix + "accounting.json", try TelemetryJSON.encode(accounting)), (prefix + "summary.json", try TelemetryJSON.encode(summary))]
        }
        let count = chosen.values.reduce(0) { $0 + $1.count }
        let manifest = Manifest(appVersion: appVersion, helperVersion: helperVersion, accountingContract: contract,
            claudeVersions: Array(Set(chosen.values.flatMap { $0.compactMap(\.claudeVersion) })).sorted(), createdAt: now, timezone: selection.timezone,
            start: selection.start, endExclusive: selection.end, sessions: chosen.count, events: count, coverage: snapshot.coverage, reasons: reasons.sorted())
        files.append(("manifest.json", try TelemetryJSON.encode(manifest)))
        files.append(("README.md", Data("""
        # LLM Usage — local Claude telemetry, schema 1
        This archive contains selected API metadata and numeric accounting projections only.
        IDs and all model aliases are replaced afresh for each archive. No mapping is included.
        Exact UTC times and the selected timezone are retained. Indirect identification by timing or numbers remains possible.
        costUSD is canonical; costMicros is a rounded fallback, never an additional charge.
        Errors, conflicts and service calls do not increase LLM Usage totals. Missing values are unknown, not zero.
        Durations describe individual API calls; their sum is not elapsed session time. TTL is not inferred from telemetry.
        Accounting includes numeric JSONL requests and validated cumulative modelUsage adjustments only.
        Cumulative values are whole-session context, not daily spending. Same-scope comparisons appear in summary.json.
        Rates are USD per token. Missing rates/comparisons mean unavailable; no receipt or transcript text is included.
        Collection is potentially partial even when every visible request matches. The manifest records known gaps.
        """.utf8)))
        return .init(bytes: try TelemetryZIP.encode(files), sessionCount: chosen.count, eventCount: count)
    }
    static func save(_ archive: Archive, to destination: URL) throws {
        // NSSavePanel has already authorized this exact destination. The only
        // temporary file is a private sibling, removed on every error path.
        let parent = destination.deletingLastPathComponent()
        let temp = parent.appendingPathComponent(".llmusage-export-" + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TelemetryFailure.export }
        defer { close(fd); unlink(temp.path) }
        try ClaudeSettingsEnvEditor.writeAll(archive.bytes, fd: fd)
        guard fsync(fd) == 0, (try? Data(contentsOf: temp)) == archive.bytes,
              rename(temp.path, destination.path) == 0 else { throw TelemetryFailure.export }
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw TelemetryFailure.export }; defer { close(directory) }
        guard fsync(directory) == 0 else { throw TelemetryFailure.export }
    }
}

/// Small ZIP32 writer using STORE entries. No subprocess, raw filenames, source
/// folders or temporary unredacted files. CRCs and central directory are explicit.
enum TelemetryZIP {
    static func encode(_ files: [(String, Data)]) throws -> Data {
        var output = Data(); var central = Data()
        for (name, data) in files {
            guard output.count + data.count < 256 * 1024 * 1024, name.utf8.count < 65536 else { throw TelemetryFailure.export }
            let path = Data(name.utf8), offset = UInt32(output.count), size = UInt32(data.count)
            let checksum = data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            output.le(UInt32(0x04034b50)); output.le(UInt16(20)); output.le(UInt16(0x800)); output.le(UInt16(0))
            output.le(UInt16(0)); output.le(UInt16(33)); output.le(checksum); output.le(size); output.le(size)
            output.le(UInt16(path.count)); output.le(UInt16(0)); output.append(path); output.append(data)
            central.le(UInt32(0x02014b50)); central.le(UInt16(0x0314)); central.le(UInt16(20)); central.le(UInt16(0x800)); central.le(UInt16(0))
            central.le(UInt16(0)); central.le(UInt16(33)); central.le(checksum); central.le(size); central.le(size)
            central.le(UInt16(path.count)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0))
            central.le(UInt32(0o100600 << 16)); central.le(offset); central.append(path)
        }
        guard files.count <= 65535 else { throw TelemetryFailure.export }
        let start = UInt32(output.count); output.append(central)
        output.le(UInt32(0x06054b50)); output.le(UInt16(0)); output.le(UInt16(0)); output.le(UInt16(files.count)); output.le(UInt16(files.count))
        output.le(UInt32(central.count)); output.le(start); output.le(UInt16(0))
        return output
    }
}
private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) } }
}
