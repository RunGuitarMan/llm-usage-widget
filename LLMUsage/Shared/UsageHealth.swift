import Foundation

enum UsageProblemKind: String, Codable, CaseIterable, Sendable {
    case storage, refresh, context, stale, cost, history

    var title: String {
        switch self {
        case .storage: return L10n.text("Данные виджета недоступны")
        case .refresh: return L10n.text("Не удалось обновить данные")
        case .context: return L10n.text("Данные требуют пересчёта")
        case .stale: return L10n.text("Данные устарели")
        case .cost: return L10n.text("Стоимость неполная")
        case .history: return L10n.text("История неполная")
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

    init?(snapshot: UsageSnapshot) {
        guard snapshot.totals.costIsIncomplete == true else { return nil }
        day = snapshot.day
        capturedAt = snapshot.generatedAt
        models = Array(Set(snapshot.sessions.filter { $0.usage.costIsIncomplete == true }
            .flatMap { session in
                let parts = session.modelBreakdowns.filter { $0.usage.costIsIncomplete == true }
                return parts.isEmpty ? session.models : parts.map(\.id)
            })).filter { !$0.isEmpty }.sorted()
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

struct UsageProblem: Equatable, Identifiable, Sendable {
    var reference: UsageProblemReference
    var lastSuccess: Date? = nil
    var attemptedAt: Date? = nil
    var error: UsageError? = nil
    var legacyMessage: String? = nil
    var models: [String] = []
    var missingDays: [UsageDay] = []
    var id: String { reference.id }
    var title: String { reference.kind == .refresh ? error?.errorDescription ?? reference.kind.title : reference.kind.title }
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
        return ([today.end] + (capturedAt.map { [staleDate(generatedAt: $0, interval: status?.refreshInterval ?? 180)] } ?? []))
            .filter { $0 > now }.sorted()
    }

    static func problems(snapshot: UsageSnapshot?, history: UsageHistory? = nil, status: RefreshStatus? = nil,
                         storageUnavailable: Bool = false, now: Date) -> [UsageProblem] {
        let presentation = status?.presentation
        let context = status?.dataContext
        let zone = context?.timezone ?? snapshot?.day.timezone ?? history?.context.timezone ?? "UTC"
        let today = UsageDay(date: now, timezone: zone)
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
        if let capturedAt,
           now >= staleDate(generatedAt: capturedAt, interval: status?.refreshInterval ?? 180)
            || snapshot.map({ $0.day != today }) == true {
            result.append(.init(reference: .init(kind: .stale, day: snapshot?.day ?? today), lastSuccess: capturedAt,
                                attemptedAt: presentation == nil ? status?.attemptedAt : presentation?.lastAttempt))
        }
        var costs = presentation?.costIssues ?? []
        if let snapshot, let cost = UsageCostIssue(snapshot: snapshot) { costs.append(cost) }
        for cost in costs {
            result.append(.init(reference: .init(kind: .cost, day: cost.day), lastSuccess: cost.capturedAt, models: cost.models))
        }
        if let history {
            for total in history.days where total.usage.costIsIncomplete == true {
                result.append(.init(reference: .init(kind: .cost, day: total.day), lastSuccess: total.capturedAt,
                                    models: total.usageComponents?.filter { $0.reportedUsage.costIsIncomplete == true }.flatMap(\.models) ?? []))
            }
            let missing = history.points(ending: today).filter { $0.day != today && $0.total == nil }.map(\.day)
            if !missing.isEmpty { result.append(.init(reference: .init(kind: .history), missingDays: missing)) }
        }
        var seen: Set<String> = []
        return result.filter { seen.insert($0.id).inserted }.sorted {
            let left = UsageProblemKind.allCases.firstIndex(of: $0.reference.kind)!
            let right = UsageProblemKind.allCases.firstIndex(of: $1.reference.kind)!
            return left == right ? $0.id > $1.id : left < right
        }
    }

    static func summary(_ problems: [UsageProblem]) -> String {
        guard let first = problems.first else { return L10n.text("Проблем не обнаружено") }
        return problems.count == 1 ? first.title : L10n.text("\(first.title) · ещё \(problems.count - 1)")
    }
}
