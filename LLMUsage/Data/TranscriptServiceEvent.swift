import Foundation
import CoreFoundation

/// Useful Claude service records remain context for usage attribution, but get
/// their own readable timeline rows. Unknown records keep the lossless fallback.
struct TranscriptServiceEvent: Sendable {
    enum Kind: String, Sendable { case compaction, apiError, hookBlocked, hookError, hookContext, diagnostics }
    var kind: Kind
    var trigger: String?
    var tokensBefore: Int64?
    var tokensAfter: Int64?
    var duration: Double?
    var retryAttempt: Int64?
    var maxRetries: Int64?
    var retryDelay: Double?
    var hook: String?
    var hookEvent: String?

    var title: String {
        switch kind {
        case .compaction:
            if trigger == "auto" { return L10n.text("Контекст сжат автоматически") }
            if trigger == "manual" { return L10n.text("Контекст сжат вручную") }
            return L10n.text("Контекст сжат")
        case .apiError: return L10n.text("Ошибка API")
        case .hookBlocked: return L10n.text("Хук заблокировал продолжение")
        case .hookError: return L10n.text("Ошибка хука")
        case .hookContext: return L10n.text("Инструкции от хука")
        case .diagnostics: return L10n.text("Диагностика редактора")
        }
    }

    var isSupplementary: Bool { kind == .hookContext || kind == .diagnostics }
    var facts: [String] {
        var values: [String] = []
        if let tokensBefore, let tokensAfter {
            values.append(L10n.text("\(tokensBefore) → \(tokensAfter) токенов"))
        } else if let tokensBefore { values.append(L10n.text("До сжатия: \(tokensBefore) токенов")) }
        else if let tokensAfter { values.append(L10n.text("После сжатия: \(tokensAfter) токенов")) }
        if let duration { values.append(TranscriptTimingFormat.duration(duration)) }
        if let retryAttempt, let maxRetries { values.append(L10n.text("Повтор \(retryAttempt) из \(maxRetries)")) }
        else if let retryAttempt { values.append(L10n.text("Повтор \(retryAttempt)")) }
        if let retryDelay { values.append(L10n.text("Повтор через \(TranscriptTimingFormat.duration(retryDelay))")) }
        if let hookEvent { values.append(hookEvent) }
        if let hook, hook != hookEvent { values.append(hook) }
        return values
    }

    static func decode(_ root: [String: Any]) -> (service: Self, text: String, isError: Bool)? {
        let type = root["type"] as? String
        guard type == "system" || type == "attachment" else { return nil }
        let fields = type == "attachment" ? TranscriptJSON.object(root["attachment"]) : root
        let subtype = fields[type == "attachment" ? "type" : "subtype"] as? String
        var service: Self
        var text = ""
        var isError = false
        switch subtype {
        case "compact_boundary":
            let metadata = TranscriptJSON.object(fields["compactMetadata"])
            service = .init(kind: .compaction, trigger: metadata["trigger"] as? String,
                            tokensBefore: integer(metadata["preTokens"]), tokensAfter: integer(metadata["postTokens"]),
                            duration: number(metadata["durationMs"] ?? fields["durationMs"]).map { $0 / 1000 })
            text = content(fields["content"])
        case "api_error":
            service = .init(kind: .apiError, retryAttempt: integer(fields["retryAttempt"]),
                            maxRetries: integer(fields["maxRetries"]), retryDelay: number(fields["retryInMs"]).map { $0 / 1000 })
            text = unique([errorText(fields["error"]), errorText(fields["cause"]), content(fields["content"])])
            isError = true
        case "hook_blocking_error", "hook_non_blocking_error", "hook_error":
            service = .init(kind: subtype == "hook_blocking_error" ? .hookBlocked : .hookError)
            let blocking = TranscriptJSON.object(fields["blockingError"])
            text = unique([content(blocking["blockingError"] ?? fields["blockingError"]),
                           content(fields["stderr"]), errorText(fields["error"]), content(fields["content"])])
            service.hook = nonempty(fields["hookName"]) ?? nonempty(blocking["command"]) ?? nonempty(fields["command"])
            isError = true
        case "hook_additional_context":
            service = .init(kind: .hookContext)
            let output = TranscriptJSON.object(fields["hookSpecificOutput"])
            text = content(fields["additionalContext"] ?? fields["content"] ?? output["additionalContext"])
        case "diagnostics":
            service = .init(kind: .diagnostics)
            let value = fields["files"] ?? fields["diagnostics"] ?? fields["content"]
            text = diagnosticText(value)
            isError = hasDiagnosticError(value)
        default: return nil
        }
        service.hook = service.hook ?? nonempty(fields["hookName"])
        service.hookEvent = nonempty(fields["hookEvent"]) ?? nonempty(fields["hookEventName"])
        return (service, text, isError)
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= 1_000_000_000_000 else { return nil }
        return value.doubleValue
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let value = number(value), value.rounded() == value else { return nil }
        return Int64(value)
    }
    private static func content(_ value: Any?) -> String { TranscriptJSON.content(value) }
    private static func unique(_ values: [String]) -> String {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n\n")
    }
    private static func errorText(_ value: Any?) -> String {
        guard let fields = value as? [String: Any] else { return content(value) }
        let message = unique([content(fields["message"]), content(fields["code"]), content(fields["type"]),
                              fields["error"].map(errorText) ?? "", fields["cause"].map(errorText) ?? ""])
        return message.isEmpty ? TranscriptJSON.render(value) : message
    }

    /// Editor payloads vary by extension. Format known fields, including object
    /// diagnostic codes, and retain unrecognized shapes as readable JSON.
    private static func diagnosticText(_ value: Any?) -> String {
        if let values = value as? [Any] { return values.map(diagnosticText).filter { !$0.isEmpty }.joined(separator: "\n\n") }
        guard let fields = value as? [String: Any] else { return content(value) }
        let file = nonempty(fields["filePath"]) ?? nonempty(fields["path"]) ?? nonempty(fields["uri"])
        if let diagnostics = fields["diagnostics"] {
            return [file ?? "", diagnosticText(diagnostics)].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        guard let message = nonempty(fields["message"]) else { return TranscriptJSON.render(value) }
        var labels = [file, nonempty(fields["severity"]), nonempty(fields["source"])].compactMap { $0 }
        let code = TranscriptJSON.object(fields["code"])["value"] ?? fields["code"]
        if code != nil { labels.append(TranscriptJSON.render(code)) }
        let start = TranscriptJSON.object(TranscriptJSON.object(fields["range"])["start"])
        if let line = integer(start["line"]) { labels.append(L10n.text("Строка \(line + 1)")) }
        return [labels.joined(separator: " · "), message].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private static func hasDiagnosticError(_ value: Any?) -> Bool {
        if let values = value as? [Any] { return values.contains(where: hasDiagnosticError) }
        guard let fields = value as? [String: Any] else { return false }
        // Numeric severity is deliberately not guessed: VS Code and LSP use
        // different numeric enums. Only explicit error labels are unambiguous.
        if (fields["severity"] as? String)?.lowercased() == "error" { return true }
        return fields["diagnostics"].map(hasDiagnosticError) ?? false
    }
}
