import Foundation
import Darwin

/// Only inspect is allowed before consent. Plans are immutable, bound to exact
/// bytes/inode/metadata and cannot be silently refreshed during commit.
actor ClaudeSettingsEnvEditor {
    struct Pair: Codable, Equatable, Sendable { var key: String; var value: String }
    struct Identity: Equatable, Sendable {
        var device: Int32; var inode: UInt64; var mode: UInt16; var owner: UInt32; var group: UInt32
        var size: Int64; var modified: Int; var modifiedNanos: Int; var changed: Int; var changedNanos: Int
        init(_ s: stat) {
            device = s.st_dev; inode = s.st_ino; mode = s.st_mode; owner = s.st_uid; group = s.st_gid; size = s.st_size
            modified = s.st_mtimespec.tv_sec; modifiedNanos = s.st_mtimespec.tv_nsec
            changed = s.st_ctimespec.tv_sec; changedNanos = s.st_ctimespec.tv_nsec
        }
    }
    struct Preview: Sendable, Identifiable {
        let id = UUID()
        let url: URL
        let additions: [Pair]
        let matches: [String]
        let conflicts: [String]
        fileprivate let original: Data?
        fileprivate let prepared: Data
        fileprivate let identity: Identity?
        var isNoOp: Bool { conflicts.isEmpty && additions.isEmpty }
        var canApply: Bool { conflicts.isEmpty && !additions.isEmpty }
    }
    struct Receipt: Codable, Sendable {
        var path: String; var beforeHash: String?; var afterHash: String; var addedKeys: [String]; var backup: String?; var timestamp: Date
    }
    enum Stage: CaseIterable, Sendable { case backup, write, sync, beforeReplace, replace, postcheck }
    typealias Fault = @Sendable (Stage) throws -> Void
    private let fault: Fault
    init(fault: @escaping Fault = { _ in }) { self.fault = fault }

    static func profile(port: UInt16) -> [Pair] {
        [("CLAUDE_CODE_ENABLE_TELEMETRY", "1"), ("OTEL_LOGS_EXPORTER", "otlp"),
         ("OTEL_EXPORTER_OTLP_LOGS_PROTOCOL", "http/json"),
         ("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "http://127.0.0.1:\(port)/v1/logs"),
         ("OTEL_LOGS_EXPORT_INTERVAL", "1000"), ("OTEL_METRICS_EXPORTER", "none"), ("OTEL_TRACES_EXPORTER", "none"),
         ("CLAUDE_CODE_ENHANCED_TELEMETRY_BETA", "0"), ("ENABLE_ENHANCED_TELEMETRY_BETA", "0"),
         ("OTEL_LOG_USER_PROMPTS", "0"), ("OTEL_LOG_ASSISTANT_RESPONSES", "0"),
         ("OTEL_LOG_TOOL_DETAILS", "0"), ("OTEL_LOG_TOOL_CONTENT", "0"), ("OTEL_LOG_RAW_API_BODIES", "")].map { Pair(key: $0.0, value: $0.1) }
    }

    func inspect(url: URL, port: UInt16) throws -> Preview {
        try Self.validatePath(url)
        let existing = try Self.read(url)
        let data = existing?.0 ?? Data("{}".utf8)
        guard let root = try? StrictJSON.parse(data, limit: 4 * 1024 * 1024), root.members != nil,
              root["env"] == nil || root["env"]?.members != nil else { throw TelemetryFailure.invalidJSON }
        let env = root["env"]
        var additions: [Pair] = []; var matches: [String] = []; var conflicts: [String] = []
        let profile = Self.profile(port: port)
        for pair in profile {
            if let old = env?[pair.key] {
                if old.string == pair.value { matches.append(pair.key) } else { conflicts.append(pair.key) }
            } else { additions.append(pair) }
        }
        // Never redirect someone else's collector or expose helper/credential values.
        let ownedKeys = Set(profile.map(\.key))
        for member in env?.members ?? [] {
            let key = member.key
            if !ownedKeys.contains(key) && (key.hasPrefix("OTEL_EXPORTER_") || key.hasPrefix("BETA_TRACING") || key.contains("OTEL_HEADERS") || key.contains("TELEMETRY_BETA")) {
                conflicts.append(key)
            }
        }
        if root["otelHeadersHelper"] != nil { conflicts.append("otelHeadersHelper") }
        var prepared = data
        if conflicts.isEmpty && !additions.isEmpty {
            let target = env ?? root
            let insertAt = target.range.upperBound - 1
            let newline = data.contains(13) ? "\r\n" : "\n"
            let pairs = additions.map { "    \(Self.quote($0.key)): \(Self.quote($0.value))" }.joined(separator: "," + newline)
            let payload = env == nil ? "  \"env\": {" + newline + pairs + newline + "  }" : pairs
            let insertion = ((target.members?.isEmpty == false) ? "," : "") + newline + payload + newline
            prepared.insert(contentsOf: insertion.utf8, at: insertAt)
            guard let updated = try? StrictJSON.parse(prepared), let newEnv = updated["env"],
                  newEnv.members?.count == (env?.members?.count ?? 0) + additions.count else { throw TelemetryFailure.invalidJSON }
            // Check each old subtree byte-for-byte, including env values. Parser ranges
            // additionally prove that the insertion did not change its JSON meaning.
            for member in root.members ?? [] {
                if member.key == "env" {
                    for old in member.value.members ?? [] {
                        guard let new = newEnv[old.key], data[old.value.range] == prepared[new.range] else { throw TelemetryFailure.invalidJSON }
                    }
                } else {
                    guard let new = updated[member.key], data[member.value.range] == prepared[new.range] else { throw TelemetryFailure.invalidJSON }
                }
            }
            guard additions.allSatisfy({ newEnv[$0.key]?.string == $0.value }) else { throw TelemetryFailure.invalidJSON }
            var removed = prepared; removed.removeSubrange(insertAt..<(insertAt + insertion.utf8.count))
            guard removed == data else { throw TelemetryFailure.invalidJSON }
        }
        return Preview(url: url, additions: additions, matches: matches, conflicts: conflicts.sorted(), original: existing?.0,
                       prepared: prepared, identity: existing?.1)
    }

    /// Call only from the explicit Add variables action. Cancellation never calls this.
    func apply(_ preview: Preview) throws -> Receipt? {
        guard preview.conflicts.isEmpty else { throw TelemetryFailure.settingsConflict }
        if preview.isNoOp { return nil }
        var result: Result<Receipt, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: preview.url, options: .forReplacing, error: &coordinationError) { _ in
            result = Result { try self.commit(preview) }
        }
        guard coordinationError == nil, let result else { throw TelemetryFailure.write }
        return try result.get()
    }

    private func commit(_ plan: Preview) throws -> Receipt {
        try Self.validatePath(plan.url)
        try Self.verify(plan)
        let fm = FileManager.default
        let parent = plan.url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            // Only one absent leaf directory is supported, never a guessed hierarchy.
            guard mkdir(parent.path, 0o700) == 0 else { throw TelemetryFailure.unsafePath }
        }
        try Self.validatePath(plan.url)
        let dir = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw TelemetryFailure.unsafePath }; defer { close(dir) }
        let source = openat(dir, plan.url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if source >= 0 { guard flock(source, LOCK_EX | LOCK_NB) == 0 else { close(source); throw TelemetryFailure.settingsChanged } }
        defer { if source >= 0 { flock(source, LOCK_UN); close(source) } }
        try Self.verify(plan)
        var backupURL: URL?
        if let original = plan.original {
            try fault(.backup)
            let backup = parent.appendingPathComponent("settings.llmusage-backup-" + UUID().uuidString + ".json")
            let fd = openat(dir, backup.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw TelemetryFailure.backup }
            do { try Self.writeAll(original, fd: fd); guard fsync(fd) == 0 else { throw TelemetryFailure.backup }; close(fd) }
            catch { close(fd); throw TelemetryFailure.backup }
            guard (try? Data(contentsOf: backup)) == original else { throw TelemetryFailure.backup }
            backupURL = backup
        }
        let name = ".llmusage-" + UUID().uuidString + ".tmp"
        let temp = openat(dir, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard temp >= 0 else { throw TelemetryFailure.write }
        defer { close(temp); unlinkat(dir, name, 0) }
        try fault(.write); try Self.writeAll(plan.prepared, fd: temp)
        if source >= 0 {
            guard fcopyfile(source, temp, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw TelemetryFailure.write }
            if let identity = plan.identity {
                guard fchmod(temp, mode_t(identity.mode & 0o7777)) == 0 else { throw TelemetryFailure.write }
                var copied = stat(); guard fstat(temp, &copied) == 0, copied.st_uid == identity.owner, copied.st_gid == identity.group else { throw TelemetryFailure.write }
            }
        }
        try fault(.sync); guard fsync(temp) == 0 else { throw TelemetryFailure.sync }
        let tempURL = parent.appendingPathComponent(name)
        guard (try? Data(contentsOf: tempURL)) == plan.prepared else { throw TelemetryFailure.write }
        try fault(.beforeReplace)
        try fault(.replace)
        try Self.validatePath(plan.url); try Self.verify(plan)
        // The final precondition and replace are adjacent. Advisory locks cannot
        // exclude arbitrary external writers; no unverified rollback is attempted.
        if plan.original == nil {
            guard linkat(dir, name, dir, plan.url.lastPathComponent, 0) == 0 else { throw TelemetryFailure.settingsChanged }
            guard unlinkat(dir, name, 0) == 0 else { throw TelemetryFailure.postcheck }
        } else {
            guard renameat(dir, name, dir, plan.url.lastPathComponent) == 0 else { throw TelemetryFailure.replace }
        }
        guard fsync(dir) == 0 else { throw TelemetryFailure.sync }
        try fault(.postcheck)
        guard let written = try Self.read(plan.url), written.0 == plan.prepared else { throw TelemetryFailure.postcheck }
        return Receipt(path: plan.url.path, beforeHash: plan.original.map(TelemetryJSON.hash), afterHash: TelemetryJSON.hash(plan.prepared),
                       addedKeys: plan.additions.map(\.key), backup: backupURL?.path, timestamp: Date())
    }
    private static func quote(_ string: String) -> String { String(decoding: try! JSONEncoder().encode(string), as: UTF8.self) }
    private static func verify(_ plan: Preview) throws {
        let current = try read(plan.url)
        guard current?.0 == plan.original, current?.1 == plan.identity else { throw TelemetryFailure.settingsChanged }
    }
    private static func read(_ url: URL) throws -> (Data, Identity)? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw TelemetryFailure.unsafePath }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1,
              before.st_mode & 0o200 != 0, before.st_mode & 0o022 == 0, before.st_size <= 4 * 1024 * 1024 else { throw TelemetryFailure.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        var after = stat(); guard fstat(fd, &after) == 0, Identity(before) == Identity(after) else { throw TelemetryFailure.settingsChanged }
        return (data, Identity(before))
    }
    private static func validatePath(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains(".."), !url.pathComponents.contains("."), url.query == nil, url.fragment == nil else { throw TelemetryFailure.unsafePath }
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        let parts = url.pathComponents.dropFirst()
        for (index, part) in parts.enumerated() {
            cursor.appendPathComponent(part)
            var s = stat()
            if lstat(cursor.path, &s) != 0 {
                guard errno == ENOENT, index >= parts.count - 2 else { throw TelemetryFailure.unsafePath }
                continue
            }
            let final = index == parts.count - 1
            guard s.st_mode & S_IFMT == (final ? S_IFREG : S_IFDIR), s.st_uid == 0 || s.st_uid == getuid() else { throw TelemetryFailure.unsafePath }
            if !final {
                let stickyRoot = s.st_uid == 0 && s.st_mode & S_ISVTX != 0 && index < parts.count - 2
                guard s.st_mode & 0o022 == 0 || stickyRoot else { throw TelemetryFailure.unsafePath }
            }
        }
    }
    static func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TelemetryFailure.write }; offset += count
            }
        }
    }
}
