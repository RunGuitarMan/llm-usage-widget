import Foundation
import CoreFoundation

enum TranscriptKind: String, Sendable { case user, assistant, tool, context }

/// Bound both characters and paragraphs in the timeline. Full text remains in
/// the transcript and opens in the native, virtualized reader.
struct TranscriptTextPreview {
    let text: String
    let isTruncated: Bool

    init(_ source: String) {
        var end = source.startIndex
        var characters = 0
        var lines = 1
        while end < source.endIndex, characters < 600 {
            if source[end].isNewline {
                if lines == 12 { break }
                lines += 1
            }
            characters += 1
            end = source.index(after: end)
        }
        text = String(source[..<end])
        isTruncated = end < source.endIndex
    }
}

/// Events share immutable source records. A parallel tool response must not be
/// copied into a new, concatenated string for every tool in that response.
struct TranscriptRecord: Identifiable, Sendable {
    let id = UUID()
    let text: String
    var sequence = 0
    var origin: String? = nil
}

struct TranscriptEvent: Identifiable, Sendable {
    var id: String
    var kind: TranscriptKind
    var title: String
    var text: String = ""
    var input: String = ""
    var output: String = ""
    var timestamp: Date?
    var model: String?
    var callID: String?
    var isError = false
    var hasResult = false
    var records: [TranscriptRecord] = []
    var requestIDs: [String] = []
    var isUsageOnly = false
    var isToolResultOnly = false
    var timing: TranscriptTiming?
    var service: TranscriptServiceEvent?
    var isHiddenContext: Bool { kind == .context && service == nil }
    var origin: String? { records.compactMap(\.origin).first.map { ($0 as NSString).lastPathComponent } }
    var raw: String { records.map(\.text).joined(separator: "\n\n") }

    init(id: String, kind: TranscriptKind, title: String, text: String = "", input: String = "",
         output: String = "", timestamp: Date? = nil, model: String? = nil, callID: String? = nil,
         isError: Bool = false, hasResult: Bool = false, raw: String = "") {
        self.id = id; self.kind = kind; self.title = title; self.text = text
        self.input = input; self.output = output; self.timestamp = timestamp; self.model = model
        self.callID = callID; self.isError = isError; self.hasResult = hasResult
        if !raw.isEmpty { records = [TranscriptRecord(text: raw)] }
    }

    mutating func attach(_ record: TranscriptRecord?) {
        guard let record, !records.contains(where: { $0.id == record.id }) else { return }
        records.append(record)
    }

    var toolSummary: String? {
        guard kind == .tool, let data = input.data(using: .utf8),
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for key in ["title", "description", "command", "cmd", "file_path", "path", "url"] {
            if let value = fields[key] as? String, !value.isEmpty {
                let summary = ["file_path", "path"].contains(key) ? (value as NSString).lastPathComponent : value
                if title.contains(summary) { return nil }
                return String(summary.prefix(120)).replacingOccurrences(of: "\n", with: " ")
            }
        }
        return nil
    }

    var searchableText: String { ([title, text, input, output, raw] + (service?.facts ?? [])).joined(separator: "\n") }
    func matches(_ query: String) -> Bool {
        ([title, text, input, output] + (service?.facts ?? [])).contains { $0.localizedCaseInsensitiveContains(query) }
            || records.contains { $0.text.localizedCaseInsensitiveContains(query) }
    }
    var isMessage: Bool { kind == .user || kind == .assistant }
}

struct SessionTranscript: Sendable {
    var id = UUID()
    var events: [TranscriptEvent]
    var files: [URL] = []
    var relatedFiles: [URL] = []
    var notices: [String] = []
    var requests: [TranscriptRequest] = []
    var usageSupported = false
    var usageUncertain = false
    var imported = false
    var telemetryPricingSpeed: String?
    var claudeSnapshotValidated = false
    var claudeSessionID: String?
    var claudeAccountingCoverage: [ClaudeAccountingCoverage] = []
    var telemetryRates: [String: [String: Double]] = [:]

    var messageCount: Int { events.filter { $0.isMessage && !$0.isUsageOnly }.count }
    var toolCount: Int { events.filter { $0.kind == .tool }.count }
    var exportText: String {
        var exportedRecords = Set<UUID>()
        return events.map { event in
            var parts = ["## \(event.title)"]
            if let date = event.timestamp { parts.append(date.ISO8601Format()) }
            if let timing = event.timing { parts.append(timing.exportText) }
            if let service = event.service, !service.facts.isEmpty { parts.append(service.facts.joined(separator: " · ")) }
            if !event.text.isEmpty { parts.append(event.text) }
            if !event.input.isEmpty { parts.append(L10n.text("Передано:\n\(event.input)")) }
            if !event.output.isEmpty { parts.append(L10n.text("Получено:\n\(event.output)")) }
            // Export is lossless, including metadata and unrecognized content blocks.
            for record in event.records where exportedRecords.insert(record.id).inserted {
                parts.append(L10n.text("Исходная запись:\n\(record.text)"))
            }
            return parts.joined(separator: "\n\n")
        }.joined(separator: "\n\n---\n\n")
    }
}

enum TranscriptJSON {
    static func object(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func string(_ value: Any?) -> String? { value as? String }
    static func render(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let text = value as? String { return text }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return text
    }
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let n = number.doubleValue
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), n.isFinite, n >= 0, n <= 253_402_300_799_000 else { return nil }
            return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func content(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let values = value as? [Any] { return values.map(content).filter { !$0.isEmpty }.joined(separator: "\n\n") }
        let block = object(value)
        if let text = string(block["text"]) { return text }
        if let text = string(block["content"]) { return text }
        if let nested = block["content"] { return content(nested) }
        return render(value)
    }
}

/// Adapts transcript envelopes without discarding their original records. ccusage's
/// aggregated reports are deliberately not treated as a conversation.
struct TranscriptDecoder {
    private(set) var events: [TranscriptEvent] = []
    private struct ToolKey: Hashable { var origin: String?; var id: String }
    private var pendingTools: [ToolKey: Int] = [:]
    private var ambiguousTools: Set<ToolKey> = []
    private var codexFallbacks: [(String, TranscriptEvent)] = []
    private var codexMessages: [String: [Int]] = [:]
    private var serial = 0
    private var recordSequence = 0
    var source: String
    var origin: String?

    init(source: String) { self.source = source }

    mutating func append(_ record: [String: Any]) {
        recordSequence += 1
        let raw = TranscriptRecord(text: TranscriptJSON.render(record), sequence: recordSequence, origin: origin)
        let type = record["type"] as? String ?? ""
        let timestamp = TranscriptJSON.date(record["timestamp"] ?? record["created_at"] ?? record["time_created"] ?? record["time"])
        if source == "claude", let decoded = TranscriptServiceEvent.decode(record) {
            var event = make(.context, text: decoded.text, raw: raw, timestamp: timestamp)
            event.service = decoded.service
            event.title = decoded.service.title
            event.isError = decoded.isError
            events.append(event)
            return
        }
        if record["role"] != nil { decodeMessage(record, raw: raw, timestamp: timestamp); return }
        if source == "codex" {
            let payload = TranscriptJSON.object(record["payload"])
            if type == "response_item" {
                decodeMessage(payload, raw: raw, timestamp: timestamp)
                return
            }
            if type == "event_msg", let eventType = payload["type"] as? String,
               ["user_message", "agent_message"].contains(eventType) {
                let kind: TranscriptKind = eventType == "user_message" ? .user : .assistant
                let text = TranscriptJSON.content(payload["message"])
                codexFallbacks.append((kind.rawValue + text, make(kind, text: text, raw: raw, timestamp: timestamp)))
                return
            }
            // The readable instructions are useful for debugging, but stay folded.
            addContext(type == "turn_context" ? L10n.text("Контекст запроса") : L10n.text("Служебное событие"), raw: raw, timestamp: timestamp)
            return
        }
        if source == "copilot" {
            let data = TranscriptJSON.object(record["data"])
            if type == "user.message" || type == "assistant.message" {
                var message = data
                message["role"] = type == "user.message" ? "user" : "assistant"
                decodeMessage(message, raw: raw, timestamp: timestamp)
            } else if type == "tool.execution_start" {
                tool(name: data["toolName"] as? String, callID: data["toolCallId"] as? String,
                     input: data["arguments"], raw: raw, timestamp: timestamp)
            } else if type == "tool.execution_complete" {
                result(callID: data["toolCallId"] as? String, value: data["result"] ?? data["error"],
                       failed: data["success"] as? Bool == false, raw: raw, timestamp: timestamp)
            } else { addContext(L10n.text("Служебное событие"), raw: raw, timestamp: timestamp) }
            return
        }
        if source == "kimi" {
            let message = TranscriptJSON.object(record["message"])
            let payload = TranscriptJSON.object(message["payload"] ?? record["payload"])
            let wireType = message["type"] as? String ?? type
            switch wireType {
            case "TurnBegin":
                events.append(make(.user, text: TranscriptJSON.content(payload["user_input"]), raw: raw, timestamp: timestamp))
            case "ContentPart":
                let text = TranscriptJSON.content(payload)
                if events.last?.kind == .assistant {
                    events[events.count - 1].text += text
                    events[events.count - 1].attach(raw)
                } else { events.append(make(.assistant, text: text, raw: raw, timestamp: timestamp)) }
            case "ToolCall":
                let function = TranscriptJSON.object(payload["function"])
                tool(name: function["name"] as? String, callID: payload["id"] as? String,
                     input: function["arguments"], raw: raw, timestamp: timestamp)
            case "ToolResult":
                result(callID: payload["tool_call_id"] as? String, value: payload["return_value"], failed: false, raw: raw, timestamp: timestamp)
            default: decodeMessage(message.isEmpty ? record : message, raw: raw, timestamp: timestamp)
            }
            return
        }
        if source == "grok" {
            let update = TranscriptJSON.object(record["update"])
            let message = update.isEmpty ? record : update
            let updateType = message["sessionUpdate"] as? String ?? ""
            if ["user_message_chunk", "agent_message_chunk"].contains(updateType) {
                let kind: TranscriptKind = updateType == "user_message_chunk" ? .user : .assistant
                let text = TranscriptJSON.content(message["content"])
                if events.last?.kind == kind {
                    events[events.count - 1].text += text
                    events[events.count - 1].attach(raw)
                } else { events.append(make(kind, text: text, raw: raw, timestamp: timestamp)) }
                return
            }
            if updateType == "tool_call" {
                tool(name: message["title"] as? String, callID: message["toolCallId"] as? String,
                     input: message["rawInput"], raw: raw, timestamp: timestamp)
                return
            }
            if updateType == "tool_call_update", ["completed", "failed"].contains(message["status"] as? String ?? "") {
                result(callID: message["toolCallId"] as? String, value: message["rawOutput"] ?? message["content"],
                       failed: message["status"] as? String == "failed", raw: raw, timestamp: timestamp)
                return
            }
            decodeMessage(message, raw: raw, timestamp: timestamp)
            return
        }
        let nested = TranscriptJSON.object(record["message"])
        decodeMessage(nested.isEmpty ? record : nested, raw: raw, timestamp: timestamp,
                      fallbackRole: record["role"] as? String ?? record["type"] as? String)
    }

    mutating func finish() -> [TranscriptEvent] {
        // Codex emits the same visible message in two event streams. Match by
        // occurrence count, not a global Set: repeated user prompts remain distinct.
        var matchedOccurrences: [String: Int] = [:]
        for (key, event) in codexFallbacks {
            let occurrence = matchedOccurrences[key, default: 0]
            if let indexes = codexMessages[key], occurrence < indexes.count {
                let index = indexes[occurrence]
                matchedOccurrences[key] = occurrence + 1
                for record in event.records { events[index].attach(record) }
            } else { events.append(event) }
        }
        codexFallbacks.removeAll()
        return events.sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
    }

    private mutating func make(_ kind: TranscriptKind, text: String = "", raw: TranscriptRecord?, timestamp: Date?) -> TranscriptEvent {
        serial += 1
        let title: String
        switch kind {
        case .user: title = L10n.text("Вы")
        case .assistant: title = L10n.text("Ответ")
        case .tool: title = L10n.text("Действие")
        case .context: title = L10n.text("Контекст")
        }
        var event = TranscriptEvent(id: String(serial), kind: kind, title: title, text: text, timestamp: timestamp)
        event.attach(raw)
        return event
    }

    private mutating func decodeMessage(_ message: [String: Any], raw: TranscriptRecord?, timestamp: Date?, fallbackRole: String? = nil) {
        let type = message["type"] as? String ?? ""
        let role = message["role"] as? String ?? fallbackRole ?? type
        let timestamp = timestamp ?? TranscriptJSON.date(message["timestamp"] ?? TranscriptJSON.object(message["time"])["created"])
        let model = message["model"] as? String ?? message["modelID"] as? String
        if ["function_call", "custom_tool_call"].contains(type) {
            tool(name: message["name"] as? String, callID: message["call_id"] as? String,
                 input: message["arguments"] ?? message["input"], raw: raw, timestamp: timestamp)
            return
        }
        if ["function_call_output", "custom_tool_call_output"].contains(type) {
            result(callID: message["call_id"] as? String, value: message["output"],
                   failed: source == "codex" && (TranscriptCodexFailure.recorded(in: message)
                       || TranscriptCodexFailure.output(message["output"])), raw: raw, timestamp: timestamp)
            return
        }
        if ["tool", "toolResult", "function"].contains(role) {
            result(callID: message["tool_call_id"] as? String ?? message["toolCallId"] as? String,
                   value: message["content"] ?? message["output"], failed: message["isError"] as? Bool == true,
                   raw: raw, timestamp: timestamp)
            return
        }
        let kind: TranscriptKind
        switch role {
        case "user", "human": kind = .user
        case "assistant", "model", "gemini", "ai": kind = .assistant
        default: kind = .context
        }
        let content = message["content"] ?? message["parts"] ?? message["text"]
        let blocks: [[String: Any]]
        if let array = content as? [[String: Any]] { blocks = array }
        else if let block = content as? [String: Any] { blocks = [block] }
        else { blocks = content == nil ? [] : [["type": "text", "text": TranscriptJSON.content(content)]] }
        var body = ""
        var messageText = ""
        var pending: [[String: Any]] = []
        for block in blocks {
            let blockType = block["type"] as? String ?? "text"
            if ["tool_use", "tool_call", "toolCall", "tool_result", "tool", "thinking", "reasoning", "redacted_thinking"].contains(blockType)
                || block["functionCall"] != nil || block["functionResponse"] != nil {
                pending.append(block)
            } else if ["text", "input_text", "output_text"].contains(blockType), let text = block["text"] as? String {
                body += (body.isEmpty ? "" : "\n\n") + text
                messageText += (messageText.isEmpty ? "" : "\n\n") + text
            } else {
                let label = ["image", "input_image", "image_url"].contains(blockType) ? L10n.text("Изображение") : L10n.text("Вложение · \(blockType)")
                let name = block["filename"] as? String ?? block["path"] as? String ?? block["url"] as? String
                let description = name.map { $0.hasPrefix("data:") ? label : "\(label): \($0)" } ?? label
                body += (body.isEmpty ? "" : "\n\n") + L10n.text("[\(description) — данные в исходной записи]")
            }
        }
        if !body.isEmpty {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let isEnvironment = source == "codex" && kind == .user &&
                trimmed.hasPrefix("<environment_context>") && trimmed.hasSuffix("</environment_context>")
            var event = make(isEnvironment ? .context : kind, text: body, raw: raw, timestamp: timestamp)
            event.model = model
            if isEnvironment { event.title = L10n.text("Окружение сессии") }
            if kind == .context { event.title = ["system", "developer"].contains(role) ? L10n.text("Инструкции и контекст") : L10n.text("Служебная запись") }
            // Match the wire text, independent of translated attachment labels.
            if source == "codex", kind != .context { codexMessages[kind.rawValue + messageText, default: []].append(events.count) }
            events.append(event)
        }
        for block in pending {
            let blockType = block["type"] as? String ?? ""
            if ["thinking", "reasoning", "redacted_thinking"].contains(blockType) {
                addContext(L10n.text("Дополнительный контекст"), raw: raw, timestamp: timestamp)
            } else if blockType == "tool_result" || block["functionResponse"] != nil {
                let response = TranscriptJSON.object(block["functionResponse"])
                result(callID: block["tool_use_id"] as? String ?? response["id"] as? String,
                       value: block["content"] ?? response["response"], failed: block["is_error"] as? Bool == true,
                       raw: raw, timestamp: timestamp)
            } else {
                let function = TranscriptJSON.object(block["functionCall"])
                let state = TranscriptJSON.object(block["state"])
                let callID = block["id"] as? String ?? block["callID"] as? String ?? function["id"] as? String ?? "inline-\(serial)"
                tool(name: block["name"] as? String ?? block["tool"] as? String ?? function["name"] as? String,
                     callID: callID, input: block["input"] ?? block["arguments"] ?? state["input"] ?? function["args"], raw: raw, timestamp: timestamp)
                if let output = state["output"] ?? state["error"] {
                    result(callID: callID, value: output, failed: state["status"] as? String == "error", raw: nil, timestamp: timestamp)
                }
            }
        }
        let toolCalls = message["toolCalls"] as? [[String: Any]] ?? message["tool_calls"] as? [[String: Any]] ?? []
        for call in toolCalls {
            let function = TranscriptJSON.object(call["function"])
            let id = call["id"] as? String ?? "inline-\(serial)"
            tool(name: call["name"] as? String ?? function["name"] as? String, callID: id,
                 input: call["args"] ?? call["arguments"] ?? function["arguments"], raw: raw, timestamp: timestamp)
            if let output = call["result"] {
                result(callID: id, value: output, failed: call["status"] as? String == "error", raw: nil, timestamp: timestamp)
            }
        }
        if body.isEmpty && pending.isEmpty && toolCalls.isEmpty { addContext(L10n.text("Служебное событие"), raw: raw, timestamp: timestamp) }
    }

    private mutating func tool(name: String?, callID: String?, input: Any?, raw: TranscriptRecord?, timestamp: Date?) {
        var event = make(.tool, raw: raw, timestamp: timestamp)
        event.title = name ?? L10n.text("Вызов инструмента")
        event.callID = callID
        event.input = TranscriptJSON.render(input)
        event.timing = .init(kind: .tool, start: timestamp, status: .incomplete)
        if let callID {
            let key = ToolKey(origin: origin, id: callID)
            if pendingTools.removeValue(forKey: key) != nil { ambiguousTools.insert(key) }
            if !ambiguousTools.contains(key) { pendingTools[key] = events.count }
        }
        events.append(event)
    }
    private mutating func result(callID: String?, value: Any?, failed: Bool, raw: TranscriptRecord?, timestamp: Date?) {
        if let callID, let index = pendingTools.removeValue(forKey: .init(origin: origin, id: callID)) {
            events[index].output = TranscriptJSON.content(value)
            events[index].isError = failed
            events[index].hasResult = true
            events[index].attach(raw)
            // Inline results share the message timestamp: that is not a measured zero-duration call.
            events[index].timing = .init(kind: .tool, start: raw == nil ? nil : events[index].timestamp,
                                        end: raw == nil ? nil : timestamp)
        } else {
            var event = make(.tool, raw: raw, timestamp: timestamp)
            event.title = L10n.text("Результат инструмента")
            event.output = TranscriptJSON.content(value)
            event.callID = callID
            event.isError = failed
            event.hasResult = true
            event.isToolResultOnly = true
            events.append(event)
        }
    }
    private mutating func addContext(_ title: String, raw: TranscriptRecord?, timestamp: Date?) {
        var event = make(.context, raw: raw, timestamp: timestamp)
        event.title = title
        events.append(event)
    }
}

/// Read explicit outcome metadata, never arbitrary words in a command's output.
enum TranscriptCodexFailure {
    static func recorded(in fields: [String: Any]) -> Bool {
        if fields["isError"] as? Bool == true || fields["is_error"] as? Bool == true
            || fields["success"] as? Bool == false { return true }
        if let status = fields["status"] as? String, ["failed", "error", "declined"].contains(status.lowercased()) { return true }
        for key in ["exit_code", "exitCode"] {
            if let code = fields[key] as? NSNumber, CFGetTypeID(code) != CFBooleanGetTypeID(),
               code.doubleValue.isFinite, code.doubleValue.rounded() == code.doubleValue, code.doubleValue != 0 { return true }
        }
        return false
    }

    static func output(_ value: Any?) -> Bool {
        if let fields = value as? [String: Any] {
            return recorded(in: fields) || recorded(in: TranscriptJSON.object(fields["metadata"]))
        }
        guard let text = value as? String else { return false }
        if let fields = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            return output(fields)
        }
        // Older shell tools serialize their exit status in a header before the
        // output body. A matching line printed by the command itself is not evidence.
        let lines = text.prefix(4096).components(separatedBy: .newlines)
        guard let boundary = lines.firstIndex(where: { $0 == "Output:" || $0 == "Final output:" }) else { return false }
        for line in lines[..<boundary] {
            for prefix in ["Process exited with code ", "Exit code: "] where line.hasPrefix(prefix) {
                if let code = Int(line.dropFirst(prefix.count)), code != 0 { return true }
            }
        }
        return false
    }
}
