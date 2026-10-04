import SwiftUI

/// Keep padding inside the native control so the toolbar capsule and its highlight share bounds.
private struct PeriodToolbarMenu: NSViewRepresentable {
    @ObservedObject var store: UsageStore
    var onCustomDate: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(store: store, onCustomDate: onCustomDate) }

    func makeNSView(context: Context) -> PeriodMenuHostView {
        let button = PeriodPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .glass
        button.borderShape = .capsule
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13)
        button.alignment = .center
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: store.period.title, action: nil, keyEquivalent: "")
        for (index, period) in DataPeriod.allCases.enumerated() {
            let item = NSMenuItem(title: period.title, action: #selector(Coordinator.selectPeriod(_:)), keyEquivalent: "")
            item.tag = index
            item.target = context.coordinator
            menu.addItem(item)
        }
        button.menu = menu
        let host = PeriodMenuHostView(button: button)
        updateNSView(host, context: context)
        return host
    }

    func updateNSView(_ host: PeriodMenuHostView, context: Context) {
        let button = host.button
        context.coordinator.store = store
        context.coordinator.onCustomDate = onCustomDate
        button.menu?.items.first?.title = store.period.title
        button.synchronizeTitleAndSelectedItem()
        for (index, item) in (button.menu?.items.dropFirst() ?? []).enumerated() {
            item.title = DataPeriod.allCases[index].title
            item.state = DataPeriod.allCases[index] == store.period ? .on : .off
        }
        button.isEnabled = !store.isDemo
        button.toolTip = L10n.text("Период · \(store.timezone)")
        button.setAccessibilityLabel(L10n.text("Период: \(store.period.title)"))
        button.invalidateIntrinsicContentSize()
        host.invalidateIntrinsicContentSize()
    }

    @MainActor final class Coordinator {
        var store: UsageStore
        var onCustomDate: () -> Void
        init(store: UsageStore, onCustomDate: @escaping () -> Void) {
            self.store = store
            self.onCustomDate = onCustomDate
        }

        @objc func selectPeriod(_ item: NSMenuItem) {
            let period = DataPeriod.allCases[item.tag]
            if period == .custom { onCustomDate(); return }
            guard store.period != period else { return }
            store.period = period
            Task { await store.selectPeriod() }
        }
    }
}

private final class PeriodMenuHostView: NSView {
    let button: PeriodPopUpButton

    init(button: PeriodPopUpButton) {
        self.button = button
        super.init(frame: NSRect(origin: .zero, size: button.intrinsicContentSize))
        button.frame = bounds
        button.autoresizingMask = [.width, .height]
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { button.intrinsicContentSize }
}

private final class PeriodPopUpButton: NSPopUpButton {
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 12, height: max(36, size.height))
    }
}

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var showTokenDetails = false
    @State private var datePopover: DatePopoverAnchor?
    private enum DatePopoverAnchor { case period, date }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var summaryActions

    // Content-only image previews avoid bitmap-caching system-composited glass panels.
    var contentPreview: some View { detail }
    var sidebarPreview: some View { sidebar }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            // Keep one toolbar owner when detail switches between settings and statistics.
            VStack(spacing: 0) { detail }
                // Constrain the native column. A content frame minimum can make
                // Tahoe's split view wider than its window and clip both edges.
                .navigationSplitViewColumnWidth(min: 520, ideal: 700)
                .navigationTitle(store.tab.title)
                .toolbar { dashboardToolbar }
                .inspector(isPresented: Binding(
                    get: { store.selectedSessionID != nil && store.tab != .settings },
                    set: { if !$0 { store.selectedSessionID = nil } }
                )) {
                    if let id = store.selectedSessionID {
                        SessionDetailView(store: store, sessionID: id)
                            .inspectorColumnWidth(min: 280, ideal: 310, max: 360)
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        // Reserve space for all three columns, including the user's widest sidebar
        // and inspector. The scene's contentMinSize expands the window on selection.
        .frame(minWidth: store.selectedSessionID != nil && store.tab != .settings ? 1160 : 860, minHeight: 560)
        .onChange(of: store.tab) { _, tab in if tab == .settings { store.selectedSessionID = nil } }
        .onChange(of: store.sourceFilter) { _, _ in
            if let session = store.selectedSession, !store.sourceFilter.isEmpty,
               session.sourceID != store.sourceFilter {
                store.selectedSessionID = nil
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding<DashboardTab?>(get: { store.tab }, set: { if let tab = $0 { store.selectedSessionID = nil; store.tab = tab } })) {
                ForEach([DashboardTab.overview, .models]) { tab in
                    DashboardSidebarLabel(title: tab.title, symbol: tab.symbol, isSelected: store.tab == tab)
                        .background(DashboardSidebarSelectionBridge().allowsHitTesting(false).accessibilityHidden(true))
                        .listRowBackground(DashboardSidebarSelection(isSelected: store.tab == tab, horizontalInset: 10))
                        .tag(tab)
                }
                if store.tab != .settings, let data = store.snapshot, !data.sessions.isEmpty {
                    Section(L10n.text("Источники")) {
                        sourceButton(id: "", name: L10n.text("Все источники"), count: data.sessions.count)
                        ForEach(data.sourceSummaries) { source in
                            sourceButton(id: source.id, name: source.label, count: source.sessionCount)
                        }
                    }
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            VStack(alignment: .leading, spacing: 14) {
                Button { store.tab = .settings } label: {
                    DashboardSidebarLabel(title: L10n.text("Настройки"), symbol: "gearshape", isSelected: store.tab == .settings)
                        .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(DashboardSidebarSelection(isSelected: store.tab == .settings))
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(store.tab == .settings ? .isSelected : [])
                HStack(spacing: 6) {
                    Circle().fill(store.error == nil ? Color.secondary.opacity(0.5) : .orange).frame(width: 5, height: 5)
                    Text(store.isDemo ? L10n.text("Демо-данные") : store.isRefreshing ? L10n.text("Обновление…") : store.snapshot.map { L10n.text("Обновлено \(UsageFormat.time($0.generatedAt))") } ?? L10n.text("Локальные данные"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.horizontal, 8)
            }.padding(12)
        }
    }

    private func sourceButton(id: String, name: String, count: Int) -> some View {
        Button {
            store.sourceFilter = id
            if store.tab == .settings { store.tab = .overview }
        } label: {
            DashboardSidebarSourceLabel(id: id, name: name, count: count, isSelected: store.sourceFilter == id)
        }.buttonStyle(.plain).help(L10n.text("Показать: \(name)"))
    }

    @ViewBuilder private var detail: some View {
        if store.tab == .settings {
            UsageSettingsView(store: store)
        } else {
            VStack(spacing: 0) {
                if let error = store.error, store.snapshot != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error.errorDescription ?? L10n.text("Не удалось обновить данные")).lineLimit(2)
                        Spacer()
                        Button(L10n.text("Настройки")) { store.tab = .settings }.buttonStyle(.borderless)
                    }
                    .font(.caption).padding(.horizontal, 28).padding(.vertical, 10)
                    .background(Color.orange.opacity(0.06), ignoresSafeAreaEdges: [])
                }
                if let snapshot = store.displaySnapshot {
                    switch store.tab {
                    case .overview: overview(snapshot)
                    case .models: ModelsView(store: store, snapshot: snapshot)
                    case .settings: EmptyView()
                    }
                } else { initialState }
            }
            .background { DashboardBackdrop().ignoresSafeArea() }
        }
    }

    @ToolbarContentBuilder private var dashboardToolbar: some ToolbarContent {
        if store.tab != .settings {
            ToolbarItem(placement: .automatic) {
                if store.period == .custom {
                    Button { datePopover = .date } label: {
                        Label(UsageFormat.date(store.customDate, timezone: store.timezone), systemImage: "calendar")
                            .labelStyle(.titleAndIcon).font(.system(size: 13)).fixedSize()
                    }
                    .disabled(store.isDemo)
                    .help(L10n.text("Выбрать дату"))
                    .accessibilityLabel(L10n.text("Выбрать дату: \(UsageFormat.date(store.customDate, timezone: store.timezone))"))
                    .popover(isPresented: calendarPresented(at: .date)) { calendarPopover }
                }
            }
            if store.period == .custom {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                PeriodToolbarMenu(store: store) { datePopover = .period }.fixedSize()
                    .popover(isPresented: calendarPresented(at: .period)) { calendarPopover }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await store.refresh() } } label: {
                if store.isRefreshing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .keyboardShortcut("r").disabled(store.isRefreshing || store.isDemo)
            .help(L10n.text("Обновить статистику · ⌘R")).accessibilityLabel(L10n.text("Обновить статистику"))
        }
    }

    private func calendarPresented(at anchor: DatePopoverAnchor) -> Binding<Bool> {
        Binding(get: { datePopover == anchor }, set: { if !$0 && datePopover == anchor { datePopover = nil } })
    }

    private var calendarPopover: some View {
        UsageDatePopover(date: store.selectedDay.date, timezone: store.timezone) { date in
            datePopover = nil
            Task { await store.selectCustomDate(date) }
        } onCancel: {
            datePopover = nil
        }
    }

    @ViewBuilder private var initialState: some View {
        if store.isRefreshing {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.text("Читаем локальную статистику…")).font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                EmptyUsageView(title: store.error?.errorDescription ?? L10n.text("Подключите ccusage"),
                               message: store.error?.recovery ?? L10n.text("Расходы и активность локальных AI-агентов появятся здесь."), symbol: "terminal")
                HStack(spacing: 10) {
                    Button(L10n.text("Найти автоматически")) { Task { await store.testCLI(autoDetect: true); await store.refresh(reason: .configuration) } }
                        .buttonStyle(.borderedProminent)
                    Button(L10n.text("Выбрать файл…")) { CLIExecutablePicker.choose(store: store) }
                }
                Spacer()
            }.frame(maxWidth: .infinity)
        }
    }

    private func overview(_ snapshot: UsageSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    spendSummary(snapshot) {
                        if store.sessionList.isExpanded {
                            scrollToSessions(using: proxy)
                        } else {
                            withAnimation(reduceMotion ? nil : DashboardSessionsSection.expansionAnimation,
                                          completionCriteria: .removed) {
                                store.sessionList.setExpanded(true)
                            } completion: {
                                if store.sessionList.isExpanded { scrollToSessions(using: proxy) }
                            }
                        }
                    }
                    if snapshot.totals.costIsIncomplete == true {
                        Label(L10n.text("Часть данных для расчёта недоступна. Показаны только учтённые токены и известная стоимость."), systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if showTokenDetails {
                        DashboardSection {
                            TokenUsageGrid(usage: snapshot.totals).padding(22)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    DashboardSessionsSection(store: store, scrollToSession: { id in
                        proxy.scrollTo(id)
                    }) { scrollToSessions(using: proxy) }
                        .id("session-list")
                }
                .padding(30).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            }
            .task(id: store.sessionNavigationID) {
                // Reveal explicit widget/deep links once; local toggles do not auto-scroll.
                // A selected row is revealed by the session section once filtering completes.
                guard store.sessionList.isExpanded, store.selectedSessionID == nil else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo("session-list", anchor: .top)
            }
        }
    }

    private func scrollToSessions(using proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            proxy.scrollTo("session-list", anchor: .top)
        }
    }

    private func spendSummary(_ snapshot: UsageSnapshot, showSessions: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 38) {
                    spendAmount(snapshot)
                    activitySummary(snapshot).frame(width: 230)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 24) {
                    spendAmount(snapshot)
                    activitySummary(snapshot)
                }
            }
            if let totals = store.snapshot?.totals,
               let budget = DailyBudget(limit: store.dailyBudget, usage: totals) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("Дневной бюджет"))
                        .font(.system(size: 12, weight: .medium))
                    UsageBudgetMeter(budget: budget)
                    if !store.sourceFilter.isEmpty {
                        Text(L10n.text("Все источники")).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: 420, alignment: .leading)
            }
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 12) {
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { showTokenDetails.toggle() }
                    } label: {
                        Label(L10n.text("Состав токенов"), systemImage: "square.grid.2x2")
                    }
                    .glassEffectID("tokens", in: summaryActions)
                    .accessibilityValue(showTokenDetails ? L10n.text("Развёрнуто") : L10n.text("Свёрнуто"))
                    Button(action: showSessions) {
                        Label(L10n.text("Все сессии"), systemImage: "list.bullet")
                    }.glassEffectID("sessions", in: summaryActions)
                }
                .buttonStyle(.glass).controlSize(.large)
            }
        }
        .padding(.top, 8).padding(.bottom, 6)
    }

    private func spendAmount(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(snapshot.day.spendingTitle())
                if !store.sourceFilter.isEmpty { Text("· \(UsageSource.label(store.sourceFilter))") }
            }.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Text(UsageFormat.cost(snapshot.totals))
                .font(.system(size: 76, weight: .semibold)).tracking(-3).lineLimit(1).minimumScaleFactor(0.55)
                .accessibilityLabel(L10n.text("Расходы: \(UsageFormat.cost(snapshot.totals))"))
            if let previous = previousUsage(for: snapshot) {
                let change = snapshot.totals.cost - previous.cost
                HStack(spacing: 4) {
                    Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    Text(L10n.text("\(UsageFormat.cost(abs(change))) \(change >= 0 ? L10n.text("больше") : L10n.text("меньше")), чем вчера"))
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(L10n.text("Оценка стоимости · \(snapshot.day.timezone)")).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }.frame(minWidth: 265, alignment: .leading)
    }

    private func activitySummary(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(UsageFormat.tokens(snapshot.totals.total)).font(.system(size: 28, weight: .medium)).tracking(-0.6)
                Text(L10n.text("токенов")).font(.system(size: 12)).foregroundStyle(.secondary)
            }.lineLimit(1)
            TokenDistribution(usage: snapshot.totals, height: 12)
            HStack {
                Text(L10n.text("Сессии: \(snapshot.sessions.count)"))
                Spacer(minLength: 8)
                if let dominant = snapshot.totals.categories.max(by: { snapshot.totals.value(for: $0) < snapshot.totals.value(for: $1) }), snapshot.totals.total > 0 {
                    Text("\(UsageFormat.menuBarPercent(count: snapshot.totals.value(for: dominant), total: snapshot.totals.total)) \(dominant.title)")
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func previousUsage(for snapshot: UsageSnapshot) -> TokenUsage? {
        guard store.period == .today, snapshot.day.isToday(),
              let previous = store.previousSnapshot, previous.day == snapshot.day.adding(days: -1) else { return nil }
        let usage = previous.filtered(source: store.sourceFilter).totals
        guard usage.costIsIncomplete != true, snapshot.totals.costIsIncomplete != true else { return nil }
        return usage
    }

}

struct DashboardPreviews: PreviewProvider {
    static var previews: some View {
        DashboardView(store: UsageStore(demo: true)).frame(width: 1080, height: 760)
    }
}
