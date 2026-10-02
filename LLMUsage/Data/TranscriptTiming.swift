import Foundation
import CoreFoundation

/// Timings describe an event or a whole turn, never a share of the system prompt.
/// A turn's output rate includes reasoning, tools and waits; it is not decode speed.
struct TranscriptTiming: Equatable, Sendable {
    enum Kind: Sendable { case processing, message, tool, service }
    enum Evidence: Sendable { case recorded, timestamps }
    enum Status: Sendable { case complete, interrupted, incomplete }
    var kind: Kind
    var start: Date?
    var end: Date?
    var duration: TimeInterval?
    var timeToFirstToken: TimeInterval?
    var outputTokens: Int64?
    var evidence: Evidence
    var status: Status

    init(kind: Kind, start: Date? = nil, end: Date? = nil, duration: TimeInterval? = nil,
         timeToFirstToken: TimeInterval? = nil, outputTokens: Int64? = nil,
         evidence: Evidence = .timestamps, status: Status = .complete) {
        self.kind = kind; self.evidence = evidence; self.status = status
        let start = start.flatMap(Self.validDate), end = end.flatMap(Self.validDate)
        self.start = start; self.end = end
        let reversed = start != nil && end != nil && end! < start!
        let interval = start.flatMap { begin in end.map { $0.timeIntervalSince(begin) } }
        self.duration = status == .incomplete || reversed ? nil : Self.valid(duration) ?? Self.valid(interval).flatMap { $0 > 0 ? $0 : nil }
        self.timeToFirstToken = Self.valid(timeToFirstToken)
        if let ttft = self.timeToFirstToken, let duration = self.duration, ttft > duration { self.timeToFirstToken = nil }
        self.outputTokens = outputTokens.flatMap { $0 >= 0 ? $0 : nil }
        if reversed { self.end = nil }
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 1_000_000_000_000 else { return nil }
        return value
    }
    private static func validDate(_ date: Date) -> Date? {
        let value = date.timeIntervalSince1970
        return value.isFinite && value >= 0 && value <= 253_402_300_799 ? date : nil
    }
    var tokensPerSecond: Double? {
        guard status == .complete, let duration, duration > 0, let outputTokens else { return nil }
        let rate = Double(outputTokens) / duration
        return rate.isFinite && (rate * 60).isFinite ? rate : nil
    }
    var title: String {
        switch kind {
        case .processing: return L10n.text("Обработка запроса")
        case .message: return L10n.text("Формирование сообщения")
        case .tool: return L10n.text("Выполнение инструмента")
        case .service: return L10n.text("Служебная операция")
        }
    }
    var sourceTitle: String {
        evidence == .recorded ? L10n.text("Измерено агентом") : L10n.text("По отметкам журнала")
    }
    var valueText: String {
        if status == .incomplete { return L10n.text("Завершение не записано") }
        return duration.map(TranscriptTimingFormat.duration) ?? L10n.text("Нет данных о времени")
    }
    var exportText: String {
        var lines = [title + ": " + valueText, sourceTitle]
        if let start { lines.append(L10n.text("Начало") + ": " + start.ISO8601Format()) }
        if let end { lines.append(L10n.text("Окончание") + ": " + end.ISO8601Format()) }
        if let timeToFirstToken { lines.append("TTFT: " + TranscriptTimingFormat.duration(timeToFirstToken)) }
        if let rate = tokensPerSecond { lines.append(L10n.text("Средняя скорость запроса") + ": " + TranscriptTimingFormat.rate(rate)) }
        if status == .interrupted { lines.append(L10n.text("Выполнение прервано")) }
        return lines.joined(separator: "\n")
    }
}

enum TranscriptTimingFormat {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return L10n.text("Нет данных о времени") }
        if seconds > 0 && seconds < 0.001 { return L10n.text("<1 мс") }
        if seconds < 1 { return L10n.text("\(number(seconds * 1000, digits: 0)) мс") }
        let rounded = (seconds * 10).rounded() / 10
        if rounded < 60 { return L10n.text("\(number(rounded)) с") }
        if rounded < 3600 { return L10n.text("\(number(floor(rounded / 60), digits: 0)) мин \(number(rounded.truncatingRemainder(dividingBy: 60))) с") }
        return L10n.text("\(number(floor(rounded / 3600), digits: 0)) ч \(number(floor(rounded.truncatingRemainder(dividingBy: 3600) / 60), digits: 0)) мин")
    }
    static func number(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.*f", locale: L10n.locale, digits, value)
    }
    static func rate(_ value: Double) -> String { L10n.text("\(number(value)) токенов/с") }
}

/// Runs before day/search filtering. IDs are scoped to the source log; ambiguous
/// IDs are left unassigned instead of borrowing a neighbouring event's timing.
enum TranscriptTimingParser {
    private struct Key: Hashable { var origin: String?; var id: String }
    private struct Turn {
        var user: Int?
        var start: Date?
        var end: Date?
        var duration: Double?
        var ttft: Double?
        var output: Int64?
        var outputUncertain = false
        var status = TranscriptTiming.Status.incomplete
        var hasStart = false
        var hasEnd = false
    }
    static func annotate(_ original: SessionTranscript, source: String) throws -> SessionTranscript {
        var transcript = original
        let records = TranscriptUsageParser.records(original)
        var indexesByRecord: [UUID: [Int]] = [:]
        var userIndexes: [String: Int] = [:]
        for (index, event) in original.events.enumerated() {
            if event.kind == .user { userIndexes[event.id] = index }
            // A tool's result belongs to that tool, not to its requesting message.
            let references = event.kind == .tool ? Array(event.records.prefix(1)) : event.records
            for record in references { indexesByRecord[record.id, default: []].append(index) }
            if event.kind != .tool { transcript.events[index].timing = nil }
        }
        var attribution = TranscriptUserAttribution(events: original.events)
        let requests = Dictionary(uniqueKeysWithValues: original.requests.map { ($0.id, $0) })
        var claudeOwners: [UUID: Int] = [:]
        var claudeUUIDOwners: [Key: Int] = [:]
        var lastClaudeAssistant: [String: Int] = [:]
        var wireIndexes: [Key: Set<Int>] = [:]
        var turns: [Key: Turn] = [:]
        var currentTurns: [String: String] = [:]
        // This first pass also handles item_completed arriving before response_item.
        for record in records {
            try Task.checkCancellation()
            let root = object(record.text), payload = TranscriptJSON.object(root["payload"])
            attribution.observe(record, root: root, source: source)
            let type = root["type"] as? String
            if source == "claude" {
                let origin = record.origin ?? ""
                let message = TranscriptJSON.object(root["message"])
                let linked = (indexesByRecord[record.id] ?? []).flatMap { original.events[$0].requestIDs }
                    .compactMap { requests[$0]?.userEventID }.compactMap { userIndexes[$0] }
                let isAssistant = type == "assistant" || message["role"] as? String == "assistant"
                let parentOwner = (root["parentUuid"] as? String).flatMap { claudeUUIDOwners[.init(origin: record.origin, id: $0)] }
                let owner = linked.first ?? (isAssistant ? parentOwner : nil) ?? attribution.owners[record.id].flatMap { userIndexes[$0] }
                if let owner, let uuid = root["uuid"] as? String {
                    claudeUUIDOwners[.init(origin: record.origin, id: uuid)] = owner
                }
                if isAssistant, let owner {
                    lastClaudeAssistant[origin] = owner
                    claudeOwners[record.id] = owner
                }
                if type == "system", root["subtype"] as? String == "turn_duration" {
                    if let parentOwner { claudeOwners[record.id] = parentOwner }
                    else if root["parentUuid"] == nil, let owner, lastClaudeAssistant[origin] == owner { claudeOwners[record.id] = owner }
                }
            }
            if source == "codex" {
                let eventType = type == "event_msg" ? payload["type"] as? String : nil
                let origin = record.origin ?? ""
                if let turn = payload["turn_id"] as? String,
                   eventType == "task_started" || type == "turn_context" { currentTurns[origin] = turn }
                if let turnID = payload["turn_id"] as? String ?? currentTurns[origin] {
                    let key = Key(origin: record.origin, id: turnID)
                    var turn = turns[key] ?? Turn()
                    if turn.user == nil { turn.user = attribution.owners[record.id].flatMap { userIndexes[$0] } }
                    if eventType == "task_started" {
                        turn.hasStart = true
                        turn.start = date(payload["started_at"]) ?? date(root["timestamp"])
                    }
                    if eventType == "task_complete" || eventType == "turn_aborted" {
                        turn.hasEnd = true
                        turn.status = eventType == "turn_aborted" ? .interrupted : .complete
                        turn.start = date(payload["started_at"]) ?? turn.start
                        turn.end = date(payload["completed_at"]) ?? date(root["timestamp"])
                        turn.duration = milliseconds(payload["duration_ms"])
                        turn.ttft = milliseconds(payload["time_to_first_token_ms"])
                        if currentTurns[origin] == turnID { currentTurns.removeValue(forKey: origin) }
                    }
                    if type == "token_usage_record", payload["turn_id"] as? String == turnID {
                        let usage = TranscriptJSON.object(payload["turn_token_usage"])
                        if let raw = usage["output_tokens"], let count = TranscriptUsageParser.number(raw) {
                            // The snapshot is cumulative for this exact turn, not a per-message count.
                            if let previous = turn.output, count < previous { turn.outputUncertain = true }
                            turn.output = count
                        } else { turn.outputUncertain = true }
                    }
                    turns[key] = turn
                }
                if type == "response_item" {
                    for index in indexesByRecord[record.id] ?? [] {
                        let event = original.events[index]
                        let ids = event.kind == .tool ? [event.callID, payload["id"] as? String] : [payload["id"] as? String]
                        for id in ids.compactMap({ $0 }) where !id.isEmpty {
                            wireIndexes[.init(origin: record.origin, id: id), default: []].insert(index)
                        }
                    }
                }
            }
        }
        var turnUsers: [Int: [TranscriptTiming]] = [:]
        for turn in turns.values where turn.hasStart || turn.hasEnd {
            guard let user = turn.user else { continue }
            let timing = TranscriptTiming(kind: .processing, start: turn.start, end: turn.end,
                duration: turn.duration, timeToFirstToken: turn.ttft, outputTokens: turn.outputUncertain || original.usageUncertain ? nil : turn.output,
                evidence: turn.duration == nil ? .timestamps : .recorded, status: turn.status)
            turnUsers[user, default: []].append(timing)
        }
        for (user, timings) in turnUsers where timings.count == 1 { transcript.events[user].timing = timings[0] }

        for record in records {
            try Task.checkCancellation()
            let root = object(record.text), payload = TranscriptJSON.object(root["payload"])
            if source == "codex", root["type"] as? String == "event_msg", payload["type"] as? String == "item_completed" {
                let item = TranscriptJSON.object(payload["item"])
                let type = item["type"] as? String ?? ""
                guard type != "UserMessage" else { continue }
                let targets = (item["id"] as? String).flatMap { wireIndexes[.init(origin: record.origin, id: $0)] }
                let matched = targets?.count == 1 ? targets?.first : nil
                let index = matched ?? indexesByRecord[record.id]?.first
                guard let index else { continue }
                let kind: TranscriptTiming.Kind
                switch type {
                case "AgentMessage": kind = .message
                case "CommandExecution", "McpToolCall", "FileChange", "ImageView", "Extension", "WebSearch": kind = .tool
                default: kind = .service
                }
                let rawDuration = TranscriptJSON.object(item["duration"])
                let duration = seconds(rawDuration["secs"]).flatMap { secs -> Double? in
                    guard let nanos = seconds(rawDuration["nanos"]), nanos < 1_000_000_000 else { return nil }
                    return secs + nanos / 1_000_000_000
                } ?? milliseconds(item["durationMs"])
                let timing = TranscriptTiming(kind: kind, start: millisecondDate(payload["started_at_ms"]),
                    end: millisecondDate(payload["completed_at_ms"]), duration: duration,
                    evidence: duration == nil ? .timestamps : .recorded)
                transcript.events[index].timing = timing
                if matched == nil {
                    transcript.events[index].title = type == "ContextCompaction" ? L10n.text("Сжатие контекста")
                        : type == "Reasoning" ? L10n.text("Рассуждения") : timing.title
                }
            }
            if source == "claude", let user = claudeOwners[record.id] {
                let message = TranscriptJSON.object(root["message"])
                if root["type"] as? String == "system", root["subtype"] as? String == "turn_duration",
                   let duration = milliseconds(root["durationMs"]) {
                    transcript.events[user].timing = .init(kind: .processing, end: date(root["timestamp"]),
                        duration: duration, evidence: .recorded)
                } else if message["stop_reason"] as? String == "end_turn", transcript.events[user].timing?.evidence != .recorded {
                    transcript.events[user].timing = .init(kind: .processing, start: transcript.events[user].timestamp,
                        end: date(root["timestamp"]))
                }
            }
        }
        return transcript
    }

    private static func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    private static func seconds(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 253_402_300_799_000 else { return nil }
        return number.doubleValue
    }
    private static func milliseconds(_ value: Any?) -> Double? { seconds(value).map { $0 / 1000 } }
    private static func millisecondDate(_ value: Any?) -> Date? { milliseconds(value).map { Date(timeIntervalSince1970: $0) } }
    private static func date(_ value: Any?) -> Date? {
        if value is NSNumber { return seconds(value).map { Date(timeIntervalSince1970: $0) } }
        return TranscriptJSON.date(value)
    }
}
