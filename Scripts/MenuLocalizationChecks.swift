import AppKit

@MainActor private final class MenuMutationCounter { var count = 0 }

/// Runs with the AppKit run loop, without launching the shipping app or opening UI.
@main
struct MenuLocalizationChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let originalLanguage = L10n.preference
        let originalMenu = app.mainMenu
        defer { app.mainMenu = originalMenu; L10n.preference = originalLanguage }
        let menu = NSMenu()
        menu.autoenablesItems = false
        app.mainMenu = menu
        let localizer = AppMenuLocalization()
        L10n.preference = .english

        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.06)) }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "MenuLocalizationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func append(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            menu.addItem(item)
            return item
        }

        let edit = append("Правка")
        let view = append("Вид")
        let window = append("Окно")
        let help = append("Справка")
        let overview = append("Открыть обзор")
        settle()
        try require([edit.title, view.title, window.title, help.title] == ["Edit", "View", "Window", "Help"], "Added menu titles did not use English")
        try require(overview.title == "Open overview", "Dashboard command has an ambiguous English translation")
        // Models a SwiftUI command-tree update caused by an unrelated preference.
        edit.title = "Правка"; view.title = "Вид"; window.title = "Окно"; help.title = "Справка"
        settle()
        try require([edit.title, view.title, window.title, help.title] == ["Edit", "View", "Window", "Help"], "Changed menu titles reverted to the system language")
        try require(view.submenu?.title == "View", "Submenu title did not update")

        menu.removeItem(help)
        let replacement = append("Справка")
        settle()
        try require(replacement.title == "Help", "Replacement menu was not localized")
        let custom = append("session-Исходный.log")
        let services = append("Services")
        services.submenu?.addItem(withTitle: "Правка", action: nil, keyEquivalent: "")
        settle()
        try require(custom.title == "session-Исходный.log" && services.submenu?.items.first?.title == "Правка", "External names or Services were translated")

        let mutations = MenuMutationCounter()
        let token = NotificationCenter.default.addObserver(forName: NSMenu.didChangeItemNotification,
                                                           object: nil, queue: .main) { _ in MainActor.assumeIsolated { mutations.count += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }
        AppMenuLocalization.update()
        settle()
        try require(mutations.count == 0, "Already-localized menu mutated or notification update loop remained active")
        L10n.preference = .russian
        AppMenuLocalization.update()
        settle()
        try require(edit.title == "Правка" && view.title == "Вид", "Explicit language change stopped working")
        // A shared Russian title must resolve to one English title after a menu
        // rebuild or language round trip, independently of Dictionary ordering.
        for _ in 0..<3 {
            L10n.preference = .english
            AppMenuLocalization.update()
            settle()
            try require(overview.title == "Open overview", "Dashboard command changed during language round trip")
            overview.title = "Открыть обзор"
            settle()
            try require(overview.title == "Open overview", "Rebuilt dashboard command used a different translation")
            L10n.preference = .russian
            AppMenuLocalization.update()
            settle()
            try require(overview.title == "Открыть обзор", "Dashboard command did not return to Russian")
        }
        withExtendedLifetime(localizer) {}
        print("PASS AppKit menu add/change/replacement, preserved Services, idempotence and language switch")
    }
}
