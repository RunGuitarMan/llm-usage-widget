import SwiftUI
import WidgetKit

enum UsageWidgetVariant: String, CaseIterable, Identifiable {
    case summary, sessions, trend
    var id: String { rawValue }
    var title: String {
        switch self { case .summary: return L10n.text("Сводка"); case .sessions: return L10n.text("Сессии"); case .trend: return L10n.text("Динамика") }
    }
}

struct UsageSessionsWidget: View {
    @Environment(\.usageLanguage) private var interfaceLanguage
    private var strings: UsageLocalizer { .init(language: interfaceLanguage) }
    var family: WidgetFamily
    var snapshot: WidgetSnapshot
    var date: Date
    var status: RefreshStatus?
    var problems: [UsageProblem]
    private var small: Bool { family == .systemSmall }
    private var large: Bool { family == .systemLarge }
    private var rows: [UsageSession] { Array(SessionSort.cost.sorted(snapshot.sessions).prefix(large ? 4 : small ? 2 : 3)) }
    private var maximum: Double { max(rows.first?.usage.cost ?? 0, 0.01) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(strings.text("Сессии")).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 2)
                UsageDayCaption(day: snapshot.day, now: date)
            }
            if family == .systemMedium {
                HStack(alignment: .top, spacing: 22) {
                    amount.frame(maxWidth: .infinity, alignment: .leading)
                    ranking.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 12)
            } else {
                if large { amount.padding(.top, 6).padding(.bottom, 12) }
                ranking.padding(.top, small ? 12 : 0)
            }
            Spacer(minLength: 7)
            HStack(spacing: 4) {
                if problems.isEmpty || small {
                    Text(small ? strings.text("По стоимости") : strings.text("Сессии: \(snapshot.sessionCount) · по стоимости"))
                }
                Spacer(minLength: 2)
                if !problems.isEmpty {
                    UsageProblemLink(problems: problems, compact: small)
                } else { Text(strings.time(snapshot.generatedAt)) }
            }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
    private var amount: some View {
        VStack(alignment: .leading, spacing: 3) {
            UsageAmount(usage: snapshot.totals, size: large ? 46 : 32)
            if !large {
                Text("\(strings.tokens(snapshot.totals.total)) Tokens")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    private var ranking: some View {
        VStack(alignment: .leading, spacing: large ? 9 : 10) {
            if rows.isEmpty {
                Text(strings.text("Пока нет сессий")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
            ForEach(rows) { session in
                Link(destination: UsageRoute.datedSession(session.id, snapshot.day).url) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Text(large ? (session.models.first ?? UsageSource.label(session.sourceID, language: interfaceLanguage)) : session.shortID)
                                .font(.system(size: large ? 12 : 10, weight: .medium))
                                .truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                            Text(strings.cost(session.usage)).font(.system(size: large ? 12 : 10, weight: .medium))
                                .fixedSize(horizontal: true, vertical: true)
                        }.lineLimit(1)
                        if large {
                            Text("\(UsageSource.label(session.sourceID, language: interfaceLanguage)) · \(session.shortID)")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        UsageBar(fraction: session.usage.cost / maximum, color: UsageSource.color(session.sourceID), height: 3)
                    }.foregroundStyle(.primary)
                }.buttonStyle(.plain)
                    .accessibilityLabel(strings.text("\(UsageSource.label(session.sourceID, language: interfaceLanguage)), \((session.models.isEmpty ? strings.text("Модель неизвестна") : session.models.joined(separator: ", "))), сессия \(session.shortID), \(strings.cost(session.usage)). Открыть сессию"))
            }
        }
    }
}

struct UsageTrendWidget: View {
    @Environment(\.usageLanguage) private var interfaceLanguage
    private var strings: UsageLocalizer { .init(language: interfaceLanguage) }
    var family: WidgetFamily
    var snapshot: WidgetSnapshot?
    var history: UsageHistory?
    var status: RefreshStatus?
    var date: Date
    var problems: [UsageProblem]
    private var today: UsageDay { .init(date: date, timezone: status?.dataContext?.timezone ?? history?.context.timezone ?? snapshot?.day.timezone ?? "UTC") }
    private var points: [UsageHistoryPoint] {
        let data = history ?? UsageHistory(context: status?.dataContext ?? .init(timezone: today.timezone, customPath: ""))
        // The app publishes today's aggregate with the history projection.
        return data.points(ending: today)
    }
    private var large: Bool { family == .systemLarge }
    private var budget: DailyBudget? {
        guard let snapshot, snapshot.day == today else { return nil }
        return DailyBudget(limit: status?.dailyBudget, usage: snapshot.totals)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if family == .systemMedium {
                HStack(alignment: .top, spacing: 22) {
                    heading.frame(maxWidth: .infinity, alignment: .leading)
                    DailyCostChart(points: points, today: today).frame(maxWidth: .infinity).frame(height: 99)
                }
            } else {
                heading
                DailyCostChart(points: points, today: today, showValues: large)
                    .frame(height: large ? (budget == nil ? 108 : 90) : 48).padding(.top, large ? (budget == nil ? 22 : 16) : 8)
            }
            if large {
                HStack {
                    Text(strings.text("За 7 дней")).foregroundStyle(.secondary)
                    Spacer()
                    Text(strings.cost(points.knownUsage))
                }.font(.system(size: 11)).padding(.top, budget == nil ? 18 : 12)
                if let budget { UsageBudgetMeter(budget: budget).padding(.top, 12) }
            }
            Spacer(minLength: large ? 8 : 5)
            HStack(spacing: 4) {
                HistoryCoverageCaption(points: points, compact: !large)
                if !problems.isEmpty {
                    UsageProblemLink(problems: problems, compact: !large).font(.system(size: 9))
                }
                if large { Spacer(); Text(today.timezone).font(.system(size: 9)).foregroundStyle(.tertiary) }
            }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageDayCaption(day: today, now: date)
            if let current = points.last?.total {
                UsageAmount(usage: current.usage, size: large ? 46 : family == .systemSmall ? 28 : 34)
                    .padding(.top, large ? 6 : 3)
                if family != .systemSmall {
                    comparison(current).padding(.top, 3)
                }
            } else {
                Text("—").font(.system(size: large ? 46 : 34, weight: .semibold)).padding(.top, 3)
                if family != .systemSmall {
                    Text(strings.text("Нет данных за сегодня")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
    @ViewBuilder private func comparison(_ current: DailyUsageTotal) -> some View {
        if let previous = points.dropLast().last?.total,
           !previous.isPartialDay, previous.usage.costIsIncomplete != true, current.usage.costIsIncomplete != true {
            let change = current.usage.cost - previous.usage.cost
            Text(strings.text("\(strings.cost(abs(change))) \(change >= 0 ? strings.text("больше") : strings.text("меньше")), чем вчера"))
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(large ? 1 : 2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(strings.text("Расходы за 7 дней")).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
