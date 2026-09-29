import Foundation

private struct LocalizationFailure: Error, CustomStringConvertible { var description: String }
private func requireLocale(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw LocalizationFailure(description: message) }
}

struct LocalizationChecks {
    @MainActor static func run(check: (String, () async throws -> Void) async -> Void) async {
        let saved = L10n.preference
        defer { L10n.preference = saved }
        await check("Locale: default system, supported-language order and fallback") {
            try requireLocale(InterfaceLanguage.system.resolved(preferredLanguages: ["ru-RU", "en-US"]) == .russian, "Russian system ignored")
            try requireLocale(InterfaceLanguage.system.resolved(preferredLanguages: ["fr-FR", "ru_RU", "en"]) == .russian, "Supported fallback order ignored")
            try requireLocale(InterfaceLanguage.system.resolved(preferredLanguages: ["en-GB", "ru"]) == .english, "English priority ignored")
            try requireLocale(InterfaceLanguage.system.resolved(preferredLanguages: ["de-DE"]) == .english, "Unsupported language must fall back to English")
            try requireLocale(InterfaceLanguage.system.resolved(preferredLanguages: []) == .english, "Empty language list")
            try requireLocale(InterfaceLanguage.english.resolved(preferredLanguages: ["ru"]) == .english, "Explicit English lost")
            try requireLocale(InterfaceLanguage.russian.resolved(preferredLanguages: ["en"]) == .russian, "Explicit Russian lost")
        }
        await check("Locale: catalogue parity and interpolation argument preservation") {
            let regex = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
            func placeholders(_ s: String) -> [String] {
                regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted()
            }
            for (key, pair) in L10n.catalog {
                try requireLocale(!pair.ru.isEmpty && !pair.en.isEmpty, "Empty translation for \(key)")
                try requireLocale(placeholders(key) == placeholders(pair.ru) && placeholders(key) == placeholders(pair.en), "Placeholder mismatch: \(key)")
                try requireLocale(pair.en.range(of: #"[А-Яа-яЁё]"#, options: .regularExpression) == nil, "Russian leaked into English: \(key)")
            }
            let model = "Модель-{1}-tool/path"
            let phrase: LocalizedPhrase = "Сессии: \(model) · \("3M") токенов"
            try requireLocale(L10n.text(phrase, language: .english) == "Sessions: Модель-{1}-tool/path · 3M Tokens", "Arguments were translated or re-interpolated")
        }
        await check("Locale: Russian plurals and English singular/plural") {
            L10n.preference = .russian
            for (n, expected) in [(0,"0 сообщений"),(1,"1 сообщение"),(2,"2 сообщения"),(5,"5 сообщений"),(11,"11 сообщений"),(21,"21 сообщение"),(22,"22 сообщения"),(114,"114 сообщений")] {
                try requireLocale(L10n.count(n, .messages) == expected, "Russian plural for \(n)")
            }
            L10n.preference = .english
            try requireLocale(L10n.count(1, .actions) == "1 action" && L10n.count(2, .actions) == "2 actions" && L10n.count(21, .messages) == "21 messages", "English plurals")
        }
        await check("Locale: numbers and dates follow language; CLI day key stays POSIX") {
            let date = ISO8601DateFormatter().date(from: "2026-09-28T13:45:00Z")!
            L10n.preference = .russian
            try requireLocale(UsageFormat.cost(5.47) == "$5,47" && UsageFormat.tokens(19_149) == "19,1K", "Russian decimal")
            try requireLocale(UsageFormat.exact(7_943_608).replacingOccurrences(of: "\u{a0}", with: " ") == "7 943 608", "Russian grouping")
            try requireLocale(UsageFormat.percent(0.000001) == "<0,01%", "Russian small percent")
            let russianDate = UsageFormat.date(date, timezone: "UTC", includeTime: true)
            let russianKey = UsageFormat.dayKey(date)
            L10n.preference = .english
            try requireLocale(UsageFormat.cost(5.47) == "$5.47" && UsageFormat.exact(7_943_608) == "7,943,608", "English decimal/grouping")
            try requireLocale(UsageFormat.date(date, timezone: "UTC", includeTime: true) != russianDate, "Date locale not changed")
            try requireLocale(russianKey == "20260928" && UsageFormat.dayKey(date) == russianKey, "Localized CLI key")
        }
        await check("Locale: persisted enum identities and errors relocalize without refetch") {
            let failure = UsageError.missingExecutable
            let detail = UsageError.malformedJSON("Total token count is inconsistent with its components")
            let reportError = UsageError.malformedJSON("Нужен общий отчёт ccusage session с полями session, agent и period. Обновите ccusage до версии с поддержкой всех источников (проверено с 20.0.26).")
            L10n.preference = .russian
            try requireLocale(failure.errorDescription == "ccusage не найден", "Russian error")
            L10n.preference = .english
            try requireLocale(failure.errorDescription == "ccusage not found", "Stored error stuck in old language")
            try requireLocale(reportError.details.hasPrefix("A combined ccusage"), "Stored report helper stayed Russian")
            try requireLocale(detail.details == "Total token count is inconsistent with its components", "English technical helper")
            try requireLocale(DashboardTab.overview.rawValue == "Обзор" && DashboardTab.overview.title == "Overview", "Dashboard persisted identity changed")
            try requireLocale(DataPeriod.today.rawValue == "Сегодня" && DataPeriod.today.title == "Today", "Period identity changed")
            try requireLocale(SessionSort.cost.rawValue == "По стоимости" && SessionSort.cost.title == "By cost", "Sort identity changed")
            try requireLocale(MenuContentMode.trend.rawValue == "trend" && MenuContentMode.trend.title == "7-day trend", "Menu identity changed")
        }
        await check("Locale: widget preference round-trip and legacy status compatibility") {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let old = Data(#"{"attemptedAt":"2026-09-28T13:45:00Z","refreshMinutes":15}"#.utf8)
            let legacy = try decoder.decode(RefreshStatus.self, from: old)
            try requireLocale(legacy.interfaceLanguage == nil, "Legacy status rejected")
            let future = Data(#"{"attemptedAt":"2026-09-28T13:45:00Z","refreshMinutes":15,"interfaceLanguage":"fr"}"#.utf8)
            let unknown = try decoder.decode(RefreshStatus.self, from: future)
            try requireLocale(unknown.interfaceLanguage == .system, "Unknown widget language rejected otherwise valid status")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            for language in InterfaceLanguage.allCases {
                let status = RefreshStatus(attemptedAt: Date(), message: nil, refreshMinutes: 15, interfaceLanguage: language)
                let restored = try decoder.decode(RefreshStatus.self, from: encoder.encode(status))
                try requireLocale(restored.interfaceLanguage == language && restored.dataContext == nil, "Language mixed into data context or lost")
            }
        }
        await check("Locale: transcript UI headings translate while content, tools and raw records stay original") {
            let record: [String: Any] = ["role": "user", "content": "Русский оригинал {1}"]
            L10n.preference = .russian
            var russian = TranscriptDecoder(source: "codex")
            russian.append(record)
            let ru = russian.finish()[0]
            L10n.preference = .english
            var english = TranscriptDecoder(source: "codex")
            english.append(record)
            english.append(["type": "response_item", "payload": ["type":"function_call", "name":"Read", "arguments":"/tmp/русский.txt", "call_id":"tool-id"]])
            let en = english.finish()
            try requireLocale(ru.title == "Вы" && en[0].title == "You", "Transcript headings not localized")
            try requireLocale(ru.text == en[0].text && ru.raw == en[0].raw && en[1].title == "Read" && en[1].input == "/tmp/русский.txt", "Transcript content was translated")
            try requireLocale(SessionTranscript(events: en).exportText.contains("Sent:"), "Export helper not localized")
        }
    }
}
