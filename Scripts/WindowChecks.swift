import AppKit
import SwiftUI

/// Test the shipping view constraints and status-item lifecycle in an isolated process.
@MainActor private final class TrackingPopover: NSPopover {
    var presented = false
    var positioningChanges = 0
    override var isShown: Bool { presented }
    override var positioningRect: NSRect {
        get { super.positioningRect }
        set { positioningChanges += 1; super.positioningRect = newValue }
    }
}

@main
struct WindowChecks {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "LLMUsageWindowChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults, demo: true)
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "WindowChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

        for language in [InterfaceLanguage.english, .russian] {
            print("Checking window language: \(language.rawValue)")
            store.interfaceLanguage = language
            let host = NSHostingView(rootView: DashboardView(store: store))
            let window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 860, height: 560),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            settle()
            let normal = window.contentMinSize.width
            try require(normal >= 860 && normal < 1160, "Dashboard cannot use its normal minimum width")
            store.selectedSessionID = store.snapshot!.sessions[0].id
            settle()
            host.layoutSubtreeIfNeeded()
            let inspected = window.contentMinSize.width
            try require(inspected >= 1160 && inspected > normal, "Inspector did not reserve room for sidebar and content")
            store.selectedSessionID = nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            window.setContentSize(NSSize(width: 860, height: 560))
            host.layoutSubtreeIfNeeded()
            settle()
            try require(window.contentMinSize.width == normal, "Closing inspector did not release the minimum width")
            print("PASS minimum width: \(normal) → \(inspected) → \(window.contentMinSize.width)")
            window.contentView = nil
        }
        print("PASS Dashboard minimum width reserves sidebar, content and inspector in both languages")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let popover = TrackingPopover()
        let controller = MenuBarController(store: store, statusItem: item, popover: popover, openRoute: { _ in })
        defer { controller.tearDown() }
        settle()
        let initialImage = item.button!.image
        let initialRectChanges = popover.positioningChanges
        popover.presented = true
        store.setModelIncluded(false, model: "gpt-6-astra")
        store.compactMenuBar.toggle()
        store.interfaceLanguage = .english
        settle()
        try require(item.button!.image === initialImage, "An open popover's status item resized during a data/preference update")
        try require(popover.positioningChanges == initialRectChanges, "Refresh forced a new popover anchor")
        popover.presented = false
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popover))
        try require(item.button!.image !== initialImage, "Closing the popover failed to publish the latest badge")
        try require(item.button!.toolTip == MenuBarBadge.accessibilityLabel(store.todaySnapshot?.totals, day: store.todaySnapshot?.day), "Closed badge shows stale totals")
        print("PASS Popover updates preserve anchor geometry and publish the latest badge on close")
    }
}
