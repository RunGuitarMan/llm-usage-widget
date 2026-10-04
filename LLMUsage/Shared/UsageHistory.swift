import Foundation

enum UsageUpdateMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeOnly, allAgents
    var id: String { rawValue }
    var title: String { self == .claudeOnly ? L10n.text("Только Claude") : L10n.text("Все агенты") }
}

/// Source and timezone travel with each file so independently replaced files cannot mix configurations.
struct UsageDataContext: Codable, Equatable, Sendable {
    var timezone: String
    var customPath: String
    // Missing in old caches, whose unified Claude totals may be incorrect.
    // Synthesized decoding keeps that absence as nil, distinct from either new mode.
    var updateMode: UsageUpdateMode? = .claudeOnly
}

struct DailyUsageTotal: Codable, Equatable, Identifiable, Sendable {
    var day: UsageDay
    var usage: TokenUsage
    var sessionCount: Int
    var capturedAt: Date
    var usageComponents: [ModelUsageComponent]? = nil
    var reportedUsage: TokenUsage? = nil
    var id: String { day.cacheKey }
    // A snapshot collected before midnight is never promoted to a complete day at rollover.
    var isPartialDay: Bool { capturedAt < day.end }

    init(snapshot: UsageSnapshot) {
        day = snapshot.day
        usage = snapshot.totals
        sessionCount = snapshot.sessions.count
        capturedAt = snapshot.generatedAt
        reportedUsage = snapshot.sessions.reduce(.zero) { $0 + $1.usage.reported }
        // Keep model allocations, not session IDs, paths or transcripts, in history.
        var grouped: [[String]: TokenUsage] = [:]
        for component in snapshot.sessions.flatMap(\.usageComponents) {
            let models = Array(Set(component.models.map(ModelExclusionPolicy.key))).sorted()
            grouped[models, default: .zero] = grouped[models, default: .zero] + component.reportedUsage
        }
        usageComponents = grouped.keys.sorted { $0.lexicographicallyPrecedes($1) }
            .map { .init(models: $0, usage: grouped[$0]!) }
    }

    func applyingExclusions(_ policy: ModelExclusionPolicy) -> Self? {
        // Old totals have no model attribution. Rebuild them instead of displaying
        // potentially excluded costs as if they had already been recalculated.
        guard let usageComponents else { return nil }
        var result = self
        let total = usageComponents.reduce(TokenUsage.zero) { $0 + $1.usage(applying: policy) }
        let hasExclusions = usageComponents.contains { $0.models.contains { !policy.includes($0) } }
        result.usage = hasExclusions ? total : (reportedUsage ?? total)
        return result
    }
}

struct UsageHistoryPoint: Identifiable, Equatable, Sendable {
    var day: UsageDay
    var total: DailyUsageTotal?
    var id: String { day.cacheKey }
}

struct UsageHistory: Codable, Equatable, Sendable {
    static let completedDayRefreshInterval: TimeInterval = 6 * 3600
    var schemaVersion = 1
    var context: UsageDataContext
    var days: [DailyUsageTotal] = []

    func applyingExclusions(_ policy: ModelExclusionPolicy) -> Self {
        var result = self
        result.days = days.compactMap { $0.applyingExclusions(policy) }
        return result
    }

    mutating func record(_ snapshot: UsageSnapshot, today: UsageDay, now: Date = Date()) {
        guard snapshot.day.timezone == context.timezone, snapshot.dataContext == context,
              snapshot.day.date >= today.adding(days: -6).date, snapshot.day.date <= today.date else { return }
        let new = DailyUsageTotal(snapshot: snapshot)
        if let old = days.first(where: { $0.day == new.day }), old.capturedAt <= now,
           old.capturedAt > new.capturedAt { return }
        days.removeAll { $0.day == new.day || $0.day.date < today.adding(days: -6).date || $0.day.date > today.date }
        days.append(new)
        days.sort { $0.day.date < $1.day.date }
    }

    func points(ending today: UsageDay) -> [UsageHistoryPoint] {
        (-6...0).map { offset in
            let day = today.adding(days: offset)
            return UsageHistoryPoint(day: day, total: days.first { $0.day == day })
        }
    }

    func missingCompletedDays(ending today: UsageDay, now: Date = Date()) -> [UsageDay] {
        points(ending: today).reversed().filter { point in
            point.day != today && (point.total == nil || point.total?.isPartialDay == true
                || point.total!.capturedAt > now
                || now.timeIntervalSince(point.total!.capturedAt) >= Self.completedDayRefreshInterval)
        }.map(\.day)
    }
}

enum MenuContentMode: String, CaseIterable, Identifiable {
    case summary, trend
    var id: String { rawValue }
    var title: String { self == .summary ? L10n.text("Сводка токенов") : L10n.text("Динамика за 7 дней") }
}

/// Calendar arithmetic stays in the report's time zone, including DST boundaries.
struct UsageCalendarMonth {
    let calendar: Calendar
    let start: Date

    init(containing date: Date, timezone: String, locale: Locale) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone(identifier: timezone) ?? .gmt
        self.calendar = calendar
        start = calendar.dateInterval(of: .month, for: date)!.start
    }

    var days: [Date] {
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return (0..<42).map { calendar.date(byAdding: .day, value: $0 - offset, to: start)! }
    }

    var weekdays: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    func moving(_ months: Int) -> Date { calendar.date(byAdding: .month, value: months, to: start)! }
    func contains(_ date: Date) -> Bool { calendar.isDate(date, equalTo: start, toGranularity: .month) }
    func isSelectable(_ date: Date, now: Date = Date()) -> Bool {
        calendar.startOfDay(for: date) <= calendar.startOfDay(for: now)
    }
}

struct DailyBudget: Equatable {
    var limit: Double
    var usage: TokenUsage
    static func validAmount(_ amount: Double?) -> Double? {
        guard let amount, amount.isFinite, amount > 0 else { return nil }
        return amount
    }
    init?(limit: Double?, usage: TokenUsage) {
        guard let limit = Self.validAmount(limit) else { return nil }
        self.limit = limit
        self.usage = usage
    }
    var fraction: Double { min(max(usage.cost / limit, 0), 1) }
    var isOver: Bool { usage.cost > limit }
    var difference: Double { abs(limit - usage.cost) }
    var caption: String {
        let partial = usage.costIsIncomplete == true
        if isOver { return L10n.text("Превышение \(UsageFormat.cost(difference))") }
        if partial { return L10n.text("Учтена часть стоимости") }
        return L10n.text("Осталось \(UsageFormat.cost(difference))")
    }
}

extension Array where Element == UsageHistoryPoint {
    /// The weekly sum is a lower bound if a day or a price is unavailable.
    var knownUsage: TokenUsage {
        var total = compactMap(\.total).reduce(TokenUsage.zero) { $0 + $1.usage }
        if contains(where: { $0.total == nil || ($0.total?.isPartialDay == true && $0.day != last?.day) }) {
            total.costIsIncomplete = true
        }
        return total
    }
}
