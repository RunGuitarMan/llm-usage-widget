import Foundation

/// Source and timezone travel with each file so independently replaced files cannot mix configurations.
struct UsageDataContext: Codable, Equatable, Sendable {
    var timezone: String
    var customPath: String
}

struct DailyUsageTotal: Codable, Equatable, Identifiable, Sendable {
    var day: UsageDay
    var usage: TokenUsage
    var sessionCount: Int
    var capturedAt: Date
    var id: String { day.cacheKey }
    // A snapshot collected before midnight is never promoted to a complete day at rollover.
    var isPartialDay: Bool { capturedAt < day.end }

    init(snapshot: UsageSnapshot) {
        day = snapshot.day
        usage = snapshot.totals
        sessionCount = snapshot.sessions.count
        capturedAt = snapshot.generatedAt
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

    mutating func record(_ snapshot: UsageSnapshot, today: UsageDay) {
        guard snapshot.day.timezone == context.timezone, snapshot.dataContext == context,
              snapshot.day.date >= today.adding(days: -6).date, snapshot.day.date <= today.date else { return }
        let new = DailyUsageTotal(snapshot: snapshot)
        if let old = days.first(where: { $0.day == new.day }), old.capturedAt > new.capturedAt { return }
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
                || now.timeIntervalSince(point.total!.capturedAt) >= Self.completedDayRefreshInterval)
        }.map(\.day)
    }
}

enum MenuContentMode: String, CaseIterable, Identifiable {
    case summary, trend
    var id: String { rawValue }
    var title: String { self == .summary ? L10n.text("Сводка токенов") : L10n.text("Динамика за 7 дней") }
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
        if isOver { return L10n.text("Превышение \(partial ? "≥ " : "")\(UsageFormat.cost(difference))") }
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
