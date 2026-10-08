import SwiftUI
import WidgetKit

struct UsageBudgetMeter: View {
    @Environment(\.usageLanguage) private var interfaceLanguage
    private var strings: UsageLocalizer { .init(language: interfaceLanguage) }
    var budget: DailyBudget
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            HStack(spacing: 5) {
                Text(strings.text("Бюджет \(strings.cost(budget.limit))"))
                if !compact { Spacer(minLength: 3) }
                if budget.isOver {
                    if compact {
                        Text("+\(strings.cost(budget.difference))").foregroundStyle(.orange)
                    } else { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                }
            }.font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            UsageBar(fraction: budget.fraction, color: budget.isOver ? .orange : .green, height: compact ? 3 : 4)
            if !compact {
                Text(budget.localizedCaption(language: interfaceLanguage)).font(.system(size: 10)).foregroundStyle(budget.isOver ? Color.orange : .secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(strings.text("Дневной бюджет \(strings.cost(budget.limit)). Учтено \(strings.cost(budget.usage)). \(budget.localizedCaption(language: interfaceLanguage))"))
    }
}

/// Missing days use a dash; confirmed zero uses a hollow marker. Bar height never invents usage.
struct DailyCostChart: View {
    @Environment(\.usageLanguage) private var interfaceLanguage
    private var strings: UsageLocalizer { .init(language: interfaceLanguage) }
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
                Text(point.total.map { strings.cost($0.usage) } ?? "—")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.55)
            }
            ZStack(alignment: .bottom) {
                if let total = point.total {
                    if total.usage.cost > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(point.day == today ? UsageStyle.orange : Color.primary.opacity(0.3))
                            .widgetAccentable(point.day == today)
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
        let date = strings.date(point.day.date, timezone: point.day.timezone)
        guard let total = point.total else { return strings.text("\(date): нет данных") }
        return "\(date): \(strings.cost(total.usage))\(total.isPartialDay ? strings.text(", неполный день") : "")\(total.usage.costIsIncomplete == true ? strings.text(", стоимость неполная") : "")"
    }
}

struct HistoryCoverageCaption: View {
    @Environment(\.usageLanguage) private var interfaceLanguage
    private var strings: UsageLocalizer { .init(language: interfaceLanguage) }
    var points: [UsageHistoryPoint]
    var compact = false
    private var missing: Int { points.filter { $0.total == nil }.count }
    var body: some View {
        Text(strings.text("Дней с данными: \(points.count - missing) из \(points.count)"))
            .font(.system(size: compact ? 9 : 10)).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.75)
    }
}
