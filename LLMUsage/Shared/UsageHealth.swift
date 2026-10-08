import Foundation

enum UsageCostReason: String, Codable, CaseIterable, Sendable {
    case missingPrice, sourceUnavailable, sourceTooLarge, ambiguousSource, sourceMismatch
    case sourceIncomplete, telemetryUnavailable, telemetryAmbiguous, dayBoundary, calculationFailed

    var explanation: String {
        switch self {
        case .missingPrice: return L10n.text("Для части моделей не найден тариф. Пересчёт повторно проверит доступные тарифы.")
        case .sourceUnavailable: return L10n.text("Не удалось прочитать исходный журнал сессии. Проверьте доступ к файлам и повторите пересчёт.")
        case .sourceTooLarge: return L10n.text("Журнал превышает безопасный предел обработки. Учтена доступная часть расходов.")
        case .ambiguousSource: return L10n.text("Найдено несколько журналов с одинаковым идентификатором сессии. Дополнительные расходы нельзя объединить однозначно.")
        case .sourceMismatch: return L10n.text("Счётчики журнала и отчёта различаются. Сохранена стоимость отчёта без неподтверждённых дополнений.")
        case .sourceIncomplete: return L10n.text("В исходных записях отсутствуют или противоречат друг другу данные расхода. Повторный расчёт поможет после появления исправленных записей.")
        case .telemetryUnavailable: return L10n.text("Не удалось прочитать локальную телеметрию Claude. Пересчёт повторит чтение.")
        case .telemetryAmbiguous: return L10n.text("Некоторые API-вызовы нельзя однозначно сопоставить с журналом или оценить по тарифам. Без дополнительных исходных данных точную сумму восстановить нельзя.")
        case .dayBoundary: return L10n.text("Общие расходы сессии пересекают границу дней. В журнале нет данных для точного распределения этой части по датам.")
        case .calculationFailed: return L10n.text("Дополнительный расчёт расходов завершился ошибкой. Сохранён предыдущий результат расчётчика; повторите пересчёт.")
        }
    }
}

enum UsageProblemScope {
    case all, currentDay, day(UsageDay)
}

struct UsageRecoveryResult: Equatable {
    var days: [UsageDay]
    var repaired: Int
    var incomplete: Int
    var failed: Int
    var completedAt: Date
}

enum UsageProblemKind: String, Codable, CaseIterable, Sendable {
    case storage, refresh, context, stale, cost, history

    var title: String { localizedTitle(language: nil) }
    func localizedTitle(language: InterfaceLanguage?) -> String {
        switch self {
        case .storage: return L10n.text("Данные виджета недоступны", language: language)
        case .refresh: return L10n.text("Не удалось обновить данные", language: language)
        case .context: return L10n.text("Данные требуют пересчёта", language: language)
        case .stale: return L10n.text("Данные устарели", language: language)
        case .cost: return L10n.text("Стоимость неполная", language: language)
        case .history: return L10n.text("История неполная", language: language)
        }
    }
}

struct UsageProblemReference: Codable, Equatable, Identifiable, Sendable {
    var kind: UsageProblemKind
    var day: UsageDay? = nil
    var id: String { kind.rawValue + ":" + (day?.cacheKey ?? "global") }
}

struct UsageRefreshFailure: Codable, Equatable, Sendable {
    var day: UsageDay
    var attemptedAt: Date
    var error: UsageError?
    // Only used when migrating a status written by an older app.
    var legacyMessage: String? = nil
}

struct UsageCostIssue: Codable, Equatable, Sendable {
    var day: UsageDay
    var capturedAt: Date
    var models: [String]
    var reasons: [UsageCostReason]? = nil

    init?(snapshot: UsageSnapshot) {
        guard snapshot.totals.costIsIncomplete == true else { return nil }
        day = snapshot.day
        capturedAt = snapshot.generatedAt
        models = Array(Set(snapshot.sessions.filter { $0.usage.costIsIncomplete == true }
            .flatMap { session in
                let parts = session.modelBreakdowns.filter { $0.usage.costIsIncomplete == true }
                return parts.isEmpty ? session.models : parts.map(\.id)
            })).filter { !$0.isEmpty }.sorted()
        reasons = snapshot.costReasons
    }
}

/// An atomic presentation envelope: the extension never pairs new diagnostics
/// with an older report from a separately replaced file. Old cache files remain
/// available for previous app versions and for recovery.
struct UsagePresentation: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var revision = UUID()
    var snapshot: UsageSnapshot?
    var previous: UsageSnapshot?
    var history: UsageHistory?
    var failures: [UsageRefreshFailure] = []
    var storageError: UsageError? = nil
    var costIssues: [UsageCostIssue] = []
    var lastAttempt: Date? = nil
}

struct UsageProblem: Codable, Equatable, Identifiable, Sendable {
    var reference: UsageProblemReference
    var lastSuccess: Date? = nil
    var attemptedAt: Date? = nil
    var error: UsageError? = nil
    var legacyMessage: String? = nil
    var models: [String] = []
    var missingDays: [UsageDay] = []
    var costReasons: [UsageCostReason]? = nil
    var id: String { reference.id }
    var title: String { localizedTitle(language: nil) }
    func localizedTitle(language: InterfaceLanguage?) -> String {
        reference.kind == .refresh ? error?.localizedDescription(language: language) ?? reference.kind.localizedTitle(language: language) : reference.kind.localizedTitle(language: language)
    }
    var scope: String { reference.day.map { UsageFormat.date($0.date, timezone: $0.timezone) + " · " + $0.timezone } ?? L10n.text("Общие данные") }
    var explanation: String {
        switch reference.kind {
        case .storage: return L10n.text("Приложению или виджету не удалось прочитать или сохранить общие данные. Виджет может показывать предыдущий результат.")
        case .refresh: return error?.recovery ?? L10n.text("Последняя попытка обновления завершилась ошибкой. Повторите обновление; сохранённые данные останутся доступны.")
        case .context: return L10n.text("Сохранённые данные рассчитаны с другими настройками или версией компонента. Обновите статистику для пересчёта.")
        case .stale: return L10n.text("Новых данных не было дольше ожидаемого интервала или начался новый день. Показан последний сохранённый результат. Если отдельной ошибки нет, причина задержки неизвестна.")
        case .cost: return L10n.text("Для части данных стоимость определить не удалось. Итог включает только известную стоимость. Обновление поможет, если недостающие данные или тарифы стали доступны.")
        case .history: return L10n.text("Не все дни за последнюю неделю загружены. Прочерки на графике не означают нулевые расходы. Повторите загрузку истории.")
        }
    }
    var details: String? { error?.details ?? legacyMessage }
    var isInformational: Bool { reference.kind == .cost || reference.kind == .history }

    // Stable across retries, price changes and publication timestamps. A new
    // cause/model is new information; the same limitation stays acknowledged.
    var dismissalFingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var stable = self
        stable.lastSuccess = nil; stable.attemptedAt = nil
        stable.models = models.sorted()
        stable.costReasons = costReasons?.sorted { $0.rawValue < $1.rawValue }
        return (try? encoder.encode(stable).base64EncodedString()) ?? id
    }
}

/// The only policy for app, menu and every widget variant. Callers supply time,
/// so the same persisted state also works while the application is closed.
enum UsageHealth {
    static func staleDate(generatedAt: Date, interval: TimeInterval) -> Date {
        generatedAt.addingTimeInterval(max(interval * 2, 600) + 1)
    }

    static func transitionDates(snapshot: UsageSnapshot?, history: UsageHistory?, status: RefreshStatus?, now: Date) -> [Date] {
        let zone = status?.dataContext?.timezone ?? snapshot?.day.timezone ?? history?.context.timezone ?? "UTC"
        let today = UsageDay(date: now, timezone: zone)
        let capturedAt = snapshot?.generatedAt ?? history?.days.first(where: { $0.day == today })?.capturedAt
        return Array(Set([today.end] + (capturedAt.map { [staleDate(generatedAt: $0, interval: status?.refreshInterval ?? 180)] } ?? [])))
            .filter { $0 > now }.sorted()
    }

    static func problems(snapshot: UsageSnapshot?, history: UsageHistory? = nil, status: RefreshStatus? = nil,
                         storageUnavailable: Bool = false, now: Date, scope: UsageProblemScope = .all,
                         includeHidden: Bool = true) -> [UsageProblem] {
        let presentation = status?.presentation
        let context = status?.dataContext
        let zone = context?.timezone ?? snapshot?.day.timezone ?? history?.context.timezone ?? "UTC"
        let today = UsageDay(date: now, timezone: zone)
        let scopedDay: UsageDay?
        switch scope { case .all: scopedDay = nil; case .currentDay: scopedDay = today; case .day(let day): scopedDay = day }
        var result: [UsageProblem] = []
        if storageUnavailable || presentation?.storageError != nil {
            result.append(.init(reference: .init(kind: .storage), error: presentation?.storageError))
        }
        var failures = presentation?.failures ?? []
        if presentation == nil, let message = status?.message {
            failures.append(.init(day: UsageDay(date: status!.attemptedAt, timezone: zone),
                                  attemptedAt: status!.attemptedAt, error: nil, legacyMessage: message))
        }
        for failure in failures {
            let success = snapshot?.day == failure.day ? snapshot?.generatedAt
                : history?.days.first(where: { $0.day == failure.day })?.capturedAt
            result.append(.init(reference: .init(kind: .refresh, day: failure.day), lastSuccess: success,
                                attemptedAt: failure.attemptedAt, error: failure.error, legacyMessage: failure.legacyMessage))
        }
        if let snapshot, let context, snapshot.dataContext != context {
            result.append(.init(reference: .init(kind: .context, day: snapshot.day), lastSuccess: snapshot.generatedAt))
        }
        let capturedAt = snapshot?.generatedAt ?? history?.days.first(where: { $0.day == today })?.capturedAt
        if scopedDay == nil || scopedDay == today, let capturedAt,
           now >= staleDate(generatedAt: capturedAt, interval: status?.refreshInterval ?? 180)
            || snapshot.map({ $0.day != today }) == true {
            result.append(.init(reference: .init(kind: .stale, day: snapshot?.day ?? today), lastSuccess: capturedAt,
                                attemptedAt: presentation == nil ? status?.attemptedAt : presentation?.lastAttempt))
        }
        // A current report supersedes a restored diagnostic, including a repair.
        var costs = presentation?.costIssues.filter { $0.day != snapshot?.day } ?? []
        if let snapshot, let cost = UsageCostIssue(snapshot: snapshot) { costs.insert(cost, at: 0) }
        for cost in costs {
            result.append(.init(reference: .init(kind: .cost, day: cost.day), lastSuccess: cost.capturedAt,
                                attemptedAt: cost.capturedAt, models: cost.models, costReasons: cost.reasons))
        }
        if let history {
            for total in history.days where total.usage.costIsIncomplete == true && total.day != snapshot?.day {
                result.append(.init(reference: .init(kind: .cost, day: total.day), lastSuccess: total.capturedAt,
                                    attemptedAt: total.capturedAt,
                                    models: total.usageComponents?.filter { $0.reportedUsage.costIsIncomplete == true }.flatMap(\.models) ?? [],
                                    costReasons: total.costReasons))
            }
            let missing = history.points(ending: today).filter { $0.day != today && $0.total == nil }.map(\.day)
            if !missing.isEmpty { result.append(.init(reference: .init(kind: .history), missingDays: missing)) }
        }
        var seen: Set<String> = []
        return result.filter { problem in
            if let scopedDay {
                switch problem.reference.kind {
                case .history: return false
                case .storage: break
                case .stale, .context:
                    guard problem.reference.day == scopedDay || scopedDay == today && problem.reference.day == snapshot?.day else { return false }
                default: guard problem.reference.day == scopedDay else { return false }
                }
            }
            return (includeHidden || status?.hiddenProblems?[problem.id] != problem.dismissalFingerprint)
                && seen.insert(problem.id).inserted
        }.sorted {
            let left = UsageProblemKind.allCases.firstIndex(of: $0.reference.kind)!
            let right = UsageProblemKind.allCases.firstIndex(of: $1.reference.kind)!
            return left == right ? $0.id > $1.id : left < right
        }
    }

    static func summary(_ problems: [UsageProblem], language: InterfaceLanguage? = nil) -> String {
        guard let first = problems.first else { return L10n.text("Проблем не обнаружено", language: language) }
        let title = first.localizedTitle(language: language)
        return problems.count == 1 ? title : L10n.text("\(title) · ещё \(problems.count - 1)", language: language)
    }
}
