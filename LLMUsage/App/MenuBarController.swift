import AppKit
import Combine
import SwiftUI

/// This controller outlives the dashboard window so the status item remains usable.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let openRoute: (UsageRoute) -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var subscriptions = Set<AnyCancellable>()
    private var keyMonitor: Any?

    convenience init(store: UsageStore, openRoute: @escaping (UsageRoute) -> Void) {
        self.init(store: store, statusItem: NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength),
                  popover: NSPopover(), openRoute: openRoute)
    }

    init(store: UsageStore, statusItem: NSStatusItem, popover: NSPopover, openRoute: @escaping (UsageRoute) -> Void) {
        self.store = store
        self.statusItem = statusItem
        self.popover = popover
        self.openRoute = openRoute
        super.init()

        statusItem.autosaveName = "LLMUsageStatusItem"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("LLM Usage")
        }

        let host = NSHostingController(rootView: MenuBarUsageView(
            store: store,
            openRoute: { [weak self] route in self?.open(route) },
            close: { [weak self] in self?.popover.performClose(nil) }
        ))
        host.sizingOptions = [.preferredContentSize]
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize

        store.$todaySnapshot.combineLatest(store.$compactMenuBar, store.$interfaceLanguage)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot, compact, _ in
                self?.updateLabel(snapshot: snapshot, compact: compact)
            }
            .store(in: &subscriptions)
        updateLabel(snapshot: store.todaySnapshot, compact: store.compactMenuBar)
    }

    private func updateLabel(snapshot: UsageSnapshot?, compact: Bool) {
        // Keep the status item's geometry stable while it anchors an open popover.
        // In a fullscreen Space, forcing positioningRect or resizing the button
        // during refresh can make AppKit reposition the popover at the screen edge.
        // The popover's observed content still updates immediately.
        guard !popover.isShown else { return }
        guard let button = statusItem.button else { return }
        button.image = MenuBarBadge.image(usage: snapshot?.totals, compact: compact, day: snapshot?.day)
        button.toolTip = MenuBarBadge.accessibilityLabel(snapshot?.totals, day: snapshot?.day)
        button.setAccessibilityLabel(MenuBarBadge.accessibilityLabel(snapshot?.totals, day: snapshot?.day))
    }

    @objc private func handleStatusItemClick() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        popover.performClose(nil)

        // Rebuild on demand so a language change is reflected immediately.
        let menu = NSMenu()
        let overview = menu.addItem(withTitle: L10n.text("Открыть обзор"),
                                    action: #selector(openOverview), keyEquivalent: "o")
        overview.target = self
        let usage = menu.addItem(withTitle: L10n.text("Показать статистику в строке меню"),
                                 action: #selector(showPopover), keyEquivalent: "")
        usage.target = self
        let settings = menu.addItem(withTitle: L10n.text("Настройки…"),
                                    action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let updates = menu.addItem(withTitle: L10n.text("Проверить обновления…"),
                                   action: #selector(checkUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: L10n.text("Завершить LLM Usage"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

        // Attach only while tracking; a persistent menu would consume left clicks too.
        statusItem.menu = menu
        defer { statusItem.menu = nil }
        button.performClick(nil)
    }

    @objc private func checkUpdates() { AppUpdateCoordinator.shared.check() }

    @objc private func openOverview() { open(.overview) }
    @objc private func openSettings() { open(.settings) }

    @objc
    func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        popover.contentViewController?.view.window?.makeKey()
        installKeyMonitor()
    }

    private func open(_ route: UsageRoute) {
        popover.performClose(nil)
        openRoute(route)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        updateLabel(snapshot: store.todaySnapshot, compact: store.compactMenuBar)
        removeKeyMonitor()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        // An independent NSHostingController has no SwiftUI Scene command bridge.
        // Scope shortcuts to this open popover, leaving dashboard shortcuts intact.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown,
                  event.window === self.popover.contentViewController?.view.window else { return event }
            if event.keyCode == 53 {
                self.popover.performClose(nil)
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers == .command else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o": self.open(.overview)
            case ",": self.open(.settings)
            case "r":
                if !self.store.isDemo, !self.store.isRefreshing {
                    Task { await self.store.refresh() }
                }
            case "q": NSApp.terminate(nil)
            default: return event
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func tearDown() {
        popover.close()
        removeKeyMonitor()
        subscriptions.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
