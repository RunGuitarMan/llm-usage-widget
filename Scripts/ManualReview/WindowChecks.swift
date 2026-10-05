#if MANUAL_REVIEW
import AppKit
import SwiftUI

@MainActor enum WindowChecks {
    static func run(_ review: ManualReviewController) async throws {
        guard let window = review.dashboard else { try ReviewCheck.require(false, "Missing production dashboard"); return }
        let store = review.store
        for provider in [ModelProvider.anthropic, .openai, .google] {
            try ReviewCheck.require(ProviderLogo.images[provider]?.isValid == true, "Missing bundled provider logo: \(provider)")
        }
        for language in [InterfaceLanguage.english, .russian] {
            review.language = language
            review.changePresentation()
            try await ReviewCheck.select("overview", in: review)
            guard let host = window.contentView, let sidebar = ReviewCheck.sidebar(in: host) else {
                try ReviewCheck.require(false, "Missing production sidebar"); return
            }
            let normal = window.contentMinSize.width
            try ReviewCheck.require(normal >= 860 && normal < 1160, "Dashboard lost normal minimum width")
            for tab in [DashboardTab.overview, .models, .settings] {
                store.tab = tab
                for width: CGFloat in [1080, 860, 1000, 860] {
                    try await ReviewCheck.resize(window, width: width)
                    try ReviewCheck.toolbar(review)
                    try ReviewCheck.require(sidebar.selectionHighlightStyle == .none, "Native accent fill returned")
                }
                let expected = [DashboardTab.overview, .models].firstIndex(of: tab) ?? -1
                try ReviewCheck.require(sidebar.selectedRow == expected, "Sidebar selection does not follow tab")
            }
            store.tab = .overview
            try await ReviewCheck.settle()
            func arrow(_ key: UInt16, _ characters: String) async throws {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                            isARepeat: false, keyCode: key)!
                sidebar.keyDown(with: event)
                try await ReviewCheck.settle()
            }
            try await arrow(125, "\u{F701}")
            try ReviewCheck.require(store.tab == .models, "Down arrow no longer selects Models")
            try await arrow(126, "\u{F700}")
            try ReviewCheck.require(store.tab == .overview, "Up arrow no longer selects Statistics")
            sidebar.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            try await ReviewCheck.settle()
            try ReviewCheck.require(store.tab == .models, "Native row selection no longer opens Models")
            for _ in 0..<3 {
                for period in [DataPeriod.custom, .yesterday, .today] {
                    store.period = period
                    for tab in [DashboardTab.settings, .overview, .models] {
                        store.tab = tab
                        try await ReviewCheck.settle()
                        try await ReviewCheck.waitForToolbar(review)
                    }
                }
            }
            print("PASS Production toolbar stays unique and trailing; sidebar selection/keyboard navigation in \(language.rawValue)")
            store.tab = .overview
            store.sessionList.setExpanded(false)
            try await ReviewCheck.settle()
            let compactScrolls = Set(ReviewCheck.views(NSScrollView.self, in: host).map(ObjectIdentifier.init))
            try ReviewCheck.require(compactScrolls.count == 2, "Statistics should scroll only sidebar and main content")
            for expanded in [true, false, true] {
                store.sessionList.setExpanded(expanded)
                try await ReviewCheck.settle()
                try ReviewCheck.require(compactScrolls == Set(ReviewCheck.views(NSScrollView.self, in: host).map(ObjectIdentifier.init)),
                                        "Session expansion recreated or added a scroll view")
            }
            for width: CGFloat in [860, 1080] { try await ReviewCheck.resize(window, width: width) }
            try ReviewCheck.require(ReviewCheck.views(NSSearchField.self, in: host).first?.isEnabled == true,
                                    "Expanded Statistics lost its search field")
            store.sessionList.setExpanded(false)
            try await ReviewCheck.settle()
            try ReviewCheck.require(ReviewCheck.views(NSSearchField.self, in: host).first?.isEnabled == false,
                                    "Collapsed search can accept hidden input")
            store.sessionList.setExpanded(true)
            store.selectedSessionID = store.snapshot!.sessions[0].id
            try await ReviewCheck.wait("Inspector did not reserve its minimum width") { window.contentMinSize.width >= 1160 }
            try await ReviewCheck.resize(window, width: 1160)
            store.selectedSessionID = nil
            try await ReviewCheck.wait("Closing inspector did not release its minimum width") { window.contentMinSize.width == normal }
            try await ReviewCheck.resize(window, width: 860)
            try ReviewCheck.require(review.dashboard === window, "Checks replaced the production window")
            print("PASS Production viewport/search/inspector geometry in \(language.rawValue)")

            for scenario in ["chat-normal", "chat-expensive", "chat-analytics", "chat-tools", "chat-errors"] {
                try await ReviewCheck.select(scenario, in: review)
                guard let sheet = window.attachedSheet else { try ReviewCheck.require(false, "Chat bypassed production sheet"); return }
                for width: CGFloat in [680, 900, 680] {
                    try await ReviewCheck.resize(sheet, width: width, height: 640)
                    try ReviewCheck.require(sheet.contentMinSize.width <= 681, "Chat minimum width grew")
                }
            }
            print("PASS Production chat/analytics/tools/error sheets fit 680/900px in \(language.rawValue)")
        }
        try await ReviewCheck.select("overview", in: review)
        try await sidebarAppearance(review)
        try await ComponentChecks.run(store: store)
    }

    private static func sidebarAppearance(_ review: ManualReviewController) async throws {
        let window = review.dashboard!
        guard let catalogue = review.panel else { try ReviewCheck.require(false, "Missing review catalogue window"); return }
        for appearance in [ReviewAppearance.light, .dark] {
            review.appearance = appearance
            review.changePresentation()
            for active in [true, false] {
                // Switch between the two real scenes, without depending on another app's focus.
                (active ? window : catalogue).makeKeyAndOrderFront(nil)
                try await ReviewCheck.wait("Dashboard key-window state did not change: active=\(active)") {
                    window.isKeyWindow == active
                }
                try await ReviewCheck.settle()
                guard let host = window.contentView, let table = ReviewCheck.sidebar(in: host),
                      let row = table.rowView(atRow: table.selectedRow, makeIfNecessary: true),
                      let bitmap = row.bitmapImageRepForCachingDisplay(in: row.bounds) else {
                    try ReviewCheck.require(false, "Cannot render production sidebar selection"); return
                }
                row.cacheDisplay(in: row.bounds, to: bitmap)
                var accentPixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.3 else { continue }
                        let c = [color.redComponent, color.greenComponent, color.blueComponent]
                        if c.max()! - c.min()! > 0.15 { accentPixels += 1 }
                    }
                }
                try ReviewCheck.require(active ? accentPixels > 10 : accentPixels == 0,
                                        "Sidebar did not follow active state: \(appearance), active=\(active), pixels=\(accentPixels)")
                let fill = bitmap.colorAt(x: bitmap.pixelsWide - 28, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
                let c = [fill.redComponent, fill.greenComponent, fill.blueComponent]
                try ReviewCheck.require(fill.alphaComponent > 0.01 && c.max()! - c.min()! < 0.03, "Sidebar highlight is missing or not neutral")
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        print("PASS Production sidebar selection in light/dark and active/inactive states")
    }
}
#endif
