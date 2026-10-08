import SwiftUI
import WidgetKit

struct UsageWidgetContent: View {
    var family: WidgetFamily
    var variant: UsageWidgetVariant = .summary
    var history: UsageHistory? = nil
    var snapshot: UsageSnapshot?
    var previous: UsageSnapshot? = nil
    var status: RefreshStatus? = nil
    var date = Date()
    var storageUnavailable = false

    var problems: [UsageProblem] {
        UsageHealth.problems(snapshot: snapshot, history: history, status: status,
                             storageUnavailable: storageUnavailable, now: date)
    }

    var destination: URL {
        if (family == .systemSmall || snapshot == nil), let first = problems.first { return UsageRoute.problem(first.reference).url }
        if snapshot == nil && history == nil { return UsageRoute.settings.url }
        return variant == .sessions ? snapshot.map { UsageRoute.datedSessions($0.day).url } ?? UsageRoute.sessions.url : UsageRoute.overview.url
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
            if variant == .trend, snapshot != nil || history != nil {
                UsageTrendWidget(family: family, snapshot: snapshot, history: history, status: status, date: date, problems: problems)
            } else if variant == .sessions, let snapshot {
                UsageSessionsWidget(family: family, snapshot: snapshot, date: date, status: status, problems: problems)
            } else if let snapshot {
                switch family {
                case .systemSmall: small(snapshot, tight: geometry.size.height < 135)
                case .systemMedium: medium(snapshot, tight: geometry.size.height < 135)
                default: large(snapshot, tight: geometry.size.height < 340)
                }
            } else { empty }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .widgetURL(destination)
    }

    private func small(_ snapshot: UsageSnapshot, tight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageDayCaption(day: snapshot.day, now: date)
            UsageAmount(usage: snapshot.totals, size: tight ? 40 : 44)
                .padding(.top, tight ? 3 : 6)
            Text("\(UsageFormat.tokens(snapshot.totals.total)) Tokens")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .padding(.top, 2)
            Spacer(minLength: 8)
            if let budget = budget(snapshot) { UsageBudgetMeter(budget: budget, compact: true) }
            else { TokenDistribution(usage: snapshot.totals, height: 4) }
            HStack {
                Text(L10n.text("Сессии: \(snapshot.sessions.count)"))
                Spacer(minLength: 0)
                if !problems.isEmpty {
                    UsageProblemLink(problems: problems, compact: true)
                } else {
                    Text(UsageFormat.time(snapshot.generatedAt)).monospacedDigit()
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 9)
        }
    }

    private func medium(_ snapshot: UsageSnapshot, tight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    UsageDayCaption(day: snapshot.day, now: date)
                    UsageAmount(usage: snapshot.totals, size: tight ? 40 : 44)
                        .padding(.top, tight ? 3 : 6)
                    Text("\(UsageFormat.tokens(snapshot.totals.total)) Tokens")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.top, 2)
                    Group {
                        if let budget = budget(snapshot) { UsageBudgetMeter(budget: budget, compact: true) }
                        else { TokenDistribution(usage: snapshot.totals, height: 4) }
                    }.padding(.top, tight ? 8 : 10)
                }.frame(maxWidth: .infinity, alignment: .leading)
                sessions(snapshot, limit: 2, compact: true, tight: tight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 8)
            footer(snapshot)
        }
    }

    private func large(_ snapshot: UsageSnapshot, tight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                UsageDayCaption(day: snapshot.day, now: date)
                Spacer(minLength: 8)
                Text(snapshot.day.timezone).font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            UsageAmount(usage: snapshot.totals, size: tight ? 46 : 52)
                .padding(.top, tight ? 3 : 6)
            Text(L10n.text("\(UsageFormat.tokens(snapshot.totals.total)) Tokens  ·  Сессии: \(snapshot.sessions.count)"))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                .padding(.top, 2)
            TokenDistribution(usage: snapshot.totals, height: 5)
                .padding(.top, tight ? 12 : 16)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], alignment: .leading, spacing: 7) {
                ForEach(snapshot.totals.categories) { category in
                    HStack(spacing: 5) {
                        Circle().fill(category.color).frame(width: 5, height: 5).accessibilityHidden(true)
                        Text(category.title).foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        Text(UsageFormat.tokens(snapshot.totals.value(for: category))).monospacedDigit()
                    }.font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.85)
                        .accessibilityElement(children: .combine)
                }
            }.padding(.top, 10)
            if let budget = budget(snapshot) { UsageBudgetMeter(budget: budget, compact: true).padding(.top, 12) }
            // Reserve the footer at the actual 344-point height, including Other tokens.
            sessions(snapshot, limit: !tight && budget(snapshot) == nil ? 3 : 2, compact: false, tight: tight)
                .padding(.top, tight ? 16 : 20)
            Spacer(minLength: 10)
            footer(snapshot)
        }
    }

    private func sessions(_ snapshot: UsageSnapshot, limit: Int, compact: Bool, tight: Bool) -> some View {
        let rows = Array(SessionSort.cost.sorted(snapshot.sessions).prefix(limit))
        return VStack(alignment: .leading, spacing: compact ? 10 : tight ? 9 : 12) {
            HStack {
                Text(L10n.text("Сессии")).font(.system(size: compact ? 11 : 12, weight: .medium))
                if !compact {
                    Spacer()
                    Text(L10n.text("По стоимости")).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }.lineLimit(1)
            if rows.isEmpty {
                Text(L10n.text("Пока нет сессий")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            } else {
                ForEach(rows) { session in
                    Link(destination: UsageRoute.datedSession(session.id, snapshot.day).url) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.models.first ?? L10n.text("Модель неизвестна"))
                                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                                    .truncationMode(.middle)
                                Text(compact ? session.sourceLabel : "\(session.sourceLabel) · \(session.shortID)")
                                    .font(.system(size: compact ? 9 : 10)).foregroundStyle(.secondary)
                            }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(UsageFormat.cost(session.usage))
                                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                                if !compact {
                                    Text("\(UsageFormat.tokens(session.usage.total)) Tokens")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }.lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: compact ? 70 : 110, alignment: .trailing)
                                .fixedSize(horizontal: !compact, vertical: true)
                        }.foregroundStyle(.primary).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("\(session.sourceLabel), \(session.modelLabel), сессия \(session.shortID), \(UsageFormat.cost(session.usage)), \(UsageFormat.exact(session.usage.total)) токенов. Открыть сессию"))
                }
            }
        }
    }

    private func budget(_ snapshot: UsageSnapshot) -> DailyBudget? {
        guard snapshot.day.isToday(now: date) else { return nil }
        return DailyBudget(limit: status?.dailyBudget, usage: snapshot.totals)
    }

    private func footer(_ snapshot: UsageSnapshot) -> some View {
        HStack(spacing: 4) {
            if !problems.isEmpty {
                UsageProblemLink(problems: problems)
            } else if family == .systemLarge, let previous,
                      previous.day == snapshot.day.adding(days: -1), previous.totals.costIsIncomplete != true {
                let change = snapshot.totals.cost - previous.totals.cost
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                Text(L10n.text("\(UsageFormat.cost(abs(change))) \(change >= 0 ? L10n.text("больше") : L10n.text("меньше")), чем вчера"))
            } else if family == .systemMedium {
                Text(L10n.text("Сессии: \(snapshot.sessions.count)"))
            } else { Text(L10n.text("Обновлено")) }
            Spacer(minLength: 4)
            Text(UsageFormat.time(snapshot.generatedAt)).monospacedDigit()
        }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LLM Usage").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: problems.isEmpty ? "chart.bar.xaxis" : "exclamationmark.triangle")
                .font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
            Text(problems.first?.title ?? (family == .systemSmall ? L10n.text("Откройте\nLLM Usage") : L10n.text("Откройте LLM Usage")))
                .font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(problems.isEmpty ? L10n.text("Настройте ccusage, чтобы видеть расходы здесь.") : L10n.text("Нажмите, чтобы узнать причину и что делать."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Content preview only. WidgetKit supplies the actual margins, shape and desktop appearance.
struct WidgetPreviewCard: View {
    var family: WidgetFamily
    var variant: UsageWidgetVariant = .summary
    var history: UsageHistory? = nil
    var snapshot: UsageSnapshot? = SampleData.multiSourceSnapshot()
    var previous: UsageSnapshot? = nil
    var status: RefreshStatus? = nil
    var date = Date()
    var storageUnavailable = false
    var size: CGSize? = nil
    var body: some View {
        UsageWidgetContent(family: family, variant: variant, history: history, snapshot: snapshot, previous: previous, status: status,
                           date: date, storageUnavailable: storageUnavailable)
            .padding(16)
            .frame(width: size?.width ?? (family == .systemSmall ? 164 : 344),
                   height: size?.height ?? (family == .systemLarge ? 344 : 164))
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 24))
    }
}

struct UsageWidgetPreviews: PreviewProvider {
    static var previews: some View {
        ForEach([WidgetFamily.systemSmall, .systemMedium, .systemLarge], id: \.self) { family in
            WidgetPreviewCard(family: family).preferredColorScheme(.light)
            WidgetPreviewCard(family: family).preferredColorScheme(.dark)
        }.padding(16).previewLayout(.sizeThatFits)
    }
}
