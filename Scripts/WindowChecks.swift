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
        func checkBounds(_ view: NSView, host: NSView) throws -> Int {
            guard !view.isHiddenOrHasHiddenAncestor else { return 0 }
            var checked = 0
            if view is NSSplitView || view is NSScrollView || view is NSSearchField {
                let rect = view.convert(view.bounds, to: host)
                try require(rect.minX >= -1 && rect.maxX <= host.bounds.width + 1,
                            "\(type(of: view)) escapes window: \(rect), window width \(host.bounds.width)")
                checked += 1
            }
            for child in view.subviews { checked += try checkBounds(child, host: host) }
            return checked
        }
        func resizeAndCheck(_ window: NSWindow, host: NSView, width: CGFloat) throws {
            window.setContentSize(NSSize(width: width, height: 620))
            settle()
            host.layoutSubtreeIfNeeded()
            settle()
            try require(try checkBounds(host, host: host) >= 3, "Layout check did not reach the native columns")
        }

        for language in [InterfaceLanguage.english, .russian] {
            print("Checking window language: \(language.rawValue)")
            store.interfaceLanguage = language
            let host = NSHostingView(rootView: DashboardView(store: store))
            let window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 860, height: 560),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            settle()
            let normal = window.contentMinSize.width
            try require(normal >= 860 && normal < 1160, "Dashboard cannot use its normal minimum width")
            for tab in [DashboardTab.overview, .sessions, .models, .settings] {
                store.tab = tab
                for width: CGFloat in [1080, 860, 1000, 860] {
                    try resizeAndCheck(window, host: host, width: width)
                }
            }
            store.tab = .sessions
            store.selectedSessionID = store.snapshot!.sessions[0].id
            settle()
            host.layoutSubtreeIfNeeded()
            let inspected = window.contentMinSize.width
            try require(inspected >= 1160 && inspected > normal, "Inspector did not reserve room for sidebar and content")
            try resizeAndCheck(window, host: host, width: 1160)
            store.selectedSessionID = nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            window.setContentSize(NSSize(width: 860, height: 560))
            host.layoutSubtreeIfNeeded()
            settle()
            try require(window.contentMinSize.width == normal, "Closing inspector did not release the minimum width")
            try resizeAndCheck(window, host: host, width: 860)
            print("PASS minimum width: \(normal) → \(inspected) → \(window.contentMinSize.width)")
            print("PASS Native split views, scroll views and search remain inside resized window on every tab")
            window.orderOut(nil)
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
