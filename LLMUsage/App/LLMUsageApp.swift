import SwiftUI
import AppKit

@MainActor
final class UsageAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let dashboard = DashboardWindowCoordinator()
    private var menuBarController: MenuBarController?
    private let menuLocalization = AppMenuLocalization()
    private let iconAppearance = AppIconAppearance()

    func applicationDidFinishLaunching(_ notification: Notification) {
        iconAppearance.start(application: .shared)
        if AppLaunchReceipt.requested {
            setbuf(stdout, nil)
            print("APP Application did finish launching")
        }
        if ManualReviewController.active == nil && !CommandLine.arguments.contains("--demo") {
            Task { await WidgetExtensionLifecycle.reconcile() }
        }
    }

    func installMenuBar(store: UsageStore, openRoute: @escaping (UsageRoute) -> Void) {
        iconAppearance.start(application: .shared)
        guard menuBarController == nil else { return }
        menuBarController = MenuBarController(store: store, openRoute: openRoute)
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.tearDown()
        ManualReviewController.active?.cleanup()
    }

    func showMenuBarUsage() { menuBarController?.showPopover() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .openUsageDashboard, object: nil) }
        return true
    }
}

@main
struct LLMUsageApp: App {
    @NSApplicationDelegateAdaptor(UsageAppDelegate.self) private var appDelegate
    @StateObject private var store = makeStore()

    private static func makeStore() -> UsageStore {
        if let review = ManualReviewController.active { return review.store }
        return UsageStore(demo: ProcessInfo.processInfo.arguments.contains("--demo")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
    }

    init() {
        if AppLaunchReceipt.requested { fputs("APP Scene initialized\n", stderr) }
    }

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("LLM Usage", id: "dashboard") {
            AppRootView(store: store, appDelegate: appDelegate)
                .windowFullScreenBehavior(.enabled)
        }
        .defaultSize(width: 1080, height: 760)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        // The dashboard is a primary window even though the app lives in the menu bar.
        .windowManagerRole(.principal)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenUsageButton(store: store, dashboard: appDelegate.dashboard, route: .settings, title: L10n.text("Настройки…")).keyboardShortcut(",")
            }
            CommandGroup(after: .appSettings) {
                Button(L10n.text("Проверить обновления…")) { AppUpdateCoordinator.shared.check() }
                    .disabled(store.isDemo || store.isManualReview)
            }
            CommandGroup(after: .appSettings) {
                if ManualReviewController.active != nil {
                    Button("Каталог проверки UI") { openWindow(id: "manual-review") }.keyboardShortcut("1")
                }
            }
            CommandGroup(after: .windowArrangement) {
                OpenUsageButton(store: store, dashboard: appDelegate.dashboard, route: .overview, title: L10n.text("Открыть обзор"))
                Button(L10n.text("Показать статистику в строке меню")) { appDelegate.showMenuBarUsage() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }
        Window("Каталог проверки — LLM Usage", id: "manual-review") {
            if let review = ManualReviewController.active { ManualReviewPanel(review: review) }
        }
        .defaultSize(width: 500, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()
        Window("Содержимое виджетов — LLM Usage", id: "review-widgets") {
            if let review = ManualReviewController.active { ReviewWidgetsView(review: review, store: store) }
        }
        .defaultSize(width: 960, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

struct AppRootView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var updates = AppUpdateCoordinator.shared
    var appDelegate: UsageAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DashboardView(store: store, dashboardWindow: appDelegate.dashboard)
            .sheet(isPresented: $updates.presentsSetup) { AppMaintenanceSetup(updates: updates) }
            .environment(\.locale, store.interfaceLanguage.locale)
            .id(store.interfaceLanguage)
            .background { DashboardWindowConnection(coordinator: appDelegate.dashboard) }
            .task {
                appDelegate.installMenuBar(store: store) { [store, openWindow] route in
                    store.navigate(route)
                    appDelegate.dashboard.show { openWindow(id: "dashboard") }
                }
                if store.isDemo || store.isManualReview { store.start() }
                else {
                    updates.start(store: store) {
                        store.navigate(.settings)
                        appDelegate.dashboard.show { openWindow(id: "dashboard") }
                    }
                }
                if let review = ManualReviewController.active {
                    print("REVIEW Production root appeared; windows: \(NSApp.windows.map { $0.identifier?.rawValue ?? $0.title })")
                    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "dashboard" }) {
                        review.connect(window: window, openWindow: { openWindow(id: $0) },
                                       showDashboard: { appDelegate.dashboard.show { openWindow(id: "dashboard") } },
                                       showMenu: { appDelegate.showMenuBarUsage() })
                    }
                }
            }
            .environment(\.transcriptServices, ManualReviewController.active?.transcriptServices ?? .live)
            .background {
                if let review = ManualReviewController.active {
                    ReviewWindowConnection { window in
                        review.connect(window: window, openWindow: { openWindow(id: $0) },
                                       showDashboard: { appDelegate.dashboard.show { openWindow(id: "dashboard") } },
                                       showMenu: { appDelegate.showMenuBarUsage() })
                    }
                }
            }
            .onChange(of: store.interfaceLanguage) { _, language in
                ManualReviewController.active?.language = language
                DispatchQueue.main.async { AppMenuLocalization.update() }
            }
            .onAppear { DispatchQueue.main.async { AppMenuLocalization.update() } }
            .onOpenURL { url in
                guard let route = UsageRoute(url: url) else { return }
                store.navigate(route)
                appDelegate.dashboard.show { openWindow(id: "dashboard") }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUsageDashboard)) { _ in
                appDelegate.dashboard.show { openWindow(id: "dashboard") }
            }
    }
}

struct OpenUsageButton: View {
    @ObservedObject var store: UsageStore
    var dashboard: DashboardWindowCoordinator
    var route: UsageRoute
    var title: String
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(title) {
            store.navigate(route)
            dashboard.show { openWindow(id: "dashboard") }
        }
    }
}
