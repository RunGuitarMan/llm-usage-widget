import Foundation

struct TokenUsage: Codable, Equatable, Sendable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheCreate: Int64 = 0
    var cacheRead: Int64 = 0
    var cost: Double = 0
    // Some sources include thought/tool tokens outside the four common buckets.
    var additional: Int64? = nil
    var costIsIncomplete: Bool? = nil
    // Preserve the CLI values so exclusions are reversible without a refetch.
    var reportedAmounts: ReportedUsageAmounts? = nil

    var reported: Self {
        guard let raw = reportedAmounts else { return self }
        return .init(input: raw.input, output: raw.output, cacheCreate: raw.cacheCreate,
                     cacheRead: raw.cacheRead, cost: raw.cost, additional: raw.additional,
                     costIsIncomplete: raw.costIsIncomplete)
    }

    func replacingUsage(with usage: Self) -> Self {
        var result = usage
        if result != reported { result.reportedAmounts = ReportedUsageAmounts(reported) }
        return result
    }

    var total: Int64 { input + output + cacheCreate + cacheRead + (additional ?? 0) }
    var categories: [TokenCategory] { TokenCategory.allCases.filter { $0 != .additional || (additional ?? 0) > 0 } }
    static let zero = TokenUsage()

    static func + (lhs: Self, rhs: Self) -> Self {
        .init(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
              cacheCreate: lhs.cacheCreate + rhs.cacheCreate, cacheRead: lhs.cacheRead + rhs.cacheRead,
              cost: lhs.cost + rhs.cost,
              additional: (lhs.additional ?? 0) + (rhs.additional ?? 0),
              costIsIncomplete: lhs.costIsIncomplete == true || rhs.costIsIncomplete == true)
    }

    func value(for category: TokenCategory) -> Int64 {
        switch category {
        case .input: return input
        case .output: return output
        case .cacheCreate: return cacheCreate
        case .cacheRead: return cacheRead
        case .additional: return additional ?? 0
        }
    }
}

struct ReportedUsageAmounts: Codable, Equatable, Sendable {
    var input: Int64
    var output: Int64
    var cacheCreate: Int64
    var cacheRead: Int64
    var cost: Double
    var additional: Int64?
    var costIsIncomplete: Bool?

    init(_ usage: TokenUsage) {
        input = usage.input; output = usage.output
        cacheCreate = usage.cacheCreate; cacheRead = usage.cacheRead
        cost = usage.cost; additional = usage.additional
        costIsIncomplete = usage.costIsIncomplete
    }
}

enum TokenCategory: String, CaseIterable, Identifiable, Sendable {
    case input, output, cacheCreate, cacheRead, additional
    var id: String { rawValue }
    var title: String {
        switch self {
        case .input: return "Input"
        case .output: return "Output"
        case .cacheCreate: return "Cache create"
        case .cacheRead: return "Cache read"
        case .additional: return "Other tokens"
        }
    }
}

struct ModelUsage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var usage: TokenUsage
}

struct UsageSession: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var models: [String]
    var usage: TokenUsage
    var lastActivity: Date?
    var activityHasTime: Bool = true
    var projectPath: String?
    var modelBreakdowns: [ModelUsage] = []
    var agent: String? = nil
    var originalID: String? = nil
    var reasoningOutputTokens: Int64? = nil

    var sourceID: String { agent ?? "claude" }
    var sourceLabel: String { UsageSource.label(sourceID) }
    var rawID: String { originalID ?? id }
    var shortID: String {
        let basename = (rawID as NSString).lastPathComponent
        // Codex rollout paths end in a UUID; a date/"rollout-" prefix is not useful.
        if basename.count >= 36, UUID(uuidString: String(basename.suffix(36))) != nil {
            return UsageFormat.shortID(String(basename.suffix(36)))
        }
        return UsageFormat.shortID(basename.isEmpty ? rawID : basename)
    }
    var modelLabel: String { models.isEmpty ? L10n.text("Модель неизвестна") : models.joined(separator: ", ") }
    var modelProvider: ModelProvider { .resolve(models: models + modelBreakdowns.map(\.id)) }

    var usageComponents: [ModelUsageComponent] {
        let total = modelBreakdowns.reduce(TokenUsage.zero) { $0 + $1.usage.reported }
        if !modelBreakdowns.isEmpty,
           TokenCategory.allCases.allSatisfy({ total.value(for: $0) == usage.reported.value(for: $0) }),
           abs(total.cost - usage.reported.cost) < 0.001 {
            return modelBreakdowns.map {
                .init(models: $0.id.isEmpty ? models : [$0.id], usage: $0.usage.reported)
            }
        }
        return [.init(models: Array(Set(models + modelBreakdowns.map(\.id))).filter { !$0.isEmpty }, usage: usage.reported)]
    }

    func applyingExclusions(_ policy: ModelExclusionPolicy) -> Self {
        var result = self
        result.usage = usage.reported
        result.modelBreakdowns = modelBreakdowns.map { .init(id: $0.id, usage: $0.usage.reported) }
        let components = usageComponents
        guard components.flatMap(\.models).contains(where: { !policy.includes($0) }) else { return result }
        result.usage = usage.replacingUsage(with: components.reduce(.zero) { $0 + $1.usage(applying: policy) })
        result.modelBreakdowns = modelBreakdowns.map { part in
            var adjusted = part
            let component = ModelUsageComponent(models: part.id.isEmpty ? models : [part.id], usage: part.usage.reported)
            adjusted.usage = part.usage.replacingUsage(with: component.usage(applying: policy))
            return adjusted
        }
        return result
    }
}

/// Model authorship is independent of the CLI agent (and of a routing service).
/// Unknown model names deliberately do not inherit the agent's vendor.
enum ModelProvider: String, CaseIterable, Sendable {
    case anthropic, openai, google, custom, mixed

    var title: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .google: return "Google"
        case .custom: return L10n.text("Другой или неизвестный провайдер")
        case .mixed: return L10n.text("Несколько провайдеров")
        }
    }

    static func resolve(models: [String]) -> Self {
        let names = models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        let providers = Set(names.map { name -> Self in
            // Match whole family prefixes, including namespaces used by routers
            // and Bedrock (e.g. openrouter/anthropic/claude-… or us.anthropic.claude-…).
            if name.range(of: #"(?:^|[/.:])(?:claude|opus|sonnet|haiku)(?:$|[-_.])"#, options: .regularExpression) != nil { return .anthropic }
            if name.range(of: #"(?:^|[/.:])(?:gpt(?:$|[-_.])|chatgpt(?:$|[-_.])|o[1-9][0-9]*(?:$|[-_.]))"#, options: .regularExpression) != nil { return .openai }
            if name.range(of: #"(?:^|[/.:])(?:gemini|gemma)(?:$|[-_.])"#, options: .regularExpression) != nil { return .google }
            return .custom
        })
        return providers.count > 1 ? .mixed : providers.first ?? .custom
    }

    /// Preserve each known author. For an unrecognized model, the source logo
    /// identifies its agent without claiming that agent authored the model.
    static func logos(models: [String], sources: [String]) -> [Self] {
        let known = Set(models.map { resolve(models: [$0]) }.filter { $0 != .custom })
        if !known.isEmpty { return allCases.filter { known.contains($0) } }
        let fallback = Set(sources.compactMap { source -> Self? in
            switch source {
            case "claude": return .anthropic
            case "codex": return .openai
            case "gemini": return .google
            default: return nil
            }
        })
        return fallback.isEmpty ? [.custom] : allCases.filter { fallback.contains($0) }
    }
}

/// Exact, case-insensitive model-name overrides take precedence over provider defaults.
struct ModelExclusionPolicy: Codable, Equatable, Sendable {
    var overrides: [String: Bool] = [:] // true means include tokens and cost

    static func key(_ model: String) -> String { model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    func includes(_ model: String) -> Bool {
        let name = Self.key(model)
        if let included = overrides[name] { return included }
        let parts = name.split(whereSeparator: { $0 == "/" || $0 == ":" }).map(String.init)
        if parts.contains(where: { ["zai", "z-ai", "z.ai", "zhipu", "zhipuai"].contains($0) }) { return false }
        let modelName = parts.last ?? name
        return modelName.range(of: #"^glm(?:$|[-_.]?[0-9])"#, options: .regularExpression) == nil
    }
}

/// Raw model allocations also travel with historical daily totals.
struct ModelUsageComponent: Codable, Equatable, Sendable {
    var models: [String]
    var reportedUsage: TokenUsage

    init(models: [String], usage: TokenUsage) {
        self.models = models
        reportedUsage = usage.reported
    }

    func usage(applying policy: ModelExclusionPolicy) -> TokenUsage {
        let excluded = models.filter { !policy.includes($0) }.count
        if excluded == 0 { return reportedUsage }
        // Without a complete breakdown, exclude this allocation as a whole.
        // An intentional exclusion is not a missing-price error.
        return .zero
    }
}

enum UsageSource {
    static func label(_ id: String) -> String {
        ["claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "amp": "Amp",
         "droid": "Droid", "codebuff": "Codebuff", "hermes": "Hermes", "pi": "pi-agent",
         "goose": "Goose", "kilo": "Kilo", "copilot": "GitHub Copilot", "gemini": "Gemini CLI",
         "antigravity": "Antigravity", "kimi": "Kimi", "qwen": "Qwen", "openclaw": "OpenClaw",
         "grok": "Grok Build", "zcode": "ZCode"][id] ?? id
    }

    static func sessionID(agent: String, rawID: String) -> String {
        let encoded = Data(rawID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(agent):\(encoded)"
    }
}

struct SourceSummary: Identifiable, Equatable, Sendable {
    var id: String
    var usage: TokenUsage
    var sessionCount: Int
    var label: String { UsageSource.label(id) }
}

struct UsageDay: Codable, Equatable, Hashable, Sendable {
    var date: Date
    var timezone: String

    init(date: Date = Date(), timezone: String = "UTC") {
        let zone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        self.date = calendar.startOfDay(for: date)
        self.timezone = TimeZone(identifier: timezone) == nil ? "UTC" : timezone
    }

    var key: String { UsageFormat.dayKey(date, timezone: timezone) }
    var cacheKey: String { "\(key)|\(timezone)" }
    var end: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone)!
        return calendar.date(byAdding: .day, value: 1, to: date)!
    }
    func adding(days: Int) -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone)!
        return .init(date: calendar.date(byAdding: .day, value: days, to: date)!, timezone: timezone)
    }
    func isToday(now: Date = Date()) -> Bool { key == Self(date: now, timezone: timezone).key }
    func label(now: Date = Date()) -> String {
        let today = Self(date: now, timezone: timezone)
        if key == today.key { return L10n.text("Сегодня, \(timezone)") }
        if key == today.adding(days: -1).key { return L10n.text("Вчера, \(timezone)") }
        return "\(UsageFormat.date(date, timezone: timezone)), \(timezone)"
    }

    func spendingTitle(now: Date = Date()) -> String {
        let today = Self(date: now, timezone: timezone)
        if self == today { return L10n.text("Расходы за сегодня") }
        if self == today.adding(days: -1) { return L10n.text("Расходы за вчера") }
        return UsageFormat.date(date, timezone: timezone)
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 2
    var dataContext: UsageDataContext? = nil
    var generatedAt: Date
    var day: UsageDay
    var sessions: [UsageSession]
    var pricingKey: String? = nil
    // Derived totals prevent a stale or inconsistent CLI totals object from contradicting rows.
    var totals: TokenUsage { sessions.reduce(.zero) { $0 + $1.usage } }
    var topModel: String { modelSummaries.first?.id ?? "—" }
    var sortedSessions: [UsageSession] { SessionSort.tokens.sorted(sessions) }

    func applyingExclusions(_ policy: ModelExclusionPolicy) -> Self {
        var result = self
        result.sessions = sessions.map { $0.applyingExclusions(policy) }
        return result
    }

    func filtered(source: String) -> Self {
        guard !source.isEmpty else { return self }
        var result = self
        result.sessions = sessions.filter { $0.sourceID == source }
        return result
    }

    var sourceSummaries: [SourceSummary] {
        Dictionary(grouping: sessions, by: \.sourceID).map { id, rows in
            SourceSummary(id: id, usage: rows.reduce(.zero) { $0 + $1.usage }, sessionCount: rows.count)
        }.sorted { $0.usage.cost == $1.usage.cost ? $0.id < $1.id : $0.usage.cost > $1.usage.cost }
    }

    func isStale(now: Date = Date(), interval: TimeInterval = 180) -> Bool {
        now.timeIntervalSince(generatedAt) > max(interval * 2, 600) || !day.isToday(now: now)
    }

    func canReuse(for requestedDay: UsageDay, now: Date, liveInterval: TimeInterval) -> Bool {
        guard day == requestedDay, generatedAt <= now else { return false }
        if day.isToday(now: now) { return now.timeIntervalSince(generatedAt) < liveInterval }
        return generatedAt >= day.end && now.timeIntervalSince(generatedAt) < UsageHistory.completedDayRefreshInterval
    }

    var modelSummaries: [ModelSummary] {
        var totals: [String: TokenUsage] = [:]
        var ids: [String: Set<String>] = [:]
        for session in sessions {
            // Never attribute all session tokens to EACH model of a mixed session.
            // Incomplete breakdowns stay together, with an explicit composite label.
            let breakdownTotal = session.modelBreakdowns.reduce(TokenUsage.zero) { $0 + $1.usage }
            let complete = !session.modelBreakdowns.isEmpty
                && TokenCategory.allCases.allSatisfy { breakdownTotal.value(for: $0) == session.usage.value(for: $0) }
                && abs(breakdownTotal.cost - session.usage.cost) < 0.001
            let parts = complete ? session.modelBreakdowns : [ModelUsage(id: session.modelLabel, usage: session.usage)]
            for part in parts {
                totals[part.id, default: .zero] = totals[part.id, default: .zero] + part.usage
                ids[part.id, default: []].insert(session.id)
            }
        }
        return totals.map { ModelSummary(id: $0.key, usage: $0.value, sessionCount: ids[$0.key]?.count ?? 0) }
            .sorted { $0.usage.total == $1.usage.total ? $0.id < $1.id : $0.usage.total > $1.usage.total }
    }

    /// Reference-only rows for Models. Accounted totals and other screens keep modelSummaries.
    func reportedModelSummaries(applying policy: ModelExclusionPolicy) -> [ModelSummary] {
        var summaries: [String: ModelSummary] = [:]
        var sessionIDs: [String: Set<String>] = [:]
        for session in sessions {
            // Completeness is checked against raw values, before exclusions can turn both sides into zero.
            for component in session.usageComponents {
                let names = Array(Set(component.models)).sorted()
                let id = names.joined(separator: ", ")
                var summary = summaries[id] ?? ModelSummary(id: id, usage: .zero, sessionCount: 0,
                    isExcluded: names.contains { !policy.includes($0) })
                summary.usage = summary.usage + component.reportedUsage
                sessionIDs[id, default: []].insert(session.id)
                summary.sessionCount = sessionIDs[id]?.count ?? 0
                summary.sources = Array(Set(summary.sources + [session.sourceID])).sorted()
                summaries[id] = summary
            }
        }
        return summaries.values.sorted { $0.usage.cost == $1.usage.cost ? $0.id < $1.id : $0.usage.cost > $1.usage.cost }
    }
}

struct ModelSummary: Identifiable, Equatable, Sendable {
    var title: String { id.isEmpty ? L10n.text("Модель неизвестна") : id }
    var id: String
    var usage: TokenUsage
    var sessionCount: Int
    var isExcluded = false
    var sources: [String] = []
}

enum SessionSort: String, CaseIterable, Identifiable, Sendable {
    case tokens = "По токенам", cost = "По стоимости", activity = "По активности"
    case output = "По Output", cacheRead = "По Cache read"
    var id: String { rawValue }
    var title: String { L10n.key(rawValue) }
    static let compactCases: [Self] = [.cost, .tokens, .activity]
    static let compactLimit = 3
    var metricTitle: String {
        switch self {
        case .cost: return L10n.text("Стоимость")
        case .tokens: return L10n.text("Токены")
        case .activity: return L10n.text("Активность")
        case .output: return "Output"
        case .cacheRead: return "Cache read"
        }
    }
    var heading: String {
        switch self {
        case .cost: return L10n.text("Основные расходы")
        case .tokens: return L10n.text("Больше всего токенов")
        case .activity: return L10n.text("Последняя активность")
        case .output, .cacheRead: return L10n.text("Все сессии")
        }
    }
    var orderDescription: String {
        self == .activity ? L10n.text("Сначала недавние") : L10n.text("По убыванию")
    }
    /// Rank the entire filtered report before applying the compact row limit.
    func topSessions(in snapshot: UsageSnapshot) -> [UsageSession] {
        Array(sorted(snapshot.sessions).prefix(Self.compactLimit))
    }
    func sorted(_ sessions: [UsageSession]) -> [UsageSession] {
        sessions.sorted { a, b in
            let left: Double, right: Double
            switch self {
            case .tokens: (left, right) = (Double(a.usage.total), Double(b.usage.total))
            case .cost: (left, right) = (a.usage.cost, b.usage.cost)
            case .activity: (left, right) = (a.lastActivity?.timeIntervalSince1970 ?? 0, b.lastActivity?.timeIntervalSince1970 ?? 0)
            case .output: (left, right) = (Double(a.usage.output), Double(b.usage.output))
            case .cacheRead: (left, right) = (Double(a.usage.cacheRead), Double(b.usage.cacheRead))
            }
            return left == right ? a.id < b.id : left > right
        }
    }
}

enum UsageError: Error, LocalizedError, Equatable, Sendable {
    case missingExecutable
    case runtimeConsentRequired
    case runtimeUnavailable
    case maintenanceInProgress
    case invalidPath(String)
    case processFailed(Int32, String)
    case timedOut
    case malformedJSON(String)
    case sharedContainer(String)
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .runtimeConsentRequired: return L10n.text("Подключите встроенный ccusage")
        case .runtimeUnavailable: return L10n.text("Встроенный ccusage повреждён или недоступен")
        case .maintenanceInProgress: return L10n.text("Подготовка обновления приложения")
        case .missingExecutable: return L10n.text("ccusage не найден")
        case .invalidPath: return L10n.text("Проверьте путь к ccusage")
        case .processFailed: return L10n.text("Не удалось получить статистику")
        case .timedOut: return L10n.text("ccusage не ответил вовремя")
        case .malformedJSON: return L10n.text("Не удалось прочитать ответ ccusage")
        case .sharedContainer: return L10n.text("Общее хранилище виджета недоступно")
        case .outputTooLarge: return L10n.text("Ответ ccusage слишком большой")
        }
    }
    var recovery: String {
        switch self {
        case .runtimeConsentRequired: return L10n.text("Откройте настройки и разрешите использование встроенного компонента. Node.js и npm не нужны.")
        case .runtimeUnavailable: return L10n.text("Установите целый релиз LLM Usage заново. Последние успешные данные сохранены.")
        case .maintenanceInProgress: return L10n.text("Расчёты продолжатся после обновления приложения.")
        case .missingExecutable, .invalidPath: return L10n.text("Установите ccusage или укажите путь к существующему executable.")
        case .processFailed, .timedOut: return L10n.text("Проверьте ccusage в настройках и повторите обновление. Последние успешные данные сохранены.")
        case .malformedJSON: return L10n.text("Проверьте версию ccusage. Подробности доступны в настройках.")
        case .sharedContainer: return SharedConfiguration.usesLocalWidgetStorage
            ? L10n.text("Переустановите приложение вместе с расширением и повторите обновление данных.")
            : L10n.text("Проверьте Signing Team и одинаковый App Group у приложения и расширения.")
        case .outputTooLarge: return L10n.text("Выберите другой день или проверьте executable в настройках.")
        }
    }
    var details: String {
        switch self {
        case .invalidPath(let path): return path
        case .processFailed(let code, let stderr): return L10n.text("Код выхода: \(code)\n\(stderr)")
        case .malformedJSON(let message), .sharedContainer(let message): return L10n.key(message)
        default: return errorDescription ?? ""
        }
    }
}
