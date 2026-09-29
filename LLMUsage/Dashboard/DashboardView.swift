import SwiftUI

/// Keep padding inside the native control so the toolbar capsule and its highlight share bounds.
private struct PeriodToolbarMenu: NSViewRepresentable {
    @ObservedObject var store: UsageStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

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
        init(store: UsageStore) { self.store = store }

        @objc func selectPeriod(_ item: NSMenuItem) {
            let period = DataPeriod.allCases[item.tag]
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var summaryActions

    // Content-only image previews avoid bitmap-caching system-composited glass panels.
    var contentPreview: some View { detail }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            detail
                .frame(minWidth: 520)
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
                ForEach([DashboardTab.overview, .sessions, .models]) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
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
                    Label(L10n.text("Настройки"), systemImage: "gearshape")
                        .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(store.tab == .settings ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
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
            HStack(spacing: 8) {
                if id.isEmpty { Image(systemName: "square.stack.3d.up").frame(width: 14) }
                else { Circle().fill(UsageSource.color(id)).frame(width: 6, height: 6).frame(width: 14) }
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
                if store.sourceFilter == id { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                else { Text(String(count)).font(.caption).foregroundStyle(.tertiary) }
            }
            .font(.system(size: 12))
            .foregroundStyle(store.sourceFilter == id ? Color.primary : Color.secondary)
            .padding(.vertical, 3).contentShape(Rectangle())
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
                    .background(Color.orange.opacity(0.06))
                }
                if let snapshot = store.displaySnapshot {
                    switch store.tab {
                    case .overview: overview(snapshot)
                    case .sessions: SessionsView(store: store)
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
                    DatePicker(L10n.text("Дата"), selection: Binding(get: { store.customDate }, set: { date in
                        store.customDate = date
                        Task { await store.selectPeriod() }
                    }), in: ...Date(), displayedComponents: .date)
                        .labelsHidden().frame(width: 115)
                        .environment(\.timeZone, TimeZone(identifier: store.timezone)!)
                }
            }
            if store.period == .custom {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                PeriodToolbarMenu(store: store).fixedSize()
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                spendSummary(snapshot)
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
                if store.sourceFilter.isEmpty, snapshot.sourceSummaries.count > 1 {
                    sourceSpending(snapshot)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.text("Основные расходы")).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text(L10n.text("По стоимости")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if snapshot.sessions.isEmpty {
                        DashboardSection { EmptyUsageView() }
                    } else {
                        DashboardSection {
                            let rows = Array(SessionSort.cost.sorted(snapshot.sessions).prefix(5))
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, session in
                                if index > 0 { Divider().padding(.leading, 56) }
                                SessionSummaryRow(session: session, timezone: snapshot.day.timezone,
                                                  selected: store.selectedSessionID == session.id,
                                                  share: snapshot.totals.cost > 0 ? session.usage.cost / snapshot.totals.cost : 0) {
                                    store.selectedSessionID = session.id
                                }
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                }
                Text(L10n.text("Данные на этом Mac · Стоимость рассчитана по тарифам ccusage"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(30).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func spendSummary(_ snapshot: UsageSnapshot) -> some View {
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
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 12) {
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { showTokenDetails.toggle() }
                    } label: {
                        Label(L10n.text("Состав токенов"), systemImage: "square.grid.2x2")
                    }
                    .glassEffectID("tokens", in: summaryActions)
                    .accessibilityValue(showTokenDetails ? L10n.text("Развёрнуто") : L10n.text("Свёрнуто"))
                    Button { store.tab = .sessions } label: {
                        Label(L10n.text("Все сессии"), systemImage: "arrow.up.right")
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

    private func sourceSpending(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("По источникам")).font(.system(size: 15, weight: .semibold))
            DashboardSection {
                ForEach(Array(snapshot.sourceSummaries.enumerated()), id: \.element.id) { index, source in
                    if index > 0 { Divider().padding(.leading, 16) }
                    Button { store.sourceFilter = source.id } label: {
                        HStack(spacing: 16) {
                            SourceBadge(source: source.id).frame(width: 115, alignment: .leading)
                            UsageBar(fraction: snapshot.totals.cost > 0 ? source.usage.cost / snapshot.totals.cost : 0,
                                     color: UsageSource.color(source.id), height: 5)
                            Text(UsageFormat.cost(source.usage)).font(.system(size: 13, weight: .medium))
                                .monospacedDigit().frame(width: 80, alignment: .trailing)
                        }.padding(16).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(L10n.text("Фильтр: \(source.label)"))
                }
            }
        }
    }
}

struct DashboardPreviews: PreviewProvider {
    static var previews: some View {
        DashboardView(store: UsageStore(demo: true)).frame(width: 1080, height: 760)
    }
}
