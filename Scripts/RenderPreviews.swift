import SwiftUI
import AppKit
import WidgetKit

@main
struct RenderPreviews {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let languageArgument = CommandLine.arguments.first { $0.hasPrefix("--language=") }?.split(separator: "=").last.map(String.init)
        let language = InterfaceLanguage(rawValue: languageArgument ?? "") ?? .system
        L10n.preference = language
        var output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        if let languageArgument { output.appendPathComponent("localization-" + languageArgument, isDirectory: true) }
        func previewStore() -> UsageStore {
            let suite = "local.LLMUsage.RenderPreviews.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(language.rawValue, forKey: "interfaceLanguage")
            let store = UsageStore(defaults: defaults, demo: true)
            defaults.removePersistentDomain(forName: suite)
            return store
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        func render<V: View>(_ view: V, name: String, size: CGSize, dark: Bool = false) throws {
            let requestedNames = CommandLine.arguments.dropFirst(2).filter { !$0.hasPrefix("--language=") }
            let localePreview = requestedNames.contains("--localization") && (
                ["overview-light", "overview-dark", "sessions", "models", "settings", "session-detail", "session-chat-light", "menu-dropdown-light", "menu-dropdown-error", "menu-dropdown-trend-budget-dark"].contains(name)
                || name.hasPrefix("widget-size-")
                || (name.hasPrefix("widget-native-") && ["-normal-", "-gaps-budget-", "-huge-", "-empty-", "-error-"].contains(where: name.contains)))
            guard localePreview || requestedNames.isEmpty || requestedNames.contains(name)
                    || (requestedNames.contains("--widgets") && name.hasPrefix("widget-"))
                    || (requestedNames.contains("--sidebars") && name.hasPrefix("sidebar-"))
                    || (requestedNames.contains("--models") && name.hasPrefix("models"))
                    || (requestedNames.contains("--chat") && name.hasPrefix("session-chat"))
                    || (requestedNames.contains("--menus") && name.hasPrefix("menu-dropdown")) else { return }
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            app.appearance = appearance
            let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, language.locale)
                .background {
                    if name.hasPrefix("menu-dropdown") { PopoverPreviewMaterial() }
                })
            let renderedSize = name.hasPrefix("menu-dropdown") ? host.fittingSize : size
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: renderedSize), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
            window.orderFront(nil)
            host.frame = CGRect(origin: .zero, size: renderedSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot render \(name)") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
            try data.write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
            print("Rendered \(name)")
        }
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let modelsStore = previewStore()
            modelsStore.tab = .models
            modelsStore.setModelIncluded(false, model: "gpt-6-astra")
            for width: CGFloat in [610, 880] {
                try render(ModelsView(store: modelsStore, snapshot: modelsStore.displaySnapshot!)
                    .background(Color(nsColor: .windowBackgroundColor)),
                           name: "models-excluded-\(Int(width))-\(suffix)", size: .init(width: width, height: 650), dark: dark)
            }
            for active in [true, false] {
                for tab in [DashboardTab.overview, .settings] {
                    let store = previewStore()
                    store.tab = tab
                    let sidebar = DashboardView(store: store).sidebarPreview
                        .environment(\.appearsActive, active)
                        .background(Color(nsColor: .windowBackgroundColor))
                    try render(sidebar, name: "sidebar-\(tab == .settings ? "settings-" : "")\(suffix)-\(active ? "active" : "inactive")",
                               size: .init(width: 220, height: 560), dark: dark)
                }
            }
            let sample = TokenUsage(cost: 23.36)
            for compact in [false, true] {
                let menu = HStack(spacing: 18) {
                    MenuBarUsageLabel(usage: sample, compact: compact)
                    Image(systemName: "wifi").font(.system(size: 13, weight: .medium))
                    Image(systemName: "battery.100percent").font(.system(size: 18))
                }
                .foregroundStyle(dark ? Color.white : Color.black)
                .frame(width: 220, height: 32)
                .background(dark ? Color(white: 0.15) : Color(white: 0.94))
                try render(menu, name: "menubar-\(compact ? "compact-" : "")\(suffix)", size: .init(width: 220, height: 32), dark: dark)
            }
            let amounts: [TokenUsage?] = [nil, .init(cost: 0), .init(cost: 23.36), .init(cost: 123.45),
                                         .init(cost: 1234), .init(cost: 1_234_567), .init(cost: 23.36, costIsIncomplete: true)]
            let states = VStack(spacing: 16) {
                ForEach([false, true], id: \.self) { compact in
                    HStack(spacing: 18) {
                        ForEach(amounts.indices, id: \.self) { index in MenuBarUsageLabel(usage: amounts[index], compact: compact) }
                    }
                }
            }.foregroundStyle(dark ? Color.white : Color.black)
                .frame(width: 800, height: 90)
                .background(dark ? Color(white: 0.15) : Color(white: 0.94))
            try render(states, name: "menubar-states-\(suffix)", size: .init(width: 800, height: 90), dark: dark)
            var reference = SampleData.snapshot()
            reference.sessions[0].usage.cost = 21.05
            for index in 2..<12 {
                reference.sessions.append(.init(id: "reference-\(index)", models: [], usage: .zero, lastActivity: nil))
            }
            try render(MenuBarUsageCard(snapshot: reference), name: "menu-dropdown-\(suffix)", size: .init(width: 328, height: 450), dark: dark)
            try render(MenuBarUsageCard(snapshot: SampleData.multiSourceSnapshot()), name: "menu-dropdown-sources-\(suffix)", size: .init(width: 328, height: 485), dark: dark)
            var hugeMenu = SampleData.multiSourceSnapshot()
            hugeMenu.sessions[0].usage.cost = 123_456.78
            try render(MenuBarUsageCard(snapshot: hugeMenu), name: "menu-dropdown-huge-\(suffix)", size: .init(width: 328, height: 485), dark: dark)
            try render(MenuBarUsageCard(snapshot: nil), name: "menu-dropdown-empty-\(suffix)", size: .init(width: 328, height: 265), dark: dark)
            try render(MenuBarUsageCard(snapshot: .init(generatedAt: Date(), day: .init(), sessions: [])), name: "menu-dropdown-zero-\(suffix)", size: .init(width: 328, height: 450), dark: dark)
            try render(MenuBarUsageCard(snapshot: SampleData.multiSourceSnapshot(now: Date().addingTimeInterval(-86400))), name: "menu-dropdown-historical-\(suffix)", size: .init(width: 328, height: 485), dark: dark)
        }
        try render(MenuBarUsageCard(snapshot: nil), name: "menu-dropdown-loading", size: .init(width: 328, height: 265))
        try render(MenuBarUsageCard(snapshot: nil, error: L10n.text("ccusage не найден")), name: "menu-dropdown-error", size: .init(width: 328, height: 265))
        try render(MenuBarUsageCard(snapshot: .init(generatedAt: Date(), day: .init(), sessions: [])), name: "menu-dropdown-empty", size: .init(width: 328, height: 450))
        var partialMenu = SampleData.multiSourceSnapshot()
        partialMenu.sessions[0].usage.costIsIncomplete = true
        try render(MenuBarUsageCard(snapshot: partialMenu, error: L10n.text("Не удалось обновить данные")), name: "menu-dropdown-partial", size: .init(width: 328, height: 515))
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let store = previewStore()
            try render(DashboardView(store: store).contentPreview, name: "overview-\(suffix)", size: .init(width: 880, height: 760), dark: dark)
            for (family, name): (WidgetFamily, String) in [(.systemSmall,"small"),(.systemMedium,"medium"),(.systemLarge,"large")] {
                let size = CGSize(width: family == .systemSmall ? 164 : 344, height: family == .systemLarge ? 344 : 164)
                try render(WidgetPreviewCard(family: family), name: "widget-\(name)-\(suffix)", size: size, dark: dark)
            }
        }
        let fixtureDate = Date()
        var fixtureSnapshot = SampleData.multiSourceSnapshot(now: fixtureDate)
        let fixtureContext = UsageDataContext(timezone: fixtureSnapshot.day.timezone, customPath: "")
        fixtureSnapshot.dataContext = fixtureContext
        var fixtureHistory = SampleData.history(now: fixtureDate, context: fixtureContext)
        fixtureHistory.record(fixtureSnapshot, today: fixtureSnapshot.day)
        var gapHistory = fixtureHistory
        gapHistory.days.removeAll { $0.day == fixtureSnapshot.day.adding(days: -3) || $0.day == fixtureSnapshot.day.adding(days: -5) }
        var zeroSnapshot = fixtureSnapshot
        zeroSnapshot.sessions = []
        var zeroHistory = fixtureHistory
        for index in zeroHistory.days.indices { zeroHistory.days[index].usage = .zero }
        var hugeSnapshot = fixtureSnapshot
        hugeSnapshot.sessions[0].usage.cost = 123_456.78
        hugeSnapshot.sessions[0].models = ["a-very-long-model-name-with-a-release-version"]
        var hugeHistory = fixtureHistory
        hugeHistory.record(hugeSnapshot, today: fixtureSnapshot.day)
        var partialSnapshot = fixtureSnapshot
        partialSnapshot.sessions[0].usage.costIsIncomplete = true
        gapHistory.record(partialSnapshot, today: fixtureSnapshot.day)
        let budgetStatus = RefreshStatus(attemptedAt: fixtureDate, message: nil, refreshMinutes: 15,
                                         dailyBudget: 10, dataContext: fixtureContext)
        let variantCases: [(String, UsageSnapshot?, UsageHistory?, RefreshStatus?, Date)] = [
            ("normal", fixtureSnapshot, fixtureHistory, nil, fixtureDate),
            ("gaps-budget", partialSnapshot, gapHistory, budgetStatus, fixtureDate),
            ("zero", zeroSnapshot, zeroHistory, budgetStatus, fixtureDate),
            ("stale", fixtureSnapshot, fixtureHistory, nil, fixtureDate.addingTimeInterval(7200)),
            ("error", fixtureSnapshot, fixtureHistory, RefreshStatus(attemptedAt: fixtureDate, message: "Не удалось обновить", refreshMinutes: 15), fixtureDate),
            ("huge", hugeSnapshot, hugeHistory, budgetStatus, fixtureDate),
            ("midnight", fixtureSnapshot, fixtureHistory, budgetStatus, fixtureSnapshot.day.end.addingTimeInterval(60)),
            ("empty", nil, nil, nil, fixtureDate)
        ]
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try render(MenuBarUsageCard(snapshot: fixtureSnapshot, history: fixtureHistory, mode: .trend, dailyBudget: 10),
                       name: "menu-dropdown-trend-budget-\(suffix)", size: .init(width: 328, height: 500), dark: dark)
            try render(MenuBarUsageCard(snapshot: partialSnapshot, history: gapHistory, mode: .trend, dailyBudget: 10),
                       name: "menu-dropdown-trend-gaps-\(suffix)", size: .init(width: 328, height: 500), dark: dark)
            for (name, snapshot, history, status, date) in variantCases {
                for variant in UsageWidgetVariant.allCases {
                    if name == "normal" {
                        for (family, familyName): (WidgetFamily, String) in [(.systemSmall, "small"), (.systemMedium, "medium"), (.systemLarge, "large")] {
                            let size = CGSize(width: family == .systemSmall ? 164 : 344, height: family == .systemLarge ? 344 : 164)
                            try render(WidgetPreviewCard(family: family, variant: variant, history: history, snapshot: snapshot, status: status, date: date),
                                       name: "widget-size-\(variant.rawValue)-\(familyName)-\(suffix)", size: size, dark: dark)
                        }
                    }
                    let sheet = VStack(alignment: .leading, spacing: 18) {
                        Text("\(variant.title) · \(name) · \(dark ? "Dark" : "Light")").font(.system(size: 17, weight: .semibold))
                        HStack(alignment: .top, spacing: 20) {
                            ForEach([WidgetFamily.systemSmall, .systemMedium, .systemLarge], id: \.self) { family in
                                WidgetPreviewCard(family: family, variant: variant, history: history, snapshot: snapshot,
                                                  status: status, date: date)
                            }
                        }
                        Text("WidgetKit content · 164×164 / 344×164 / 344×344 · \(L10n.text("Демо-данные"))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(20).background(Color(nsColor: .underPageBackgroundColor))
                    try render(sheet, name: "widget-native-\(variant.rawValue)-\(name)-\(suffix)",
                               size: .init(width: 932, height: 438), dark: dark)
                }
            }
        }
        let store = previewStore()
        let chatSession = SampleData.multiSourceSnapshot().sessions[0]
        try render(SessionChatView(session: chatSession, timezone: "Europe/Moscow", isDemo: true),
                   name: "session-chat-light", size: .init(width: 900, height: 780))
        try render(SessionChatView(session: chatSession, timezone: "Europe/Moscow", isDemo: true),
                   name: "session-chat-dark", size: .init(width: 900, height: 780), dark: true)
        try render(SessionChatView(session: chatSession, timezone: "Europe/Moscow", isDemo: true),
                   name: "session-chat-narrow", size: .init(width: 680, height: 640))
        let chatTranscript = TranscriptPreview.sample
        try render(TranscriptTimingDetails(timing: chatTranscript.events[0].timing!, timezone: "Europe/Moscow")
                    .padding(18).frame(width: 340, height: 450, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor)),
                   name: "session-chat-timing-details", size: .init(width: 340, height: 450))
        var usageChat = chatSession
        usageChat.usage = chatTranscript.requests.reduce(.zero) { $0 + $1.usage }
        let chatDay = UsageDay(date: chatTranscript.requests[0].timestamp!, timezone: "Europe/Moscow")
        for width: CGFloat in [680, 900] {
            for dark in [false, true] {
                for tab in TranscriptAnalysisTab.allCases {
                    try render(SessionChatView(session: usageChat, timezone: "Europe/Moscow", isDemo: true, preview: chatTranscript,
                                               day: chatDay, initialTab: tab),
                               name: "session-chat-usage-\(tab.rawValue)-\(Int(width))-\(dark ? "dark" : "light")",
                               size: .init(width: width, height: 740), dark: dark)
                }
                try render(SessionChatView(session: usageChat, timezone: "Europe/Moscow", isDemo: true, preview: chatTranscript,
                                           day: chatDay, initialFilter: .tools, initiallyExpandedTools: ["3"]),
                           name: "session-chat-inspector-\(Int(width))-\(dark ? "dark" : "light")",
                           size: .init(width: width, height: 740), dark: dark)
                try render(SessionChatView(session: usageChat, timezone: "Europe/Moscow", isDemo: true, preview: chatTranscript,
                                           day: chatDay, initialFilter: .errors, initiallyExpandedTools: ["7"]),
                           name: "session-chat-errors-\(Int(width))-\(dark ? "dark" : "light")",
                           size: .init(width: width, height: 740), dark: dark)
            }
        }
        try render(TranscriptRequestDetails(request: chatTranscript.requests[0], policy: .init()).padding(18)
            .frame(width: 330).background(Color(nsColor: .windowBackgroundColor)),
                   name: "session-chat-request-details", size: .init(width: 330, height: 340))
        try render(TranscriptUserUsageDetails(requests: chatTranscript.requests, policy: .init())
                    .background(Color(nsColor: .windowBackgroundColor)),
                   name: "session-chat-user-usage-details", size: .init(width: 370, height: 450))
        store.tab = .sessions
        try render(DashboardView(store: store).contentPreview, name: "sessions", size: .init(width: 900, height: 700))
        try render(DashboardView(store: store).contentPreview, name: "sessions-narrow", size: .init(width: 370, height: 600))
        store.selectedSessionID = SampleData.multiSourceSnapshot().sessions[2].id
        try render(SessionDetailView(store: store, sessionID: store.selectedSessionID!)
            .background(Color(nsColor: .windowBackgroundColor)), name: "session-detail", size: .init(width: 310, height: 740))
        store.selectedSessionID = nil
        store.tab = .models
        try render(DashboardView(store: store).contentPreview, name: "models", size: .init(width: 880, height: 760))
        store.tab = .overview
        store.sourceFilter = "codex"
        try render(DashboardView(store: store).contentPreview, name: "overview-codex", size: .init(width: 880, height: 760))
        store.sourceFilter = ""
        store.tab = .settings
        try render(DashboardView(store: store).contentPreview, name: "settings", size: .init(width: 800, height: 900))
        try render(WidgetPreviewCard(family: .systemSmall, snapshot: nil), name: "widget-empty", size: .init(width: 170, height: 170))
        try render(WidgetPreviewCard(family: .systemMedium, status: .init(attemptedAt: Date(), message: "Ошибка ccusage", refreshMinutes: 15)), name: "widget-error-with-data", size: .init(width: 360, height: 170))
        try render(WidgetPreviewCard(family: .systemMedium, snapshot: SampleData.multiSourceSnapshot(now: Date().addingTimeInterval(-7200))), name: "widget-stale", size: .init(width: 360, height: 170))
        try render(DashboardView(store: previewStore()).contentPreview, name: "overview-minimum", size: .init(width: 660, height: 580))
        try render(DashboardView(store: previewStore()).contentPreview, name: "overview-inspector-width", size: .init(width: 370, height: 640))
        try render(TokenUsageGrid(usage: SampleData.multiSourceSnapshot().totals).padding(22)
            .background(Color(nsColor: .windowBackgroundColor)), name: "token-grid-narrow", size: .init(width: 370, height: 280))
        var unpriced = SampleData.multiSourceSnapshot()
        unpriced.sessions[0].usage.costIsIncomplete = true
        try render(WidgetPreviewCard(family: .systemLarge, snapshot: unpriced), name: "widget-incomplete-cost", size: .init(width: 360, height: 382))
        var many = SampleData.multiSourceSnapshot()
        let extra = many.sessions[1]
        for index in 3...8 {
            var session = extra
            session.id = "\(index)4231c5e-4661-4266-aeb5-6587beb40add"
            many.sessions.append(session)
        }
        try render(WidgetPreviewCard(family: .systemLarge, snapshot: many), name: "widget-many-sessions", size: .init(width: 360, height: 382))
        let now = Date()
        let normal = SampleData.multiSourceSnapshot(now: now)
        var huge = normal
        huge.sessions[0].usage.cost = 123_456.78
        huge.sessions[0].models = ["a-very-long-model-name-with-a-release-version"]
        var zero = normal
        zero.sessions = []
        let failure = RefreshStatus(attemptedAt: now, message: "Не удалось получить статистику", refreshMinutes: 15)
        let cases: [(String, UsageSnapshot?, RefreshStatus?, Date, Bool)] = [
            ("normal", normal, nil, now, false),
            ("compact", normal, nil, now, false),
            ("zero", zero, nil, now, false),
            ("empty", nil, nil, now, false),
            ("error", normal, failure, now, false),
            ("partial", unpriced, nil, now, false),
            ("stale", normal, nil, now.addingTimeInterval(7200), false),
            ("midnight", normal, nil, normal.day.end.addingTimeInterval(60), false),
            ("huge", huge, nil, now, false),
            ("storage", nil, failure, now, true)
        ]
        for dark in [false, true] {
            for (name, snapshot, status, date, unavailable) in cases {
                let sheet = VStack(alignment: .leading, spacing: 20) {
                    Text("LLM Usage · \(name) · \(dark ? "Dark" : "Light")")
                        .font(.system(size: 20, weight: .semibold))
                    Text("SwiftUI content previews · Small / Medium / Large · \(L10n.text("Демо-данные"))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 24) {
                        ForEach([WidgetFamily.systemSmall, .systemMedium, .systemLarge], id: \.self) { family in
                            WidgetPreviewCard(family: family, snapshot: snapshot, status: status,
                                              date: date, storageUnavailable: unavailable,
                                              size: name == "compact" ? CGSize(width: family == .systemSmall ? 158 : 338,
                                                                              height: family == .systemLarge ? 354 : 158) : nil)
                        }
                    }
                }.padding(24).background(Color(nsColor: .underPageBackgroundColor))
                try render(sheet, name: "widget-sheet-\(name)-\(dark ? "dark" : "light")",
                           size: .init(width: 986, height: 496), dark: dark)
            }
        }
    }
}

// Content-only preview; the app's real NSPopover supplies its chevron and outer chrome.
private struct PopoverPreviewMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
