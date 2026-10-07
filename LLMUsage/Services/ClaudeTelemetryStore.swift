import Foundation
import Darwin

/// A synchronous gate is closed before stopping the socket. Actor work already
/// queued cannot append after the user disables collection.
final class TelemetryWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    func set(_ value: Bool) { lock.lock(); active = value; lock.unlock() }
    func withOpen<T>(_ action: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw TelemetryFailure.disabled }
        return try action()
    }
}

struct TelemetryCoverage: Codable, Sendable, Equatable {
    struct Interval: Codable, Sendable, Equatable { var start: Date; var end: Date? }
    var intervals: [Interval] = []
    var reasons: Set<String> = ["collection_may_be_partial"]
    var ignored = 0
    var rejected = 0
    var unmatched = 0
    var corrupted = 0
    var removed = 0
    var lastPacket: Date?
    var lastAPIEvent: Date?
    var lastWrite: Date?
}
struct TelemetrySessionSummary: Codable, Sendable, Identifiable {
    var id: String
    var first: Date
    var last: Date
    var lastReceived: Date
    var events: Int
    var requests: Int
    var errors: Int
    var conflicts: Int
    var models: [String]
}
struct TelemetrySnapshot: Sendable {
    let sessions: [String: [ClaudeTelemetryEvent]]
    let coverage: TelemetryCoverage
    let bytes: Int
    let summaries: [TelemetrySessionSummary]
    /// Constructed on the storage actor, never recalculated while SwiftUI reads
    /// status/count labels. Large sessions cannot put fingerprinting on main.
    init(sessions: [String: [ClaudeTelemetryEvent]] = [:], coverage: TelemetryCoverage = .init(), bytes: Int = 0) {
        self.sessions = sessions; self.coverage = coverage; self.bytes = bytes
        summaries = sessions.compactMap { id, events in
            guard let first = events.map(\.date).min(), let last = events.map(\.date).max(), let received = events.map(\.receivedAt).max() else { return nil }
            return TelemetrySessionSummary(id: id, first: first, last: last, lastReceived: received, events: events.count,
                requests: events.filter { $0.kind == .apiRequest }.count, errors: events.filter { $0.kind == .apiError }.count,
                conflicts: Self.conflictingKeys(events).count, models: Array(Set(events.compactMap(\.model))).sorted())
        }.sorted { $0.last > $1.last }
    }
    static func conflictingKeys(_ events: [ClaudeTelemetryEvent]) -> Set<String> {
        let groups = Dictionary(grouping: events.filter { $0.callKey != nil }, by: { $0.callKey! })
        return Set(groups.filter { _, rows in Set(rows.map(\.fingerprint)).count > 1 }.keys)
    }
}

actor ClaudeTelemetryStore {
    let directory: URL
    nonisolated let gate = TelemetryWriteGate()
    private let quota: Int
    private var retentionDays: Int
    private var loaded = false
    private var sessions: [String: [ClaudeTelemetryEvent]] = [:]
    private var fingerprints: [String: Set<String>] = [:]
    private var coverage = TelemetryCoverage()
    private var byteCounts: [String: Int] = [:]
    private let failWrite: @Sendable () throws -> Void

    init(directory: URL, retentionDays: Int = 30, quota: Int = 100 * 1024 * 1024, failWrite: @escaping @Sendable () throws -> Void = {}) {
        self.directory = directory; self.retentionDays = retentionDays; self.quota = quota; self.failWrite = failWrite
    }
    private func load() throws {
        guard !loaded else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { loaded = true; return }
        try TelemetryFiles.validate(directory, directory: true)
        if let data = try? TelemetryFiles.read(directory.appendingPathComponent("coverage.json")),
           let saved = try? TelemetryJSON.decode(TelemetryCoverage.self, data) { coverage = saved }
        else { coverage.reasons.insert("coverage_rebuilt") }
        if let last = coverage.intervals.last, last.end == nil {
            coverage.intervals[coverage.intervals.count - 1].end = coverage.lastWrite ?? last.start
            coverage.reasons.insert("unclean_shutdown")
        }
        // The index is a cache only. Rebuild from bounded, private session files.
        for folder in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let sid = ClaudeTelemetrySanitizer.session(folder.lastPathComponent), sid == folder.lastPathComponent else { continue }
            try TelemetryFiles.validate(folder, directory: true)
            let url = folder.appendingPathComponent("events.jsonl")
            let data = try TelemetryFiles.read(url, limit: pendingLimit)
            var events: [ClaudeTelemetryEvent] = []; var keys = Set<String>(); var damaged = false
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where !line.isEmpty {
                guard index < lines.count - 1, let event = try? TelemetryJSON.decode(ClaudeTelemetryEvent.self, Data(line)),
                      Self.valid(event), event.sessionID == sid else { coverage.corrupted += 1; damaged = true; continue }
                if keys.insert(event.fingerprint).inserted { events.append(event) }
            }
            sessions[sid] = events; fingerprints[sid] = keys; byteCounts[sid] = data.count
            if damaged {
                coverage.reasons.insert("corrupt_or_truncated_events")
                // Never append to a torn record or preserve unknown fields from disk.
                try persist(sid, events)
            }
        }
        // Events commit before metadata. Recover activity after a crash between
        // those commits without treating startup or a self-test as a new API event.
        if let received = sessions.values.flatMap({ $0 }).map(\.receivedAt).max(),
           coverage.lastAPIEvent == nil || received > coverage.lastAPIEvent! {
            coverage.lastAPIEvent = received
            coverage.lastPacket = max(coverage.lastPacket ?? received, received)
            coverage.lastWrite = max(coverage.lastWrite ?? received, received)
            coverage.reasons.insert("activity_recovered_from_events")
        }
        loaded = true
        try maintain(now: Date())
        try saveMetadata()
    }
    private static func valid(_ event: ClaudeTelemetryEvent) -> Bool {
        guard event.schemaVersion == 1, ClaudeTelemetrySanitizer.session(event.sessionID) != nil,
              event.requestID.map({ ClaudeTelemetrySanitizer.identifier($0) != nil }) ?? true,
              event.clientRequestID.map({ ClaudeTelemetrySanitizer.identifier($0) != nil }) ?? true,
              event.model.map({ ClaudeTelemetrySanitizer.model($0) != nil }) ?? true,
              event.costUSD.map({ ClaudeTelemetrySanitizer.decimal($0) != nil }) ?? true,
              event.durationMS.map({ $0.isFinite && $0 >= 0 }) ?? true,
              [event.input, event.output, event.cacheRead, event.cacheWrite, event.sequence, event.costMicros, event.attempt].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { return false }
        return true
    }
    func setCollecting(_ enabled: Bool, now: Date = Date()) throws {
        if !enabled { gate.set(false) }
        try load()
        if enabled {
            try TelemetryFiles.createDirectory(directory)
            if coverage.intervals.last?.end != nil || coverage.intervals.isEmpty { coverage.intervals.append(.init(start: now)) }
        } else if !coverage.intervals.isEmpty && coverage.intervals.last?.end == nil {
            coverage.intervals[coverage.intervals.count - 1].end = now
        }
        if coverage.intervals.count > 512 { coverage.intervals.removeFirst(coverage.intervals.count - 512); coverage.reasons.insert("older_intervals_pruned") }
        if FileManager.default.fileExists(atPath: directory.path) { try saveMetadata() }
        if enabled { gate.set(true) }
    }
    @discardableResult
    func accept(_ batch: ClaudeTelemetryBatch, now: Date = Date()) throws -> Int {
        try load()
        return try gate.withOpen {
            try failWrite()
            try TelemetryFiles.createDirectory(directory)
            var accepted = 0
            for (sid, incoming) in Dictionary(grouping: batch.events, by: \.sessionID) {
                guard incoming.allSatisfy(Self.valid) else { throw TelemetryFailure.invalidJSON }
                var keys = fingerprints[sid] ?? []
                let unique = incoming.filter { keys.insert($0.fingerprint).inserted }
                if !unique.isEmpty {
                    let events = (sessions[sid] ?? []) + unique
                    try persist(sid, events)
                    // Update memory after the durable event commit even if a later
                    // metadata write fails. A retried OTLP batch remains idempotent.
                    sessions[sid] = events; fingerprints[sid] = keys; accepted += unique.count
                }
            }
            coverage.ignored += batch.ignored; coverage.rejected += batch.rejected; coverage.unmatched += batch.unmatched
            coverage.lastPacket = now
            if !batch.events.isEmpty { coverage.lastAPIEvent = now }
            if batch.rejected + batch.unmatched > 0 { coverage.reasons.insert("rejected_or_unattributed_events") }
            coverage.lastWrite = now
            try maintain(now: now)
            try saveMetadata()
            return accepted
        }
    }
    func rejectPacket() throws {
        try load()
        try gate.withOpen {
            coverage.rejected += 1; coverage.reasons.insert("rejected_packets"); try saveMetadata()
        }
    }
    func snapshot() throws -> TelemetrySnapshot {
        try load()
        return .init(sessions: sessions, coverage: coverage, bytes: try storageBytes())
    }
    func events(sessionID: String) throws -> [ClaudeTelemetryEvent] { try load(); return sessions[sessionID.lowercased()] ?? [] }
    func setRetention(_ days: Int, now: Date = Date()) throws {
        guard [7, 30, 90].contains(days) else { throw TelemetryFailure.storage }
        retentionDays = days; try load(); try maintain(now: now)
        if FileManager.default.fileExists(atPath: directory.path) { try saveMetadata() }
    }
    func delete(sessionIDs: Set<String>? = nil) throws {
        try load()
        for sid in sessions.keys.sorted() where sessionIDs == nil || sessionIDs!.contains(sid) { try remove(sid, reason: "user_deleted_events") }
        if FileManager.default.fileExists(atPath: directory.path) { try saveMetadata() }
    }
    // A bounded incoming packet can temporarily cross quota before oldest-first
    // cleanup. Rejecting at quota here would prevent that cleanup from ever running.
    private var pendingLimit: Int { max(quota, 16 * 1024 * 1024) + TelemetryHTTPParser.bodyLimit }
    private func persist(_ sid: String, _ events: [ClaudeTelemetryEvent]) throws {
        guard ClaudeTelemetrySanitizer.session(sid) == sid else { throw TelemetryFailure.storage }
        var data = Data()
        for event in events { data.append(try TelemetryJSON.encode(event)); data.append(10) }
        // Bound a single session too; no silent truncation when the quota is impossible.
        guard data.count <= pendingLimit else { throw TelemetryFailure.quota }
        let folder = directory.appendingPathComponent(sid)
        try TelemetryFiles.createDirectory(folder)
        try TelemetryFiles.atomic(data, to: folder.appendingPathComponent("events.jsonl"))
        byteCounts[sid] = data.count
    }
    private func maintain(now: Date) throws {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        for sid in sessions.keys.sorted() {
            let old = sessions[sid] ?? []
            let keep = old.filter { $0.date >= cutoff }
            if keep.count != old.count {
                coverage.removed += old.count - keep.count; coverage.reasons.insert("retention_removed_events")
                if keep.isEmpty { try remove(sid, reason: "retention_removed_events", count: false) }
                else { try persist(sid, keep); sessions[sid] = keep; fingerprints[sid] = Set(keep.map(\.fingerprint)) }
            }
        }
        // Remove oldest individual deliveries, including old portions of resumed
        // sessions. Persist the gap before a subsequent packet can be acknowledged.
        while try storageBytes() > quota {
            var excess = try storageBytes() - quota
            let ordered = sessions.flatMap { sid, events in events.map { (sid, $0) } }.sorted { $0.1.receivedAt < $1.1.receivedAt }
            guard !ordered.isEmpty else { throw TelemetryFailure.quota }
            var removed: [String: Set<String>] = [:]
            for (sid, event) in ordered where excess > 0 {
                removed[sid, default: []].insert(event.fingerprint)
                excess -= try TelemetryJSON.encode(event).count + 1
            }
            for (sid, keys) in removed {
                let keep = sessions[sid, default: []].filter { !keys.contains($0.fingerprint) }
                coverage.removed += keys.count; coverage.reasons.insert("quota_removed_events")
                if keep.isEmpty { try remove(sid, reason: "quota_removed_events", count: false) }
                else { try persist(sid, keep); sessions[sid] = keep; fingerprints[sid] = Set(keep.map(\.fingerprint)) }
            }
        }
    }
    private func storageBytes() throws -> Int {
        let summaries = TelemetrySnapshot(sessions: sessions, coverage: coverage).summaries
        return try byteCounts.values.reduce(0, +) + TelemetryJSON.encode(summaries).count
            + summaries.reduce(0) { try $0 + TelemetryJSON.encode($1).count } + TelemetryJSON.encode(coverage).count
    }

    private func remove(_ sid: String, reason: String, count: Bool = true) throws {
        let folder = directory.appendingPathComponent(sid)
        if FileManager.default.fileExists(atPath: folder.path) { try TelemetryFiles.validate(folder, directory: true); try FileManager.default.removeItem(at: folder) }
        if count { coverage.removed += sessions[sid]?.count ?? 0 }
        coverage.reasons.insert(reason); sessions.removeValue(forKey: sid); fingerprints.removeValue(forKey: sid); byteCounts.removeValue(forKey: sid)
    }
    private func saveMetadata() throws {
        try TelemetryFiles.createDirectory(directory)
        let snapshot = TelemetrySnapshot(sessions: sessions, coverage: coverage)
        for summary in snapshot.summaries {
            try TelemetryFiles.atomic(TelemetryJSON.encode(summary), to: directory.appendingPathComponent(summary.id).appendingPathComponent("summary.json"))
        }
        try TelemetryFiles.atomic(TelemetryJSON.encode(snapshot.summaries), to: directory.appendingPathComponent("index.json"))
        try TelemetryFiles.atomic(TelemetryJSON.encode(coverage), to: directory.appendingPathComponent("coverage.json"))
    }
}

enum TelemetryFiles {
    static func validate(_ url: URL, directory: Bool) throws {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_uid == getuid(), s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              s.st_mode & 0o077 == 0, directory || s.st_nlink == 1 else { throw TelemetryFailure.storage }
    }
    static func createDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try validate(url, directory: true); return }
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) { try createDirectory(parent) }
        guard mkdir(url.path, 0o700) == 0 else { throw TelemetryFailure.storage }
        try validate(url, directory: true)
    }
    static func read(_ url: URL, limit: Int = 16 * 1024 * 1024) throws -> Data {
        try validate(url, directory: false)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TelemetryFailure.storage }; defer { close(fd) }
        var s = stat(); guard fstat(fd, &s) == 0, s.st_size <= limit else { throw TelemetryFailure.storage }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }
    static func atomic(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent(); try validate(parent, directory: true)
        let temp = parent.appendingPathComponent(".tmp-" + UUID().uuidString)
        let fd = open(temp.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TelemetryFailure.storage }
        defer { close(fd); unlink(temp.path) }
        try ClaudeSettingsEnvEditor.writeAll(data, fd: fd)
        guard fsync(fd) == 0, rename(temp.path, url.path) == 0 else { throw TelemetryFailure.storage }
        let dir = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dir >= 0 else { throw TelemetryFailure.storage }; defer { close(dir) }
        guard fsync(dir) == 0 else { throw TelemetryFailure.storage }
    }
}
