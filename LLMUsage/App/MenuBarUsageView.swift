import AppKit
import SwiftUI

struct MenuBarUsageView: View {
    @ObservedObject var store: UsageStore
    var openRoute: (UsageRoute) -> Void
    var close: () -> Void

    var body: some View {
        MenuBarUsageCard(snapshot: store.todaySnapshot, history: store.history, mode: store.menuContent,
                         dailyBudget: store.dailyBudget, timezone: store.timezone,
                         isRefreshing: store.isRefreshing, isDemo: store.isDemo,
                         error: store.error?.errorDescription,
                         refreshInterval: store.refreshInterval,
                         openDashboard: { openRoute(.overview) }, openSettings: { openRoute(.settings) },
                         refresh: { Task { await store.refresh() } })
            .environment(\.locale, store.interfaceLanguage.locale)
            .id(store.interfaceLanguage)
            .task { store.start() }
            .onExitCommand(perform: close)
    }
}

/// Separate from window routing so previews exercise the actual popover layout.
struct MenuBarUsageCard: View {
    var snapshot: UsageSnapshot?
    var history: UsageHistory? = nil
    var mode: MenuContentMode = .summary
    var dailyBudget: Double? = nil
    var timezone = "UTC"
    var isRefreshing = false
    var isDemo = false
    var error: String?
    var refreshInterval: TimeInterval = 180
    var openDashboard: () -> Void = {}
    var openSettings: () -> Void = {}
    var refresh: () -> Void = {}
    private let ink = Color.primary
    private let secondaryInk = Color.secondary
    private let rule = Color.primary.opacity(0.09)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot {
                summary(snapshot)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("—").font(.system(size: 48, weight: .semibold))
                    HStack(spacing: 8) {
                        if error == nil { ProgressView().controlSize(.small) }
                        Text(error ?? L10n.text("Загружаем статистику…"))
                            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }.foregroundStyle(secondaryInk)
                }.padding(.top, 17).padding(.bottom, 22)
            }

            Rectangle().fill(rule).frame(height: 1)
            VStack(spacing: 0) {
                action(L10n.text("Открыть обзор"), symbol: "arrow.up.forward.square", shortcut: "O", action: openDashboard)
                    .keyboardShortcut("o")
                HStack(spacing: 12) {
                    action(isRefreshing ? L10n.text("Обновляем…") : L10n.text("Обновить"), symbol: "arrow.clockwise", shortcut: "R", action: refresh)
                        .keyboardShortcut("r")
                        .disabled(isRefreshing || isDemo)
                    settingsButton
                }
            }.padding(.top, 10)
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
        .frame(width: 328)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(ink)
        // NSPopover owns the material, chevron, clipping, border and shadow.
        // Keeping this view transparent avoids a second set of rounded corners.
    }

    private var settingsButton: some View {
        Button(action: openSettings) {
            Image(systemName: "gearshape").font(.system(size: 16, weight: .regular))
                .frame(width: 24, height: 30)
        }
        .buttonStyle(MenuBarActionStyle()).foregroundStyle(secondaryInk)
        .help(L10n.text("Настройки · ⌘,")).accessibilityLabel(L10n.text("Настройки")).keyboardShortcut(",")
        .contextMenu {
            Button(L10n.text("Настройки…"), action: openSettings)
            Divider()
            Button(L10n.text("Завершить LLM Usage")) { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }

    private func summary(_ snapshot: UsageSnapshot) -> some View {
        let usage = snapshot.totals
        return VStack(alignment: .leading, spacing: 0) {
            UsageDayCaption(day: snapshot.day)
            UsageAmount(usage: usage, size: 48)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            Text(L10n.text("\(UsageFormat.tokens(usage.total)) Tokens  ·  Сессии: \(snapshot.sessions.count)"))
                .font(.system(size: 12)).foregroundStyle(secondaryInk)
                .lineLimit(1).minimumScaleFactor(0.8).padding(.top, 5)
            if usage.costIsIncomplete == true {
                Label(L10n.text("Стоимость неполная"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(secondaryInk).padding(.top, 8)
            }
            if snapshot.day.isToday(), let budget = DailyBudget(limit: dailyBudget, usage: usage) {
                UsageBudgetMeter(budget: budget).padding(.top, 18)
            }
            if mode == .trend {
                trend.padding(.top, 20)
            } else {
            TokenDistribution(usage: usage, height: 5).padding(.top, 20)
            Grid(horizontalSpacing: 9, verticalSpacing: 12) {
                ForEach(usage.categories) { category in
                    let count = usage.value(for: category)
                    GridRow {
                        Circle().fill(category.color).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(category.title).foregroundStyle(secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(UsageFormat.tokens(count)).monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        Text(UsageFormat.menuBarPercent(count: count, total: usage.total))
                            .font(.system(size: 11))
                            .foregroundStyle(secondaryInk).monospacedDigit()
                            .frame(width: 49, alignment: .trailing)
                    }.accessibilityElement(children: .combine)
                }
            }.font(.system(size: 12)).padding(.top, 17)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            } else if snapshot.isStale(interval: refreshInterval) {
                Text(L10n.text("Обновлено \(UsageFormat.time(snapshot.generatedAt)) · данные устарели"))
                    .font(.system(size: 11)).foregroundStyle(secondaryInk).padding(.top, 14)
            }
        }.padding(.bottom, 22)
    }

    private var trend: some View {
        let today = UsageDay(timezone: timezone)
        let points = (history ?? UsageHistory(context: .init(timezone: timezone, customPath: ""))).points(ending: today)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("За 7 дней")).foregroundStyle(.secondary)
                Spacer()
                Text(UsageFormat.cost(points.knownUsage)).fontWeight(.medium)
            }.font(.system(size: 12))
            DailyCostChart(points: points, today: today).frame(height: 104)
            HistoryCoverageCaption(points: points)
        }
    }

    private func action(_ title: String, symbol: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .regular)).frame(width: 18)
                    .foregroundStyle(secondaryInk)
                Text(title).font(.system(size: 12, weight: .regular))
                Spacer(minLength: 4)
                Text("⌘\(shortcut)").font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }.frame(height: 34).contentShape(Rectangle())
        }.buttonStyle(MenuBarActionStyle())
    }
}

private struct MenuBarActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        MenuBarActionBody(configuration: configuration)
            .opacity(isEnabled ? 1 : 0.5)
    }
    private struct MenuBarActionBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : hovering ? 0.045 : 0))
                    .padding(.horizontal, -6))
                .onHover { hovering = $0 }
        }
    }
}
