import Foundation
import SQLite3

enum TranscriptError: LocalizedError {
    case unavailable(String), tooLarge, unreadable(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .unreadable(let message): return message
        case .tooLarge: return L10n.text("История слишком велика для открытия целиком (более 256 МБ). Выберите отдельный файл или откройте журнал в редакторе.")
        }
    }
}

struct TranscriptSource: Sendable {
    var variable: String
    var paths: [String]
    static let all: [String: TranscriptSource] = [
        "codex": .init(variable: "CODEX_HOME", paths: [".codex"]),
        "claude": .init(variable: "CLAUDE_CONFIG_DIR", paths: [".claude", ".config/claude"]),
        "gemini": .init(variable: "GEMINI_DATA_DIR", paths: [".gemini/tmp"]),
        "opencode": .init(variable: "OPENCODE_DATA_DIR", paths: [".local/share/opencode"]),
        "amp": .init(variable: "AMP_DATA_DIR", paths: [".local/share/amp"]),
        "droid": .init(variable: "DROID_SESSIONS_DIR", paths: [".factory/sessions"]),
        "codebuff": .init(variable: "CODEBUFF_DATA_DIR", paths: [".config/manicode", ".config/manicode-dev", ".config/manicode-staging"]),
        "hermes": .init(variable: "HERMES_HOME", paths: [".hermes"]),
        "pi": .init(variable: "PI_AGENT_DIR", paths: [".pi/agent/sessions"]),
        "goose": .init(variable: "GOOSE_PATH_ROOT", paths: [".local/share/goose", "Library/Application Support/goose", ".local/share/Block/goose"]),
        "kilo": .init(variable: "KILO_DATA_DIR", paths: [".local/share/kilo"]),
        "copilot": .init(variable: "COPILOT_HOME", paths: [".copilot"]),
        "antigravity": .init(variable: "ANTIGRAVITY_DATA_DIR", paths: [".gemini/antigravity", ".gemini/antigravity-cli", ".gemini/antigravity-ide", ".gemini/antigravity-backup", ".config/antigravity"]),
        "kimi": .init(variable: "KIMI_DATA_DIR", paths: [".kimi", ".kimi-code"]),
        "qwen": .init(variable: "QWEN_DATA_DIR", paths: [".qwen"]),
        "openclaw": .init(variable: "OPENCLAW_DIR", paths: [".openclaw", ".clawdbot", ".moltbot", ".moldbot"]),
        "grok": .init(variable: "GROK_HOME", paths: [".grok"]),
        "zcode": .init(variable: "ZCODE_HOME", paths: [".zcode"])
    ]
}

struct TranscriptService: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var environment = ProcessInfo.processInfo.environment
    static let maximumBytes = 256 * 1024 * 1024

    func load(session: UsageSession, file: URL? = nil) async throws -> SessionTranscript {
        let task = Task.detached(priority: .userInitiated) { try read(session: session, file: file) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    func roots(for source: String) -> [URL] {
        guard let config = TranscriptSource.all[source] else { return [] }
        if let value = environment[config.variable], !value.isEmpty {
            return value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }
        if ["opencode", "amp", "kilo"].contains(source), let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return [URL(fileURLWithPath: xdg).appendingPathComponent(source)]
        }
        return config.paths.map { home.appendingPathComponent($0) }
    }

    private func read(session: UsageSession, file: URL?) throws -> SessionTranscript {
        if let file { return try readFiles([file], source: session.sourceID, sessionID: session.rawID, imported: true) }
        let roots = roots(for: session.sourceID)
        guard !roots.isEmpty else {
            throw TranscriptError.unavailable(L10n.text("Для \(session.sourceLabel) пока нет автоматического поиска истории. Можно открыть сохранённый чат в JSON или JSONL."))
        }
        var matched: [URL] = []
        var databases: [URL] = []
        var inspected = 0
        var discoveryIncomplete = false
        var databaseFailure: String?
        let fm = FileManager.default
        let skipped = Set(["node_modules", ".git", "plugins", "skills", "cache", "debug", "file-history", "backups", "memories", "memory"])
        for root in roots where fm.fileExists(atPath: root.path) {
            let scanRoots: [URL]
            switch session.sourceID {
            case "codex": scanRoots = [root.appendingPathComponent("sessions"), root.appendingPathComponent("archived_sessions")]
            case "claude": scanRoots = [root.appendingPathComponent("projects")]
            case "gemini": scanRoots = [root]
            case "amp": scanRoots = [root.appendingPathComponent("threads")]
            case "copilot": scanRoots = [root.appendingPathComponent("session-state")]
            default: scanRoots = [root]
            }
            for scanRoot in scanRoots {
                guard let enumerator = fm.enumerator(at: scanRoot, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [], errorHandler: { _, _ in discoveryIncomplete = true; return true }) else { continue }
                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    if info.isDirectory == true {
                        if skipped.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                        continue
                    }
                    guard info.isRegularFile == true else { continue }
                    inspected += 1
                    guard inspected <= 30_000 else { discoveryIncomplete = true; break }
                    if ["db", "sqlite", "sqlite3"].contains(url.pathExtension) {
                        databases.append(url); continue
                    }
                    guard ["json", "jsonl", "ndjson"].contains(url.pathExtension),
                          !url.lastPathComponent.hasSuffix(".settings.json"),
                          !["settings.json", "config.json", "auth.json", "history.jsonl", "sessions-index.json"].contains(url.lastPathComponent) else { continue }
                    if Self.matches(url: url, sessionID: session.rawID) { matched.append(url) }
                    else {
                        do { if try headerMatches(url, sessionID: session.rawID) { matched.append(url) } }
                        catch is CancellationError { throw CancellationError() }
                        catch { discoveryIncomplete = true }
                    }
                }
            }
        }
        // Databases contain many sessions. Every query below is bound to the selected ID.
        for database in databases.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            if session.sourceID == "antigravity" && !Self.matches(url: database, sessionID: session.rawID) { continue }
            let records: [[String: Any]]
            do { records = try TranscriptDatabase.read(database, sessionID: session.rawID) }
            catch is CancellationError { throw CancellationError() }
            catch { databaseFailure = error.localizedDescription; continue }
            if !records.isEmpty {
                var decoder = TranscriptDecoder(source: session.sourceID)
                for record in records { decoder.append(record) }
                let events = decoder.finish()
                var notices: [String] = []
                if !events.contains(where: \.isMessage) { notices.append(L10n.text("В базе найдены только служебные записи. Текст переписки в этом формате недоступен.")) }
                return .init(events: events, files: [database], notices: notices)
            }
        }
        guard !matched.isEmpty else {
            if let databaseFailure { throw TranscriptError.unreadable(databaseFailure) }
            let message = session.sourceID == "antigravity" && !databases.isEmpty
                ? L10n.text("Antigravity хранит эту историю в бинарном формате. Текст чата из него пока не читается. Можно открыть JSON-экспорт сессии.")
                : L10n.text("Не удалось найти сохранённую переписку этой сессии. История могла быть удалена, отключена или сохранена в другой папке. Выберите файл чата вручную.")
            throw TranscriptError.unavailable(discoveryIncomplete ? message + L10n.text(" Часть папок недоступна для чтения.") : message)
        }
        matched.sort { $0.path < $1.path }
        // Legacy OpenCode stores one JSON document per message, with separate parts.
        if session.sourceID == "opencode", let first = matched.first,
           first.path.contains("/storage/message/") {
            var records: [[String: Any]] = []
            let messageFiles = matched.filter { $0.path.contains("/storage/message/") }
            for url in messageFiles {
                var message = try Self.records(at: url).records.first ?? [:]
                let partsRoot = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("part").appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                let parts = (try? fm.contentsOfDirectory(at: partsRoot, includingPropertiesForKeys: nil)) ?? []
                message["parts"] = try parts.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
                    .flatMap { try Self.records(at: $0).records }
                records.append(message)
            }
            var decoder = TranscriptDecoder(source: session.sourceID)
            for record in records { decoder.append(record) }
            return .init(events: decoder.finish(), files: messageFiles)
        }
        // A sidecar and a wire log may describe the same session. Prefer the complete
        // conversation, never concatenate backups into a misleading mixed timeline.
        let preferred = matched.sorted { lhs, rhs in
            func score(_ url: URL) -> Int {
                if url.lastPathComponent == "context.jsonl" { return 0 }
                if url.lastPathComponent == "wire.jsonl" { return 2 }
                if url.path.contains("archived_sessions") { return 3 }
                return 1
            }
            return score(lhs) == score(rhs) ? lhs.path < rhs.path : score(lhs) < score(rhs)
        }
        var transcript = try readFiles([preferred[0]], source: session.sourceID, sessionID: session.rawID)
        if preferred.count > 1 {
            transcript.relatedFiles = Array(preferred.dropFirst())
            transcript.notices.append(L10n.text("Есть дополнительные журналы этой сессии. Они доступны в меню «Другие журналы»."))
        }
        if discoveryIncomplete { transcript.notices.append(L10n.text("Некоторые папки не удалось проверить. Можно выбрать файл вручную.")) }
        return transcript
    }

    static func matches(url: URL, sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        let id = sessionID.hasSuffix(".jsonl") ? String(sessionID.dropLast(6)) : sessionID
        let stem = url.deletingPathExtension().lastPathComponent
        let leaf = (id as NSString).lastPathComponent
        if url.lastPathComponent == "chat-messages.json", id.split(separator: "/").count == 3 {
            let chat = url.deletingLastPathComponent()
            let project = chat.deletingLastPathComponent().deletingLastPathComponent()
            let channel = project.deletingLastPathComponent().deletingLastPathComponent()
            return [channel.lastPathComponent, project.lastPathComponent, chat.lastPathComponent].joined(separator: "/") == id
        }
        if stem == id || stem == leaf || stem.hasSuffix("_" + leaf) { return true }
        if leaf.count >= 36, UUID(uuidString: String(leaf.suffix(36))) != nil,
           stem.hasSuffix(String(leaf.suffix(36))) { return true }
        if url.deletingLastPathComponent().lastPathComponent == leaf { return true }
        if id.contains("/"), url.path.contains("/" + id + "/") { return true }
        return false
    }

    private func headerMatches(_ url: URL, sessionID: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if size > Self.maximumBytes { return false }
        let data = try handle.read(upToCount: url.pathExtension == "json" ? size : 128 * 1024) ?? Data()
        // Inspect only identities, not arbitrary occurrences of an ID in chat text.
        let candidates: [Data] = ["jsonl", "ndjson"].contains(url.pathExtension)
            ? data.split(separator: UInt8(10)).prefix(3).map { Data($0) } : [data]
        for candidate in candidates {
            guard let record = (try? JSONSerialization.jsonObject(with: candidate)) as? [String: Any] else { continue }
            let payload = TranscriptJSON.object(record["payload"])
            for key in ["sessionId", "sessionID", "session_id", "id"] where record[key] as? String == sessionID || payload[key] as? String == sessionID { return true }
        }
        return false
    }

    private func readFiles(_ files: [URL], source: String, sessionID: String, imported: Bool = false) throws -> SessionTranscript {
        var decoder = TranscriptDecoder(source: source)
        var notices: [String] = imported ? [L10n.text("Открыт выбранный файл. Его содержимое может отличаться от сессии в статистике.")] : []
        for url in files {
            try Task.checkCancellation()
            let parsed = try Self.records(at: url)
            if parsed.invalid > 0 { notices.append(L10n.text("Не удалось разобрать строк: \(parsed.invalid). Они сохранены в служебных событиях; история может быть неполной.")) }
            for record in parsed.records { try Task.checkCancellation(); decoder.append(record) }
        }
        let events = decoder.finish()
        guard !events.isEmpty else { throw TranscriptError.unavailable(L10n.text("Файл пока не содержит записей. Обновите историю после следующего сообщения.")) }
        if !events.contains(where: \.isMessage) { notices.append(L10n.text("В журнале нет распознанных сообщений. Все доступные записи находятся в служебных событиях.")) }
        return .init(events: events, files: files, notices: notices)
    }

    static func records(at url: URL) throws -> (records: [[String: Any]], invalid: Int) {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw TranscriptError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw TranscriptError.tooLarge }
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let records = json as? [[String: Any]] { return (records, 0) }
            if let record = json as? [String: Any] {
                for key in ["messages", "chatMessages", "events"] {
                    if let records = record[key] as? [[String: Any]] {
                        // OpenCode's export wraps each message in {info, parts}.
                        var metadata = record
                        metadata.removeValue(forKey: key)
                        metadata["type"] = "session_metadata"
                        return ([metadata] + records.map { row in
                            if var info = row["info"] as? [String: Any] { info["parts"] = row["parts"]; return info }
                            return row
                        }, 0)
                    }
                }
                return ([record], 0)
            }
        }
        var records: [[String: Any]] = []
        var invalid = 0
        for line in data.split(separator: 10) {
            try Task.checkCancellation()
            if line.allSatisfy({ $0 == 32 || $0 == 13 || $0 == 9 }) { continue }
            if let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] { records.append(record) }
            else {
                invalid += 1
                records.append(["type": "unparsed", "original_line": String(decoding: line, as: UTF8.self)])
            }
        }
        return (records, invalid)
    }
}

/// SQLite is supplied by macOS. Read-only connections and bound session IDs keep
/// an active agent's database intact, including its WAL. No CLI or network needed.
enum TranscriptDatabase {
    static func read(_ url: URL, sessionID: String) throws -> [[String: Any]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw TranscriptError.unreadable(L10n.text("Не удалось открыть базу истории: \(url.lastPathComponent)."))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        try query(db, "BEGIN", values: []).forEach { _ in }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        let tables = try query(db, "SELECT name FROM sqlite_master WHERE type = 'table'", values: []).compactMap { $0["name"] as? String }
        for table in ["transcript_events", "session_message", "message", "messages", "model_usage"] where tables.contains(table) {
            let columns = try query(db, "PRAGMA table_info(\"\(table)\")", values: []).compactMap { $0["name"] as? String }
            guard let sessionColumn = ["session_id", "sessionId", "sessionID"].first(where: columns.contains) else { continue }
            let order = ["seq", "sequence", "time_created", "created_at", "timestamp", "id"].first(where: columns.contains)
            let sql = "SELECT * FROM \"\(table)\" WHERE \"\(sessionColumn)\" = ?" + (order.map { " ORDER BY \"\($0)\"" } ?? "")
            let rows = try query(db, sql, values: [sessionID])
            guard !rows.isEmpty else { continue }
            var partsByMessage: [String: [[String: Any]]] = [:]
            for partsTable in ["part", "session_part"] where tables.contains(partsTable) {
                let partColumns = try query(db, "PRAGMA table_info(\"\(partsTable)\")", values: []).compactMap { $0["name"] as? String }
                guard partColumns.contains("session_id"), partColumns.contains("message_id") else { continue }
                let partOrder = partColumns.contains("id") ? " ORDER BY id" : ""
                for part in try query(db, "SELECT * FROM \"\(partsTable)\" WHERE session_id = ?" + partOrder, values: [sessionID]) {
                    guard let id = part["message_id"] as? String else { continue }
                    partsByMessage[id, default: []].append(unpack(part))
                }
            }
            return rows.map { row in
                var record = unpack(row)
                if let id = row["id"] as? String, let parts = partsByMessage[id] { record["parts"] = parts }
                // Goose stores content as a JSON string; Hermes uses text plus a
                // serialized tool_calls column. Decode either without losing fields.
                for key in ["content", "tool_calls"] {
                    if let text = record[key] as? String, let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) { record[key] = json }
                }
                return record
            }
        }
        return []
    }

    private static func unpack(_ row: [String: Any]) -> [String: Any] {
        for key in ["event_json", "data", "message_json"] {
            if let text = row[key] as? String, let data = text.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                var result = row
                result.removeValue(forKey: key)
                result.merge(json) { _, new in new }
                return result
            }
        }
        return row
    }

    private static func query(_ db: OpaquePointer?, _ sql: String, values: [String]) throws -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw TranscriptError.unreadable(L10n.text("Формат базы истории не удалось прочитать.")) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            _ = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        var rows: [[String: Any]] = []
        var bytes = 0
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw TranscriptError.unreadable(L10n.text("База истории занята или повреждена. Попробуйте обновить чат.")) }
            var row: [String: Any] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                let count = Int(sqlite3_column_bytes(statement, index))
                bytes += count
                guard bytes <= TranscriptService.maximumBytes else { throw TranscriptError.tooLarge }
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, index)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, index)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, index))
                case SQLITE_BLOB: row[name] = "[Бинарные данные: \(count) байт]"
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }
}
