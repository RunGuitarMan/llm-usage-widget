import SwiftUI
import AppKit

@MainActor
final class UsageAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private let menuLocalization = AppMenuLocalization()
    private let iconAppearance = AppIconAppearance()

    func applicationDidFinishLaunching(_ notification: Notification) {
        iconAppearance.start(application: .shared)
    }

    func installMenuBar(store: UsageStore, openRoute: @escaping (UsageRoute) -> Void) {
        iconAppearance.start(application: .shared)
        guard menuBarController == nil else { return }
        menuBarController = MenuBarController(store: store, openRoute: openRoute)
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.tearDown()
    }

    func showMenuBarUsage() { menuBarController?.showPopover() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .openUsageDashboard, object: nil) }
        return true
    }
}

extension Notification.Name {
    static let openUsageDashboard = Notification.Name("OpenUsageDashboard")
}

@main
struct LLMUsageApp: App {
    @NSApplicationDelegateAdaptor(UsageAppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore(demo: ProcessInfo.processInfo.arguments.contains("--demo")
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)

    var body: some Scene {
        Window("LLM Usage", id: "dashboard") {
            AppRootView(store: store, appDelegate: appDelegate)
        }
        .defaultSize(width: 1080, height: 760)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenUsageButton(store: store, route: .settings, title: L10n.text("Настройки…")).keyboardShortcut(",")
            }
            CommandGroup(after: .windowArrangement) {
                OpenUsageButton(store: store, route: .overview, title: L10n.text("Открыть Dashboard"))
                Button(L10n.text("Показать статистику в строке меню")) { appDelegate.showMenuBarUsage() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }
    }
}

struct AppRootView: View {
    @ObservedObject var store: UsageStore
    var appDelegate: UsageAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DashboardView(store: store)
            .environment(\.locale, store.interfaceLanguage.locale)
            .id(store.interfaceLanguage)
            .task {
                appDelegate.installMenuBar(store: store) { [store, openWindow] route in
                    store.navigate(route)
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                store.start()
            }
            .onChange(of: store.interfaceLanguage) { _, _ in
                DispatchQueue.main.async { AppMenuLocalization.update() }
            }
            .onAppear { DispatchQueue.main.async { AppMenuLocalization.update() } }
            .onOpenURL { url in
                guard let route = UsageRoute(url: url) else { return }
                store.navigate(route)
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUsageDashboard)) { _ in
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

struct OpenUsageButton: View {
    @ObservedObject var store: UsageStore
    var route: UsageRoute
    var title: String
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(title) {
            store.navigate(route)
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
