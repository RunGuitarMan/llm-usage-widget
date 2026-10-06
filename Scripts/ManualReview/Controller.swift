import AppKit
import SwiftUI
import WidgetKit

enum ReviewAppearance: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var title: String { self == .light ? "Светлая" : "Тёмная" }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

enum ReviewSize: String, CaseIterable, Identifiable {
    case compact, standard, wide
    var id: String { rawValue }
    var title: String {
        switch self { case .compact: return "Узкое"; case .standard: return "Обычное"; case .wide: return "Широкое" }
    }
    var width: CGFloat {
        switch self { case .compact: return 860; case .standard: return 1080; case .wide: return 1280 }
    }
}

@MainActor final class ManualReviewController: ObservableObject {
    static let active: ManualReviewController? = {
        guard CommandLine.arguments.contains("--review") || CommandLine.arguments.contains("--manual-review") else { return nil }
        let args = CommandLine.arguments
        let directory = args.firstIndex(of: "--review-report-dir").flatMap { index in
            args.indices.contains(index + 1) ? URL(fileURLWithPath: args[index + 1]) : nil
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent("LLMUsageReview")
        do { return try ManualReviewController(reportDirectory: directory, resume: !args.contains("--review-self-check") && !args.contains("--review-widget-check") && !args.contains("--review-focus-check")) }
        catch { fatalError("Cannot initialize manual review: \(error)") }
    }()

    let store: UsageStore
    let service = ReviewFixtureService()
    let repository = ReviewRepository()
    let reportURL: URL
    private let positionURL: URL
    private struct Position: Codable {
        var scenario: String
        var language: String
        var appearance: String
        var size: String
    }
    let suite: String
    var buildID: String { AppLaunchReceipt.buildID }
    @Published var selectedID = ReviewScenario.all[0].id
    @Published var language: InterfaceLanguage = .russian
    @Published var appearance: ReviewAppearance = .light
    @Published var size: ReviewSize = .compact
    @Published var report = ReviewReport()
    @Published var persistenceError: String?
    @Published var preparing = false
    private var reportReadable = true
    private var lastTransition: Int?
    private var refreshTask: Task<Void, Never>?
    private(set) var selectionTask: Task<Void, Never>?
    weak var panel: NSWindow?
    private(set) weak var dashboard: NSWindow?
    private var openWindow: ((String) -> Void)?
    private var presentDashboard: (() -> Void)?
    private var showMenu: (() -> Void)?
    private(set) var chatKind: String?
    private(set) var connectedToAppRoot = false
    // Read-only observations from the actual SwiftUI views, never environment overrides.
    var observedSidebarAppearance: [String: Bool] = [:]

    init(reportDirectory: URL, resume: Bool = true) throws {
        reportURL = reportDirectory.appendingPathComponent("review-progress.json")
        positionURL = reportDirectory.appendingPathComponent("review-position.json")
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        suite = "local.LLMUsage.ManualReview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(InterfaceLanguage.russian.rawValue, forKey: "interfaceLanguage")
        defaults.set("Europe/Moscow", forKey: "timezone")
        defaults.set(UsageUpdateMode.allAgents.rawValue, forKey: "updateMode")
        store = UsageStore(service: service, repository: repository, defaults: defaults, reloadWidget: {})
        store.isManualReview = true
        if FileManager.default.fileExists(atPath: reportURL.path) {
            do {
                report = try JSONDecoder().decode(ReviewReport.self, from: Data(contentsOf: reportURL))
                guard report.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            } catch {
                reportReadable = false
                persistenceError = "Не удалось прочитать отчёт. Исходный файл сохранён; запись отключена: \(error.localizedDescription)"
            }
        }
        if resume {
            if let data = try? Data(contentsOf: positionURL), let position = try? JSONDecoder().decode(Position.self, from: data) {
                restore(position)
            } else if let latest = report.records.values.max(by: { $0.updatedAt < $1.updatedAt }) {
                // Migrate reports saved before the catalogue remembered its position.
                let next = ReviewScenario.all.firstIndex { $0.id == latest.scenario }.map {
                    ReviewScenario.all[min($0 + 1, ReviewScenario.all.count - 1)].id
                } ?? latest.scenario
                restore(.init(scenario: next, language: latest.language, appearance: latest.appearance, size: latest.size))
            }
        }
    }

    private func restore(_ position: Position) {
        if ReviewScenario.all.contains(where: { $0.id == position.scenario }) { selectedID = position.scenario }
        language = InterfaceLanguage(rawValue: position.language) ?? .russian
        appearance = ReviewAppearance(rawValue: position.appearance) ?? .light
        size = ReviewSize(rawValue: position.size) ?? .compact
    }

    private func savePosition() {
        do {
            let position = Position(scenario: selectedID, language: language.rawValue, appearance: appearance.rawValue, size: size.rawValue)
            try JSONEncoder().encode(position).write(to: positionURL, options: .atomic)
        } catch { persistenceError = "Не удалось сохранить место проверки: \(error.localizedDescription)" }
    }

    var scenario: ReviewScenario { ReviewScenario.all.first { $0.id == selectedID } ?? ReviewScenario.all[0] }
    var index: Int { ReviewScenario.all.firstIndex { $0.id == selectedID } ?? 0 }
    var recordKey: String { key(for: scenario.id) }
    func key(for id: String) -> String { "\(id)|\(language.rawValue)|\(appearance.rawValue)|\(size.rawValue)" }
    var currentRecord: ReviewRecord {
        report.records[recordKey] ?? .init(scenario: scenario.id, language: language.rawValue,
                                          appearance: appearance.rawValue, size: size.rawValue)
    }
    var reviewedCount: Int {
        ReviewScenario.all.filter { report.records[key(for: $0.id)]?.status == "passed" }.count
    }
    var problemCount: Int { report.records.values.filter { $0.status == "issue" }.count }

    func save(status: String? = nil, notes: String? = nil) {
        guard reportReadable else { return }
        var record = currentRecord
        if let status { record.status = status }
        if let notes { record.notes = notes }
        record.updatedAt = Date()
        savePosition()
        report.records[recordKey] = record
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = "Не удалось сохранить заметки: \(error.localizedDescription)" }
    }

    func move(_ offset: Int) {
        let target = min(max(0, index + offset), ReviewScenario.all.count - 1)
        select(ReviewScenario.all[target].id)
    }

    func connect(window: NSWindow, openWindow: @escaping (String) -> Void,
                 showDashboard: @escaping () -> Void, showMenu: @escaping () -> Void) {
        guard dashboard !== window else { return }
        dashboard = window
        print("REVIEW Attached to production dashboard scene")
        self.openWindow = openWindow
        self.presentDashboard = showDashboard
        self.showMenu = showMenu
        guard !connectedToAppRoot else { return }
        connectedToAppRoot = true
        Task { @MainActor in
            // Let AppRootView install the real menu bar and start the store first.
            try? await Task.sleep(for: .milliseconds(100))
            changePresentation()
            select(selectedID)
            await selectionTask?.value
            openWindow("manual-review")
            NSApp.activate(ignoringOtherApps: true)
            if CommandLine.arguments.contains("--review-self-check") || CommandLine.arguments.contains("--review-widget-check") || CommandLine.arguments.contains("--review-focus-check") {
                do {
                    if CommandLine.arguments.contains("--review-widget-check") {
                        try await WidgetChecks.run()
                        print("PASS Widget checks in common app")
                    } else if CommandLine.arguments.contains("--review-focus-check") {
                        try await WindowChecks.sidebarAppearance(self)
                        print("PASS Focus checks in common app")
                    } else {
                        try await ManualReviewChecks.run(self)
                        print("PASS Manual review: production App/Scene, toolbar, chat sheet, data lifecycle and reports")
                    }
                    cleanup()
                    exit(0)
                } catch {
                    WindowChromeChecks.saveFailure(self)
                    fputs("FAIL Manual review: \(error)\n", stderr)
                    cleanup()
                    exit(1)
                }
            }
        }
    }

    func select(_ id: String) {
        guard let scenario = ReviewScenario.all.first(where: { $0.id == id }) else { return }
        selectionTask?.cancel()
        selectedID = id
        savePosition()
        preparing = true
        selectionTask = Task { @MainActor in
            defer { if selectedID == id { preparing = false } }
            store.requestReviewChat(false)
            for _ in 0..<40 {
                if dashboard?.attachedSheet == nil { break }
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled else { return }
            chatKind = nil
            if case .transition = scenario.target { } else { lastTransition = nil }
            switch scenario.target {
            case let .dashboard(tab, fixture, option):
                await prepare(fixture, keepInspector: option == "inspector")
                guard !Task.isCancelled else { return }
                store.tab = tab
                switch option {
                case "expanded": store.sessionList.setExpanded(true)
                case "no-results": store.sessionList = .init(isExpanded: true, query: "no-matching-session")
                case "source": store.sourceFilter = "codex"
                case "yesterday": store.period = .yesterday; await store.selectPeriod()
                case "calendar":
                    await store.selectCustomDate(Date().addingTimeInterval(-3 * 86400))
                    store.budgetEnabled = true
                    _ = store.setBudgetAmount(100)
                case "budget": store.budgetEnabled = true; _ = store.setBudgetAmount(10)
                case "excluded": store.setModelIncluded(false, model: "gpt-6-astra")
                case "inspector": store.selectedSessionID = store.snapshot?.sessions.first?.id
                default: break
                }
                if fixture == .missing { await store.testCLI() }
                showDashboard()
            case let .transition(step):
                if lastTransition != step - 1 || step == 0 { await prepare(.normal) }
                guard !Task.isCancelled else { return }
                switch step {
                case 1: store.navigate(.settings)
                case 2: store.tab = .models
                case 4: await store.selectCustomDate(Date().addingTimeInterval(-86400))
                case 5: store.selectedSessionID = store.snapshot?.sessions.first?.id
                case 6: store.selectedSessionID = nil
                default: store.navigate(.overview)
                }
                lastTransition = step
                showDashboard()
            case let .chat(kind):
                // Reuse the existing inspector while switching chat fixtures, as a user does.
                // Closing/reopening the native inspector mid-dismissal can discard its new selection.
                await prepare(.normal, keepInspector: true)
                guard !Task.isCancelled else { return }
                chatKind = kind
                store.selectedSessionID = store.snapshot?.sessions.first?.id
                showDashboard()
                store.requestReviewChat(true)
                for _ in 0..<40 {
                    if dashboard?.attachedSheet != nil { break }
                    try? await Task.sleep(for: .milliseconds(50))
                    if Task.isCancelled { return }
                }
                guard !Task.isCancelled else { return }
                resizeDashboard()
            case let .menu(fixture, mode, budget):
                await prepare(fixture)
                guard !Task.isCancelled else { return }
                store.menuContent = mode
                store.budgetEnabled = budget
                _ = store.setBudgetAmount(10)
                showMenu?()
            case let .widgets(_, fixture):
                await prepare(fixture)
                guard !Task.isCancelled else { return }
                openWindow?("review-widgets")
            }
        }
    }

    private func prepare(_ fixture: ReviewFixture, keepInspector: Bool = false) async {
        refreshTask?.cancel()
        store.resetForManualReview()
        service.configure(fixture)
        if !keepInspector { store.selectedSessionID = nil }
        store.sourceFilter = ""
        store.sessionList = .init()
        store.period = .today
        store.tab = .overview
        store.budgetEnabled = false
        store.menuContent = .summary
        for model in store.excludedModels { store.setModelIncluded(true, model: model) }
        repository.configure(fixture, context: store.dataContext)
        refreshTask = Task { await store.refresh(reason: .startup) }
        // Held network responses leave the actual store in its actual loading state.
        if fixture == .loading || fixture == .refreshing {
            for _ in 0..<30 {
                if store.isRefreshing { break }
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { return }
            }
        } else { await refreshTask?.value }
    }

    func recoverSource() {
        if ["loading", "missing", "partial"].contains(chatKind ?? "") { chatKind = "normal" }
        service.releaseResponse()
        if !store.isRefreshing { refreshTask = Task { await store.refresh() } }
    }

    func changePresentation() {
        savePosition()
        let changedLanguage = store.interfaceLanguage != language
        store.interfaceLanguage = language
        NSApp.appearance = NSAppearance(named: appearance == .light ? .aqua : .darkAqua)
        for window in NSApp.windows { window.appearance = NSApp.appearance }
        resizeDashboard()
        if changedLanguage, case .chat = scenario.target { select(selectedID) }
    }

    func showCurrent() {
        if case .menu = scenario.target { showMenu?() }
        else if case .widgets = scenario.target { openWindow?("review-widgets") }
        else {
            showDashboard()
            if case .chat = scenario.target, dashboard?.attachedSheet == nil {
                store.requestReviewChat(true)
            }
        }
    }

    func showDashboard() {
        presentDashboard?()
        resizeDashboard()
    }

    private func resizeDashboard() {
        dashboard?.setContentSize(.init(width: max(size.width, store.selectedSessionID == nil ? 860 : 1160),
                                       height: size == .compact ? 620 : 760))
        dashboard?.attachedSheet?.setContentSize(.init(width: size == .compact ? 680 : size == .standard ? 900 : 1100,
                                                       height: size == .compact ? 640 : 760))
    }

    var transcriptServices: TranscriptServices {
        .init(load: { [weak self] _, _ in
            let kind = self?.chatKind ?? "normal"
            if kind == "loading" {
                while self?.chatKind == "loading" { try await Task.sleep(for: .milliseconds(200)) }
                try Task.checkCancellation()
            }
            try await Task.sleep(for: .milliseconds(120))
            if kind == "missing" { throw UsageError.processFailed(1, "Тестовый журнал не найден") }
            if kind == "empty" { return .init(events: []) }
            var transcript = TranscriptPreview.sample
            if kind == "partial" {
                transcript.usageUncertain = true
                for index in transcript.requests.indices {
                    transcript.requests[index].usage.costIsIncomplete = true
                    transcript.requests[index].priced = false
                }
            }
            if kind == "long" {
                transcript.events[1].text = String(repeating: "## Длинный ответ\n\nПроверка переноса строк, **выделения**, `кода` и прокрутки.\n\n", count: 180)
            }
            return transcript
        }, price: { [weak self] transcript, _, _, _ in
            if self?.chatKind == "partial" { throw UsageError.processFailed(1, "Не удалось определить все тарифы") }
            return transcript
        })
    }

    func cleanup() {
        selectionTask?.cancel()
        refreshTask?.cancel()
        store.resetForManualReview()
        service.configure(.normal)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

/// Observe the existing SwiftUI scene window; never create a replacement product window.
struct ReviewWindowConnection: NSViewRepresentable {
    var connect: (NSWindow) -> Void
    func makeNSView(context: Context) -> WindowObserver { WindowObserver(connect: connect) }
    func updateNSView(_ view: WindowObserver, context: Context) { view.connect = connect; view.reportWindow() }
    final class WindowObserver: NSView {
        var connect: (NSWindow) -> Void
        init(connect: @escaping (NSWindow) -> Void) { self.connect = connect; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reportWindow() }
        func reportWindow() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.connect(window)
            }
        }
    }
}

struct ReviewWidgetsView: View {
    @ObservedObject var review: ManualReviewController
    @ObservedObject var store: UsageStore
    var variant: UsageWidgetVariant {
        if case let .widgets(variant, _) = review.scenario.target { return variant }
        return UsageWidgetVariant.allCases[0]
    }
    var fixture: ReviewFixture {
        if case let .widgets(_, fixture) = review.scenario.target { return fixture }
        return .normal
    }
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 24) {
                Text("\(variant.title) · \(fixture.title)").font(.title2.bold())
                Text("Содержимое WidgetKit · три размера. Системную подложку и размещение проверяй на рабочем столе.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 24) {
                    ForEach([WidgetFamily.systemSmall, .systemMedium, .systemLarge], id: \.self) { family in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(family == .systemSmall ? "Small" : family == .systemMedium ? "Medium" : "Large").font(.headline)
                            WidgetPreviewCard(family: family, variant: variant, history: store.history,
                                              snapshot: store.snapshot, status: .init(attemptedAt: Date(), message: fixture.error?.errorDescription,
                                                                                     refreshMinutes: 15),
                                              storageUnavailable: fixture == .storage)
                                .allowsHitTesting(false)
                        }
                    }
                }
                Text("Ссылки отключены только в этой галерее, чтобы не открывать рабочую копию приложения.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.background(Color(nsColor: .underPageBackgroundColor))
    }
}
