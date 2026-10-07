import Foundation

/// Matches the bundled Claude adapter's response boundaries. A timestamp alone
/// identifies an unlinked gateway record; linked fragments retain one identity.
/// Serialized fragments can each contain tool_use/end_turn as stop_reason;
/// that field does not establish a boundary between requests.
/// Owned tool results and hook_success attachments may interleave tool blocks;
/// bridging them additionally requires unchanged counters and distinct tool IDs.
struct ClaudeResponseIdentity {
    private struct Previous {
        var tailUUID: String
        var origin: String?
        var session: String?
        var message: String
        var model: String?
        var sidechain: Bool?
        var usage: [String: Int64]
        var speed: String?
        var key: String
        var toolIDs: Set<String>?
        var crossedToolResult = false
    }
    private var previous: Previous?

    mutating func observe(_ root: [String: Any], record: TranscriptRecord) -> String? {
        let kind = root["type"] as? String
        if ["progress", "file-history-snapshot", "queue-operation"].contains(kind ?? "") { return nil }
        if var old = previous, old.origin == record.origin,
           old.tailUUID == root["parentUuid"] as? String,
           let uuid = root["uuid"] as? String, !uuid.isEmpty,
           let tools = old.toolIDs {
            let results = Self.blockIDs(root, kind: "tool_result", key: "tool_use_id")
            let ownedResults = kind == "user" && results.map { $0.isSubset(of: tools) } == true
            let hook = kind == "attachment" && old.crossedToolResult
                && TranscriptJSON.object(root["attachment"])["type"] as? String == "hook_success"
            if ownedResults || hook {
                old.tailUUID = uuid
                old.crossedToolResult = true
                previous = old
                return nil
            }
        }
        let old = previous
        previous = nil
        let message = TranscriptJSON.object(root["message"])
        guard let id = message["id"] as? String, !id.isEmpty else { return nil }
        if let request = root["requestId"] as? String { return "claude|\(id)|\(request)" }
        let session = root["sessionId"] as? String
        let timestamp = root["timestamp"] as? String ?? record.id.uuidString
        let identity = [session == nil ? "file" : "session", session ?? record.origin ?? "", id, timestamp]
        guard let bytes = try? JSONSerialization.data(withJSONObject: identity) else { return nil }
        var key = "claude-requestless|" + bytes.base64EncodedString()
        guard kind == "assistant", let uuid = root["uuid"] as? String, !uuid.isEmpty,
              let raw = message["usage"] as? [String: Any],
              var usage = TranscriptUsageParser.numbers(raw, keys: ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]),
              let cache = TranscriptUsageParser.numbers(TranscriptJSON.object(raw["cache_creation"]), keys: ["ephemeral_5m_input_tokens", "ephemeral_1h_input_tokens"]) else { return key }
        if cache.values.contains(where: { $0 > 0 }) { usage["cache_creation_input_tokens"] = cache.values.reduce(0, +) }
        let model = message["model"] as? String
        let sidechain = root["isSidechain"] as? Bool
        let speed = raw["speed"] as? String
        let tools = Self.blockIDs(root, kind: "tool_use", key: "id")
        if let old, old.tailUUID == root["parentUuid"] as? String,
           old.origin == record.origin, old.session == session, old.message == id,
           old.model == model, old.sidechain == sidechain,
           old.speed == speed,
           ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].allSatisfy({ old.usage[$0, default: 0] == usage[$0, default: 0] }),
           old.usage["output_tokens", default: 0] <= usage["output_tokens", default: 0],
           !old.crossedToolResult || (
               old.usage["output_tokens", default: 0] == usage["output_tokens", default: 0]
               && tools.map { current in old.toolIDs.map { $0.isDisjoint(with: current) } == true } == true) {
            key = old.key
        }
        previous = .init(tailUUID: uuid, origin: record.origin, session: session, message: id,
                         model: model, sidechain: sidechain,
                         usage: usage, speed: speed, key: key, toolIDs: tools)
        return key
    }

    private static func blockIDs(_ root: [String: Any], kind: String, key: String) -> Set<String>? {
        guard let blocks = TranscriptJSON.object(root["message"])["content"] as? [[String: Any]], !blocks.isEmpty else { return nil }
        var ids = Set<String>()
        for block in blocks {
            guard block["type"] as? String == kind, let id = block[key] as? String, !id.isEmpty else { return nil }
            ids.insert(id)
        }
        return ids
    }
}
