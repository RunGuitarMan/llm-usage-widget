import AppKit
import Combine
import SwiftUI

/// AppKit supplies a single native popover surface, including its arrow and corners.
/// This controller outlives the dashboard window so the status item remains usable.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let openRoute: (UsageRoute) -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()
    private var keyMonitor: Any?

    init(store: UsageStore, openRoute: @escaping (UsageRoute) -> Void) {
        self.store = store
        self.openRoute = openRoute
        super.init()

        statusItem.autosaveName = "LLMUsageStatusItem"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
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

        store.$todaySnapshot.combineLatest(store.$compactMenuBar, store.$interfaceLanguage, store.$state)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot, compact, _, _ in
                self?.updateLabel(snapshot: snapshot, compact: compact)
            }
            .store(in: &subscriptions)
        updateLabel(snapshot: store.todaySnapshot, compact: store.compactMenuBar)
    }

    private func updateLabel(snapshot: UsageSnapshot?, compact: Bool) {
        guard let button = statusItem.button else { return }
        button.image = MenuBarBadge.image(usage: snapshot?.totals, compact: compact, day: snapshot?.day)
        button.toolTip = MenuBarBadge.accessibilityLabel(snapshot?.totals, day: snapshot?.day)
        button.setAccessibilityLabel(MenuBarBadge.accessibilityLabel(snapshot?.totals, day: snapshot?.day))
        if popover.isShown { popover.positioningRect = button.bounds }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

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
