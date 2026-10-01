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
        func sidebarTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.effectiveStyle == .sourceList { return table }
            return view.subviews.lazy.compactMap { sidebarTable(in: $0) }.first
        }
        func arrowKey(_ keyCode: UInt16, characters: String, in table: NSTableView) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: table.window!.windowNumber,
                                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: false, keyCode: keyCode)!
            table.keyDown(with: event)
            settle()
        }
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
            // Geometry checks resize immediately; do not race native inspector animations.
            let host = NSHostingView(rootView: DashboardView(store: store).transaction { $0.disablesAnimations = true })
            let window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 860, height: 560),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            settle()
            let normal = window.contentMinSize.width
            try require(normal >= 860 && normal < 1160, "Dashboard cannot use its normal minimum width")
            guard let sidebar = sidebarTable(in: host) else {
                throw NSError(domain: "WindowChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing native sidebar"])
            }
            for tab in [DashboardTab.overview, .sessions, .models, .settings] {
                store.tab = tab
                for width: CGFloat in [1080, 860, 1000, 860] {
                    try resizeAndCheck(window, host: host, width: width)
                    try require(sidebar.selectionHighlightStyle == .none, "Native accent fill returned after navigation or resize")
                }
                let expectedRow = [DashboardTab.overview, .sessions, .models].firstIndex(of: tab) ?? -1
                try require(sidebar.selectedRow == expectedRow, "Sidebar selection does not follow the current tab")
            }
            store.tab = .overview
            settle()
            arrowKey(125, characters: "\u{F701}", in: sidebar)
            try require(store.tab == .sessions, "Down arrow no longer selects Sessions")
            arrowKey(126, characters: "\u{F700}", in: sidebar)
            try require(store.tab == .overview, "Up arrow no longer selects Overview")
            sidebar.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            settle()
            try require(store.tab == .models, "Native row selection no longer opens Models")
            print("PASS Sidebar keeps native selection and keyboard navigation without an accent-filled highlight")
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

        for language in [InterfaceLanguage.english, .russian] {
            store.interfaceLanguage = language
            let transcript = TranscriptPreview.sample
            var session = store.snapshot!.sessions[0]
            session.usage = transcript.requests.reduce(.zero) { $0 + $1.usage }
            let configurations = TranscriptAnalysisTab.allCases.map { ($0, TranscriptEventFilter.all) }
                + [(TranscriptAnalysisTab.chat, .tools), (.chat, .errors)]
            for (tab, filter) in configurations {
                let chat = SessionChatView(session: session, timezone: "UTC", isDemo: true, preview: transcript,
                                           day: UsageDay(date: transcript.requests[0].timestamp!), initialTab: tab,
                                           initialFilter: filter, initiallyExpandedTools: filter == .all ? [] : ["3", "7"])
                let host = NSHostingView(rootView: chat)
                let window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 680, height: 640),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFront(nil)
                for width: CGFloat in [680, 900, 680] {
                    window.setContentSize(.init(width: width, height: 640))
                    settle(); host.layoutSubtreeIfNeeded(); settle()
                    try require(try checkBounds(host, host: host) > 0, "Chat check did not inspect scroll/search views")
                    try require(abs(host.bounds.width - width) <= 1 && window.contentMinSize.width <= 681,
                                "Chat cannot fit \(width)px (actual: \(host.bounds.width), minimum: \(window.contentMinSize.width))")
                }
                window.orderOut(nil)
                window.contentView = nil
            }
        }
        print("PASS Chat, costliest requests, tools and expanded debug filters fit 680/900px in both languages")

        store.tab = .overview
        for dark in [false, true] {
            for active in [true, false] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let host = NSHostingView(rootView: DashboardView(store: store).sidebarPreview
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.appearsActive, active)
                    .accentColor(.blue)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 220, height: 560),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = appearance
                window.contentView = host
                window.orderFront(nil)
                host.layoutSubtreeIfNeeded()
                settle()
                guard let table = sidebarTable(in: host),
                      let row = table.rowView(atRow: table.selectedRow, makeIfNecessary: true),
                      let bitmap = row.bitmapImageRepForCachingDisplay(in: row.bounds) else {
                    throw NSError(domain: "WindowChecks", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot render selected sidebar row"])
                }
                row.cacheDisplay(in: row.bounds, to: bitmap)
                var accentPixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.3 else { continue }
                        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                        if channels.max()! - channels.min()! > 0.15 { accentPixels += 1 }
                    }
                }
                try require(active ? accentPixels > 10 : accentPixels == 0,
                            "Sidebar text/icon did not follow active state (dark: \(dark), active: \(active), colored pixels: \(accentPixels))")
                // Sample the empty trailing part of the row, away from text and icons.
                let fill = bitmap.colorAt(x: bitmap.pixelsWide - 28, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
                let channels = [fill.redComponent, fill.greenComponent, fill.blueComponent]
                try require(fill.alphaComponent > 0.01 && channels.max()! - channels.min()! < 0.03,
                            "Sidebar selection background is missing or not neutral")
                window.orderOut(nil)
                window.contentView = nil
            }
        }
        print("PASS Sidebar uses neutral selection and adapts text/icons in light/dark and active/inactive states")

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
