import AppKit

/// AppKit owns the menus and standard actions; only their visible titles change.
/// System-wide language defaults and Services supplied by other apps are untouched.
@MainActor
final class AppMenuLocalization {
    private var observers: [NSObjectProtocol] = []
    private var updateScheduled = false
    private static var isUpdating = false

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.update() }
        })
        // SwiftUI may rebuild its menus after any observed state change, not only
        // a language change. Wait until that batch of native mutations finishes.
        for notification in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didRemoveItemNotification] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleUpdate() }
            })
        }
        scheduleUpdate()
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    private func scheduleUpdate() {
        guard !Self.isUpdating, !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            Self.update()
        }
    }

    static func update() {
        guard !isUpdating, let menu = NSApp.mainMenu else { return }
        isUpdating = true
        defer { isUpdating = false }
        translate(menu)
    }

    private static func translate(_ menu: NSMenu) {
        for item in menu.items {
            let title = item.title
            // Only exact known UI labels are candidates; document names and paths are not.
            if let pair = L10n.catalog.first(where: { $0.key == title || $0.value.ru == title || $0.value.en == title }) {
                let translated = L10n.key(pair.key)
                if item.title != translated { item.title = translated }
            }
            if let submenu = item.submenu, item.title != L10n.key("Services") {
                if submenu.title != item.title { submenu.title = item.title }
                translate(submenu)
            }
        }
    }
}
