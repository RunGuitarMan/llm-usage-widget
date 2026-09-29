import Foundation

enum UsageFormat {
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func tokens(_ value: Int64) -> String {
        let number = Double(value)
        if value >= 999_950 { return trimmed(number / 1_000_000, digits: 2) + "M" }
        if value >= 1_000 { return trimmed(number / 1_000, digits: 1) + "K" }
        return String(value)
    }
    private static func trimmed(_ value: Double, digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }
    static func decimal(_ value: Double) -> String { trimmed(value, digits: 6) }
    static func exact(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        // Grouping follows the selected interface locale.
        formatter.groupingSize = 3
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
    static func cost(_ value: Double) -> String {
        String(format: "$%.2f", locale: L10n.locale, value == 0 ? 0 : value)
    }
    static func cost(_ usage: TokenUsage) -> String {
        cost(usage.cost)
    }
    /// At most six characters; the menu keeps the full cents-precision amount.
    static func menuBarCost(_ usage: TokenUsage?) -> String {
        guard let usage else { return "···" }
        guard usage.cost.isFinite, usage.cost >= 0 else { return "—" }
        let prefix = "$"
        if usage.cost < 99.995 { return prefix + String(format: "%.2f", locale: L10n.locale, usage.cost) }
        if usage.cost < 999.95 { return prefix + trimmed(usage.cost, digits: 1) }
        for (unit, divisor): (String, Double) in [("K", 1_000), ("M", 1_000_000), ("B", 1_000_000_000)] {
            if usage.cost < divisor * 999.95 {
                let value = usage.cost / divisor
                return prefix + trimmed(value, digits: value < 99.95 ? 1 : 0) + unit
            }
        }
        return prefix + "1T+"
    }
    static func percent(_ fraction: Double) -> String {
        if fraction > 0 && fraction < 0.0001 { return "<" + trimmed(0.01, digits: 2) + "%" }
        return String(format: "%.2f%%", locale: L10n.locale, fraction * 100)
    }
    static func menuBarPercent(count: Int64, total: Int64) -> String {
        guard total > 0, count > 0 else { return "0%" }
        let percent = Double(count) / Double(total) * 100
        return percent < 0.1 ? "<" + trimmed(0.1, digits: 1) + "%" : String(format: "%.1f%%", locale: L10n.locale, percent)
    }
    static func shortID(_ id: String) -> String { String(id.prefix(8)) }
    static func dayKey(_ date: Date, timezone: String = "UTC") -> String {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
    static func date(_ date: Date, timezone: String = TimeZone.current.identifier, includeTime: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = TimeZone(identifier: timezone)
        formatter.dateStyle = .medium
        formatter.timeStyle = includeTime ? .short : .none
        return formatter.string(from: date)
    }
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    static func activity(_ session: UsageSession, timezone: String) -> String {
        guard let date = session.lastActivity else { return L10n.text("Время не указано") }
        return self.date(date, timezone: timezone, includeTime: session.activityHasTime)
    }
}
