import Foundation
import CoreFoundation

/// Billing requests and visible events are different units. A request owns its
/// usage once, even when its text, reasoning and parallel calls occupy many rows.
struct TranscriptRequest: Identifiable, Sendable {
    var id: String
    var model: String
    var timestamp: Date?
    var eventIDs: [String]
    var billing: TranscriptBilling
    var usage: TokenUsage
    var reasoning: Int64 = 0
    var isReplay = false
    var isSidechain = false
    var priced = false
    var sequence = 0
    var accountingModel: String?
    var userEventID: String?
    var modelForAccounting: String { accountingModel ?? model }
    var anchorID: String? { eventIDs.first }
}

struct TranscriptBilling: Equatable, Sendable {
    var tokens: [String: Int64]
    var speed: String?
    var cacheCreation: [String: Int64] = [:]
}

enum TranscriptScope: String, CaseIterable, Identifiable {
    case day, session
    var id: String { rawValue }
    var title: String { self == .day ? L10n.text("Выбранный день") : L10n.text("Вся сессия") }
}

struct TranscriptToolSummary: Identifiable, Sendable {
    var id: String
    var count = 0
    var eventIDs: [String] = []
    var requestIDs: Set<String> = []
    var usage = TokenUsage.zero
}

struct TranscriptUsageSummary: Sendable {
    var requests: [TranscriptRequest]
    var expensiveRequests: [TranscriptRequest] = []
    var reported = TokenUsage.zero
    var included = TokenUsage.zero
    var tools: [TranscriptToolSummary] = []
    var unknownDates = 0

    init(transcript: SessionTranscript, day: UsageDay?, policy: ModelExclusionPolicy) {
        unknownDates = transcript.requests.filter { $0.timestamp == nil && !$0.isReplay }.count
        requests = transcript.requests.filter { request in
            guard !request.isReplay else { return false }
            guard let day else { return true }
            guard let date = request.timestamp else { return false }
            return date >= day.date && date < day.end
        }
        for request in requests {
            reported = reported + request.usage
            if policy.includes(request.modelForAccounting) { included = included + request.usage }
        }
        expensiveRequests = requests.sorted {
            if ($0.usage.costIsIncomplete == true) != ($1.usage.costIsIncomplete == true) { return $0.usage.costIsIncomplete != true }
            return $0.usage.cost == $1.usage.cost ? $0.sequence < $1.sequence : $0.usage.cost > $1.usage.cost
        }
        let byID = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
        var groups: [String: TranscriptToolSummary] = [:]
        var toolCalls = Set<String>()
        for event in transcript.events where event.kind == .tool && !event.isToolResultOnly {
            let linked = event.requestIDs.compactMap { byID[$0] }
            if let day, linked.isEmpty, event.timestamp.map({ $0 >= day.date && $0 < day.end }) != true { continue }
            if !event.requestIDs.isEmpty && linked.isEmpty { continue }
            if let callID = event.callID,
               !toolCalls.insert(callID + "|" + event.requestIDs.sorted().joined(separator: "|")).inserted { continue }
            var name = event.title
            if ["skill", "skills"].contains(event.title.lowercased()),
               let data = event.input.data(using: .utf8),
               let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let skill = (input["skill"] ?? input["name"]) as? String, !skill.isEmpty {
                name += ": " + skill
            }
            var group = groups[name] ?? .init(id: name)
            group.count += 1
            group.eventIDs.append(event.id)
            if linked.isEmpty { group.usage.costIsIncomplete = true }
            for request in linked where group.requestIDs.insert(request.id).inserted {
                group.usage = group.usage + request.usage
            }
            groups[name] = group
        }
        tools = groups.values.sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
    }

    func reconciles(with expected: TokenUsage, transcript: SessionTranscript) -> Bool {
        !transcript.imported && !transcript.usageUncertain && unknownDates == 0
            && reported.costIsIncomplete != true && expected.costIsIncomplete != true
            && TokenCategory.allCases.allSatisfy { reported.value(for: $0) == expected.value(for: $0) }
            && abs(reported.cost - expected.cost) <= max(0.000001, abs(expected.cost) * 1e-9)
    }
}

private struct TranscriptUserAttribution {
    private var users: [UUID: String] = [:]
    private var currentUser: String?
    private var origin: String?
    private var turn: String?
    private var turnUsers: [String: String] = [:]
    private var awaitingTurn = false
    private(set) var owners: [UUID: String] = [:]

    init(events: [TranscriptEvent]) {
        for event in events where event.kind == .user {
            // Codex's two streams describe one visible message. Only its first
            // occurrence starts a new attribution boundary.
            if let record = event.records.min(by: { $0.sequence < $1.sequence }) { users[record.id] = event.id }
        }
    }

    mutating func observe(_ record: TranscriptRecord, root: [String: Any], source: String) {
        if origin != record.origin {
            currentUser = nil; turn = nil; turnUsers = [:]; awaitingTurn = false
            origin = record.origin
        }
        let payload = TranscriptJSON.object(root["payload"])
        let type = root["type"] as? String
        let eventType = type == "event_msg" ? payload["type"] as? String : nil
        let turnID = payload["turn_id"] as? String
        if source == "codex", let turnID, turnID != turn,
           type == "turn_context" || eventType == "task_started" {
            currentUser = turnUsers[turnID] ?? (awaitingTurn ? currentUser : nil)
            turn = turnID
            if let currentUser { turnUsers[turnID] = currentUser }
            awaitingTurn = false
        }
        if let user = users[record.id] {
            currentUser = user
            awaitingTurn = true
            if let turn, turnUsers[turn] == nil { turnUsers[turn] = user }
        } else if type == "turn_context"
                    || (eventType == "token_count" && (turnID == nil || turnID.flatMap { turnUsers[$0] } == currentUser))
                    || payload["role"] as? String == "assistant"
                    || ["function_call", "custom_tool_call"].contains(payload["type"] as? String ?? "") {
            if let turn, let currentUser, turnID == nil || type == "turn_context" { turnUsers[turn] = currentUser }
            awaitingTurn = false
        }
        let owner: String?
        if source == "codex", let turnID { owner = turnUsers[turnID] }
        else { owner = currentUser }
        if let owner { owners[record.id] = owner }
        if source == "codex", ["task_complete", "turn_aborted"].contains(eventType ?? ""),
           turnID == nil || turnID == turn {
            currentUser = nil; turn = nil; awaitingTurn = false
        }
    }
}

enum TranscriptUsageParser {
    static let supportedSources: Set<String> = ["claude", "codex", "gemini"]
    static let maximumRequests = 50_000

    static func records(_ transcript: SessionTranscript) -> [TranscriptRecord] {
        var seen = Set<UUID>()
        return transcript.events.flatMap(\.records).filter { seen.insert($0.id).inserted }
            .sorted { $0.sequence < $1.sequence }
    }

    static func parentID(_ transcript: SessionTranscript) -> String? {
        for record in records(transcript).prefix(8) {
            let root = object(record.text)
            guard root["type"] as? String == "session_meta" else { continue }
            let payload = TranscriptJSON.object(root["payload"])
            let spawn = TranscriptJSON.object(TranscriptJSON.object(TranscriptJSON.object(payload["source"])["subagent"])["thread_spawn"])
            return (payload["forked_from_id"] ?? spawn["parent_thread_id"]) as? String
        }
        return nil
    }

    static func annotate(_ original: SessionTranscript, source: String, parent: SessionTranscript? = nil) throws -> SessionTranscript {
        var transcript = original
        guard supportedSources.contains(source) else { return transcript }
        transcript.usageSupported = true
        transcript.requests = []
        transcript.events.removeAll(where: \.isUsageOnly)
        for index in transcript.events.indices { transcript.events[index].requestIDs = [] }
        var references: [UUID: [String]] = [:]
        for event in transcript.events where event.kind == .assistant || (event.kind == .tool && !event.isToolResultOnly) {
            for record in event.records where (event.kind != .tool && source != "codex") || event.records.first?.id == record.id {
                references[record.id, default: []].append(event.id)
            }
        }
        var indexes: [String: Int] = [:]
        var userAttribution = TranscriptUserAttribution(events: transcript.events)
        var sidechainIndexes: [String: Int] = [:]
        var model = ""
        var speed: String?
        var previous: [String: Int64]?
        var pending: [String] = []
        var serial = 0
        var sequence = 0
        func append(model: String, date: Date?, events: [String], billing: TranscriptBilling,
                    usage: TokenUsage, reasoning: Int64 = 0, key: String?, sidechain: Bool = false, replayKey: String? = nil) {
            var seen = Set<String>()
            let ids = events.filter { seen.insert($0).inserted }
            let replayIndex = replayKey.flatMap { sidechainIndexes[$0] }.flatMap { index in
                sidechain || transcript.requests[index].isSidechain ? index : nil
            }
            if let index = key.flatMap({ indexes[$0] }) ?? replayIndex {
                let old = transcript.requests[index]
                var seen = Set<String>()
                let allIDs = (old.eventIDs + ids).filter { seen.insert($0).inserted }
                if source == "gemini" || (old.isSidechain && !sidechain) || (old.isSidechain == sidechain &&
                    (usage.total > old.usage.total || (usage.total == old.usage.total && old.billing.speed == nil && billing.speed != nil))) {
                    transcript.requests[index] = .init(id: old.id, model: model, timestamp: date, eventIDs: allIDs,
                        billing: billing, usage: usage, reasoning: reasoning, isSidechain: sidechain, sequence: old.sequence)
                } else { transcript.requests[index].eventIDs = allIDs }
                if let key { indexes[key] = index }
                return
            }
            serial += 1
            if let key { indexes[key] = transcript.requests.count }
            if let replayKey { sidechainIndexes[replayKey] = transcript.requests.count }
            transcript.requests.append(.init(id: "request-\(serial)", model: model, timestamp: date,
                eventIDs: ids, billing: billing, usage: usage, reasoning: reasoning, isSidechain: sidechain, sequence: sequence))
        }
        for record in records(original) {
            try Task.checkCancellation()
            sequence = record.sequence
            let root = object(record.text)
            userAttribution.observe(record, root: root, source: source)
            let date = TranscriptJSON.date(root["timestamp"] ?? root["created_at"])
            let events = references[record.id] ?? []
            if source == "claude" {
                let nested = TranscriptJSON.object(root["message"])
                let message = nested.isEmpty ? root : nested
                guard message["role"] as? String == "assistant" || root["type"] as? String == "assistant",
                      let raw = message["usage"] as? [String: Any] else { continue }
                let model = message["model"] as? String ?? ""
                guard var tokens = numbers(raw, keys: ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]),
                      let cache = numbers(TranscriptJSON.object(raw["cache_creation"]), keys: ["ephemeral_5m_input_tokens", "ephemeral_1h_input_tokens"]) else {
                    transcript.usageUncertain = true; continue
                }
                if !cache.isEmpty { tokens["cache_creation_input_tokens"] = cache.values.reduce(0, +) }
                let usage = TokenUsage(input: tokens["input_tokens", default: 0], output: tokens["output_tokens", default: 0],
                    cacheCreate: tokens["cache_creation_input_tokens", default: 0], cacheRead: tokens["cache_read_input_tokens", default: 0], costIsIncomplete: true)
                let messageID = message["id"] as? String
                let requestID = root["requestId"] as? String
                let key = messageID.map { "claude|\($0)|\(requestID ?? "\(root["sessionId"] ?? "")|\(root["timestamp"] ?? "")")" }
                append(model: model, date: date, events: events,
                       billing: .init(tokens: tokens, speed: raw["speed"] as? String, cacheCreation: cache), usage: usage,
                       key: key, sidechain: root["isSidechain"] as? Bool == true,
                       replayKey: messageID.map { $0 + "|" + (requestID == nil ? "requestless" : String(describing: root["timestamp"] ?? "")) })
                // Advisor iterations are separate billable model calls, not replacements for the main answer.
                for (index, iteration) in (raw["iterations"] as? [[String: Any]] ?? []).enumerated()
                    where iteration["type"] as? String == "advisor_message" {
                    guard let tokens = numbers(iteration, keys: ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]),
                          let advisor = iteration["model"] as? String else { transcript.usageUncertain = true; continue }
                    append(model: advisor, date: date, events: events,
                        billing: .init(tokens: tokens), usage: .init(input: tokens["input_tokens", default: 0], output: tokens["output_tokens", default: 0],
                            cacheCreate: tokens["cache_creation_input_tokens", default: 0], cacheRead: tokens["cache_read_input_tokens", default: 0], costIsIncomplete: true),
                        key: key.map { $0 + "|advisor-\(index)" })
                }
            } else if source == "codex" {
                let payload = TranscriptJSON.object(root["payload"])
                let type = root["type"] as? String ?? ""
                if type == "turn_context" || payload["type"] as? String == "thread_settings_applied" {
                    let settings = TranscriptJSON.object(payload["thread_settings"])
                    if let value = (settings["model"] ?? payload["model"]) as? String { model = value }
                    if let value = settings["service_tier"] as? String { speed = value }
                }
                if payload["type"] as? String == "user_message" || payload["role"] as? String == "user" { pending.removeAll() }
                pending += events.filter { !pending.contains($0) }
                guard type == "event_msg", payload["type"] as? String == "token_count" else { continue }
                let info = TranscriptJSON.object(payload["info"])
                let keys = ["input_tokens", "cached_input_tokens", "cache_creation_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"]
                let totals = (info["total_token_usage"] as? [String: Any]).flatMap(codexTokens)
                let last = (info["last_token_usage"] as? [String: Any]).flatMap(codexTokens)
                if totals == nil && last == nil {
                    if !info.isEmpty { transcript.usageUncertain = true }
                    continue
                }
                defer { if let totals { previous = totals } }
                if let totals, totals == previous { continue }
                var tokens = last ?? totals!
                if last == nil { for key in keys { tokens[key] = max(0, tokens[key, default: 0] - (previous?[key] ?? 0)) } }
                let input = tokens["input_tokens", default: 0]
                let cached = min(input, tokens["cached_input_tokens", default: 0])
                let create = min(input - cached, tokens["cache_creation_tokens", default: 0])
                tokens["cached_input_tokens"] = cached
                tokens["cache_creation_tokens"] = create
                let output = tokens["output_tokens", default: 0]
                guard input + output > 0 else { continue }
                let usage = TokenUsage(input: input - cached - create, output: output, cacheCreate: create, cacheRead: cached,
                    additional: max(0, tokens["total_tokens", default: input + output] - input - output), costIsIncomplete: true)
                let recordedModel = (payload["model"] ?? info["model"]) as? String ?? model
                append(model: recordedModel, date: date, events: pending, billing: .init(tokens: tokens, speed: speed),
                       usage: usage, reasoning: tokens["reasoning_output_tokens", default: 0], key: nil)
                pending.removeAll()
            } else {
                guard root["type"] as? String == "gemini", let raw = root["tokens"] as? [String: Any] else { continue }
                let aliases = ["input": ["input", "prompt", "input_tokens", "prompt_tokens"], "output": ["output", "candidates", "output_tokens", "candidates_tokens"],
                    "cached": ["cached", "cached_tokens"], "thoughts": ["thoughts", "reasoning", "thoughts_tokens", "reasoning_tokens"],
                    "tool": ["tool", "tool_tokens"], "total": ["total", "total_tokens"]]
                var tokens: [String: Int64] = [:]
                var valid = true
                for (key, names) in aliases {
                    if let value = names.compactMap({ raw[$0] }).first {
                        if let number = number(value) { tokens[key] = number } else { valid = false }
                    }
                }
                guard valid else { transcript.usageUncertain = true; continue }
                let cached = tokens["cached", default: 0], output = tokens["output", default: 0], thoughts = tokens["thoughts", default: 0]
                let tool = tokens["tool", default: 0]
                var input = tokens["input", default: 0]
                if cached > 0 && tokens["total"] == input + tool + output + thoughts { input -= min(input, cached) }
                input += tool
                append(model: root["model"] as? String ?? "", date: date, events: events, billing: .init(tokens: tokens),
                       usage: .init(input: input, output: output, cacheRead: cached,
                            additional: max(thoughts, tokens["total", default: input + output + cached + thoughts] - input - output - cached), costIsIncomplete: true),
                       reasoning: thoughts, key: (root["id"] as? String).map { "gemini|" + $0 })
            }
            guard transcript.requests.count <= maximumRequests else { throw UsageError.outputTooLarge }
        }
        if source == "codex", parentID(original) != nil {
            if let parent {
                let forkTime = records(original).first.flatMap { TranscriptJSON.date(object($0.text)["timestamp"]) }
                let parentUsage = try annotate(parent, source: source).requests.filter { request in
                    guard let forkTime, let time = request.timestamp else { return true }
                    return time <= forkTime
                }
                var matched = 0
                for (child, ancestor) in zip(transcript.requests, parentUsage) {
                    guard child.billing.tokens == ancestor.billing.tokens else { break }
                    transcript.requests[matched].isReplay = true
                    matched += 1
                }
                if matched == 0 { transcript.usageUncertain = true }
            } else { transcript.usageUncertain = true }
            if transcript.usageUncertain { transcript.notices.append(L10n.text("Не удалось подтвердить границу перенесённой истории. Сверка расходов неполная.")) }
        }
        var eventIndex = Dictionary(uniqueKeysWithValues: transcript.events.enumerated().map { ($0.element.id, $0.offset) })
        let sourceRecords = records(original).reduce(into: [Int: TranscriptRecord]()) { $0[$1.sequence] = $1 }
        for index in transcript.requests.indices {
            // Use the response's first record, not a later usage counter or tool
            // result that may arrive after the next user message.
            let firstEvent = transcript.requests[index].eventIDs.first.flatMap { eventIndex[$0] }
            let firstRecord = firstEvent.flatMap { transcript.events[$0].records.min { $0.sequence < $1.sequence } }
                ?? sourceRecords[transcript.requests[index].sequence]
            transcript.requests[index].userEventID = firstRecord.flatMap { userAttribution.owners[$0.id] }
            if source == "claude", transcript.requests[index].billing.speed == "fast" {
                transcript.requests[index].accountingModel = transcript.requests[index].model + "-fast"
            }
            if transcript.requests[index].eventIDs.isEmpty {
                let request = transcript.requests[index]
                var event = TranscriptEvent(id: request.id, kind: .assistant, title: L10n.text("Обращение к модели"), timestamp: request.timestamp, model: request.model)
                event.isUsageOnly = true
                if let record = sourceRecords[request.sequence] { event.attach(record) }
                eventIndex[event.id] = transcript.events.count
                transcript.events.append(event)
                transcript.requests[index].eventIDs = [event.id]
            }
            for id in transcript.requests[index].eventIDs {
                if let row = eventIndex[id] { transcript.events[row].requestIDs.append(transcript.requests[index].id) }
            }
        }
        transcript.events = transcript.events.enumerated().sorted {
            let left = $0.element.records.map(\.sequence).min() ?? Int.max
            let right = $1.element.records.map(\.sequence).min() ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        return transcript
    }

    private static func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    private static func codexTokens(_ raw: [String: Any]) -> [String: Int64]? {
        let aliases = ["input_tokens": ["input_tokens", "prompt_tokens", "input"],
                       "output_tokens": ["output_tokens", "completion_tokens", "output"],
                       "cached_input_tokens": ["cached_input_tokens", "cache_read_input_tokens", "cached_tokens"],
                       "cache_creation_tokens": ["cache_write_input_tokens", "cache_creation_input_tokens"],
                       "reasoning_output_tokens": ["reasoning_output_tokens", "reasoning_tokens"], "total_tokens": ["total_tokens"]]
        var result: [String: Int64] = [:]
        for (key, names) in aliases {
            guard let value = names.compactMap({ raw[$0] }).first else { result[key] = 0; continue }
            guard let value = number(value) else { return nil }
            result[key] = value
        }
        let input = result["input_tokens", default: 0]
        result["cached_input_tokens"] = min(input, result["cached_input_tokens", default: 0])
        result["cache_creation_tokens"] = min(input - result["cached_input_tokens", default: 0], result["cache_creation_tokens", default: 0])
        if result["total_tokens"] == 0 { result["total_tokens"] = input + result["output_tokens", default: 0] }
        return result
    }
    static func number(_ value: Any) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 1_000_000_000_000,
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.int64Value
    }
    private static func numbers(_ raw: [String: Any], keys: [String]) -> [String: Int64]? {
        var result: [String: Int64] = [:]
        for key in keys {
            guard let value = raw[key] else { continue }
            guard let number = number(value) else { return nil }
            result[key] = number
        }
        return result
    }
}
