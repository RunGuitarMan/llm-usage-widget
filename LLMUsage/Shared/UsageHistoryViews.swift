import SwiftUI

struct UsageBudgetMeter: View {
    var budget: DailyBudget
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            HStack(spacing: 5) {
                Text(L10n.text("Бюджет \(UsageFormat.cost(budget.limit))"))
                if !compact { Spacer(minLength: 3) }
                if budget.isOver {
                    if compact {
                        Text("+\(UsageFormat.cost(budget.difference))").foregroundStyle(.orange)
                    } else { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                }
            }.font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            UsageBar(fraction: budget.fraction, color: budget.isOver ? .orange : .green, height: compact ? 3 : 4)
            if !compact {
                Text(budget.caption).font(.system(size: 10)).foregroundStyle(budget.isOver ? Color.orange : .secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Дневной бюджет \(UsageFormat.cost(budget.limit)). Учтено \(UsageFormat.cost(budget.usage)). \(budget.caption)"))
    }
}

/// Missing days use a dash; confirmed zero uses a hollow marker. Bar height never invents usage.
struct DailyCostChart: View {
    var points: [UsageHistoryPoint]
    var today: UsageDay
    var showValues = false
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: showValues ? 10 : 7) {
                ForEach(points) { point in
                    column(point, height: max(10, geometry.size.height - (showValues ? 38 : 21)))
                        .frame(maxWidth: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
    private var maximum: Double { max(points.compactMap { $0.total?.usage.cost }.max() ?? 0, 0.01) }
    private func column(_ point: UsageHistoryPoint, height: CGFloat) -> some View {
        VStack(spacing: 6) {
            if showValues {
                Text(point.total.map { UsageFormat.cost($0.usage) } ?? "—")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.55)
            }
            ZStack(alignment: .bottom) {
                if let total = point.total {
                    if total.usage.cost > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(point.day == today ? UsageStyle.orange : Color.primary.opacity(0.18))
                            .frame(height: max(2, height * CGFloat(total.usage.cost / maximum)))
                            .overlay(alignment: .top) {
                                if total.usage.costIsIncomplete == true || total.isPartialDay {
                                    Capsule().fill(Color.primary.opacity(0.4)).frame(height: 2).padding(.horizontal, 2)
                                }
                            }
                    } else if total.usage.costIsIncomplete == true {
                        Text("?").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Circle().stroke(Color.secondary.opacity(0.7), lineWidth: 1).frame(width: 5, height: 5)
                    }
                } else {
                    Text("—").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }.frame(height: height, alignment: .bottom)
            Text(dayNumber(point.day)).font(.system(size: 9, weight: point.day == today ? .semibold : .regular))
                .foregroundStyle(point.day == today ? Color.primary : .secondary)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(point))
            .help(accessibilityText(point))
    }
    private func dayNumber(_ day: UsageDay) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: day.timezone)!
        return String(calendar.component(.day, from: day.date))
    }
    private func accessibilityText(_ point: UsageHistoryPoint) -> String {
        let date = UsageFormat.date(point.day.date, timezone: point.day.timezone)
        guard let total = point.total else { return L10n.text("\(date): нет данных") }
        return "\(date): \(UsageFormat.cost(total.usage))\(total.isPartialDay ? L10n.text(", неполный день") : "")\(total.usage.costIsIncomplete == true ? L10n.text(", стоимость неполная") : "")"
    }
}

struct HistoryCoverageCaption: View {
    var points: [UsageHistoryPoint]
    var compact = false
    private var missing: Int { points.filter { $0.total == nil }.count }
    private var incomplete: Bool { points.contains { $0.total?.usage.costIsIncomplete == true } }
    var body: some View {
        Text(missing > 0 ? L10n.text("Дней без данных: \(missing) · —") : incomplete ? L10n.text("Стоимость неполная") : L10n.text("Сегодня — неполный день"))
            .font(.system(size: compact ? 9 : 10)).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.75)
    }
}
