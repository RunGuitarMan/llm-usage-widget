#if MANUAL_REVIEW
import AppKit
import QuartzCore

/// Inspect the real system glass and titlebar, not a rendered copy of SwiftUI content.
@MainActor enum WindowChromeChecks {
    struct Geometry {
        var titlebarHeight: CGFloat
        var sidebarRadius: CGFloat
        var toolbarControls: Int
    }
    private static var firstPresentation: Geometry?
    private static var firstPresentationWasHidden = false

    static func recordFirstPresentation(_ window: NSWindow) {
        guard firstPresentation == nil else { return }
        firstPresentationWasHidden = window.alphaValue == 0
        firstPresentation = try? geometry(window)
    }

    private static func geometry(_ window: NSWindow) throws -> Geometry {
        guard let content = window.contentView, let table = ReviewCheck.sidebar(in: content) else {
            throw NSError(domain: "WindowChromeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing native sidebar"])
        }
        var ancestor: NSView? = table
        while let view = ancestor, !(view is NSGlassEffectView) { ancestor = view.superview }
        guard let glass = ancestor as? NSGlassEffectView, let backing = glass.layer else {
            throw NSError(domain: "WindowChromeChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing system sidebar glass"])
        }
        // The public glass.cornerRadius is its minimum, not the computed concentric
        // radius. Read the rendered layers using public CALayer properties only.
        func radii(_ layer: CALayer) -> [CGFloat] {
            let sameSize = abs(layer.bounds.width - glass.bounds.width) < 1
                && abs(layer.bounds.height - glass.bounds.height) < 1
            let own = sameSize && layer.cornerRadius.isFinite ? [layer.cornerRadius] : []
            return own + (layer.sublayers ?? []).flatMap(radii) + (layer.mask.map(radii) ?? [])
        }
        return Geometry(titlebarHeight: window.frame.height - window.contentLayoutRect.height,
                        sidebarRadius: radii(backing).max() ?? 0,
                        toolbarControls: window.toolbar?.items.compactMap(\.view).count ?? 0)
    }

    private static func requireSame(_ actual: Geometry, _ expected: Geometry, _ context: String) throws {
        try ReviewCheck.require(abs(actual.sidebarRadius - expected.sidebarRadius) < 0.1,
                                "Sidebar radius changed during \(context): \(expected.sidebarRadius) -> \(actual.sidebarRadius)")
        try ReviewCheck.require(abs(actual.titlebarHeight - expected.titlebarHeight) < 0.1,
                                "Titlebar changed during \(context): \(expected.titlebarHeight) -> \(actual.titlebarHeight)")
        try ReviewCheck.require(actual.toolbarControls == expected.toolbarControls,
                                "Toolbar detached during \(context): \(actual.toolbarControls) controls")
    }

    static func run(_ review: ManualReviewController) async throws {
        guard let window = review.dashboard else { return }
        try await ReviewCheck.select("overview", in: review)
        try await ReviewCheck.wait("Initial dashboard remained transparent") { window.alphaValue == 1 }
        let settled = try geometry(window)
        try ReviewCheck.require(firstPresentationWasHidden, "First toolbar layout was already visible")
        guard let firstPresentation else {
            try ReviewCheck.require(false, "First presentation did not contain native sidebar glass"); return
        }
        try requireSame(firstPresentation, settled, "first presentation")
        print("PASS First visible dashboard has its final toolbar and sidebar corners")

        for appearance in [ReviewAppearance.light, .dark] {
            review.appearance = appearance
            review.changePresentation()
            for language in [InterfaceLanguage.russian, .english] {
                review.language = language
                review.changePresentation()
                try await ReviewCheck.select("overview", in: review)
                try await ReviewCheck.resize(window, width: 860)
                window.makeKeyAndOrderFront(nil)
                let normal = try geometry(window)
                try ReviewCheck.require(normal.sidebarRadius > 8, "Baseline sidebar did not become concentric")
                for _ in 0..<2 {
                    review.store.selectedSessionID = review.store.snapshot!.sessions[0].id
                    try await ReviewCheck.wait("Inspector did not finish opening") {
                        window.contentMinSize.width >= 1160
                            && ReviewCheck.views(NSScrollView.self, in: window.contentView!).filter { !$0.isHiddenOrHasHiddenAncestor }.count == 3
                    }
                    // Do not resize here: that repairs the very bug this check must catch.
                    try await ReviewCheck.settle()
                    try requireSame(geometry(window), normal, "automatic inspector expansion")
                    try ReviewCheck.require(window.contentView!.bounds.width >= 1160, "Inspector clipped its window")
                    try await ReviewCheck.wait("Inspector animation left content outside the window") {
                        (try? ReviewCheck.bounds(window.contentView!, in: window.contentView!)) != nil
                    }
                    review.store.selectedSessionID = nil
                    try await ReviewCheck.wait("Inspector kept its minimum after closing") { window.contentMinSize.width == 860 }
                    try await ReviewCheck.wait("Inspector did not finish closing") {
                        guard let split = ReviewCheck.views(NSSplitView.self, in: window.contentView!).last,
                              let inspector = split.arrangedSubviews.last else { return false }
                        return split.arrangedSubviews.count == 1 || split.isSubviewCollapsed(inspector)
                    }
                    try await ReviewCheck.resize(window, width: 860)
                    try requireSame(geometry(window), normal, "closing inspector and narrowing")
                }
                // Selection can be cancelled while the native resize is pending.
                review.store.selectedSessionID = review.store.snapshot!.sessions[0].id
                await Task.yield()
                review.store.navigate(.settings)
                try await ReviewCheck.settle()
                try ReviewCheck.require(review.store.selectedSessionID == nil && window.contentMinSize.width == 860,
                                        "Cancelled selection reopened the inspector")
            }
        }
        try await ReviewCheck.select("overview", in: review)
        let normal = try geometry(window)
        let toolbar = window.toolbar
        let content = window.contentView
        for _ in 0..<3 {
            window.performClose(nil)
            try ReviewCheck.require(!window.isVisible, "Close did not hide dashboard")
            try await ReviewCheck.settle()
            try ReviewCheck.require(window.toolbar === toolbar && window.contentView === content,
                                    "Close tore down the production window or toolbar")
            try requireSame(geometry(window), normal, "hidden dashboard")
            NotificationCenter.default.post(name: .openUsageDashboard, object: nil)
            // Sample immediately, then on subsequent frames; do not wait for a
            // settled toolbar, which would conceal a titlebar-only first frame.
            for _ in 0..<12 {
                try requireSame(geometry(window), normal, "reopening dashboard")
                try await Task.sleep(for: .milliseconds(16))
            }
            try ReviewCheck.require(window.isVisible && window.alphaValue == 1, "Reopen did not show dashboard")
            try ReviewCheck.require(review.dashboard === window, "Reopen replaced the scene window")
        }
        // The catalogue has commandsRemoved(). Keep it from taking menu focus
        // when the dashboard hides; it does not exist in the shipping app.
        review.panel?.orderOut(nil)
        try await otherPresentationPaths(window, normal: normal)
        print("PASS Native corners after automatic expansion/cancellation in RU/EN, light/dark; close/reopen, menu, minimization and full-screen preserve chrome")
    }

    @MainActor private final class FullScreenState { var entered = false }

    private static func otherPresentationPaths(_ window: NSWindow, normal: Geometry) async throws {
        func findOpenDashboard(in menu: NSMenu) -> (NSMenu, Int)? {
            menu.update()
            for (index, item) in menu.items.enumerated() {
                if item.title == L10n.text("Открыть обзор") { return (menu, index) }
                if let submenu = item.submenu, let match = findOpenDashboard(in: submenu) { return match }
            }
            return nil
        }
        window.makeKeyAndOrderFront(nil)
        try await ReviewCheck.settle()
        window.performClose(nil)
        // SwiftUI rebuilds the menu asynchronously as the key window changes.
        try await ReviewCheck.wait("Missing production Open Dashboard command") {
            NSApp.mainMenu.flatMap { findOpenDashboard(in: $0) } != nil
        }
        guard let mainMenu = NSApp.mainMenu, let (menu, index) = findOpenDashboard(in: mainMenu) else {
            try ReviewCheck.require(false, "Missing production Open Dashboard command"); return
        }
        menu.performActionForItem(at: index)
        try await ReviewCheck.wait("Open Dashboard menu command did not reopen the window") { window.isVisible }
        try requireSame(geometry(window), normal, "Open Dashboard menu command")
        window.miniaturize(nil)
        try await ReviewCheck.wait("Dashboard did not minimize") { window.isMiniaturized }
        NotificationCenter.default.post(name: .openUsageDashboard, object: nil)
        try await ReviewCheck.wait("Dashboard did not restore from the Dock") { window.isVisible && !window.isMiniaturized }
        try requireSame(geometry(window), normal, "restoring minimized dashboard")

        let state = FullScreenState()
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                                              object: window, queue: .main) { _ in
            MainActor.assumeIsolated { state.entered = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.toggleFullScreen(nil)
        try await ReviewCheck.wait("Dashboard did not finish entering full-screen") { state.entered }
        window.performClose(nil)
        try await ReviewCheck.wait("Closing full-screen dashboard did not exit its Space and hide it") {
            !window.isVisible && !window.styleMask.contains(.fullScreen)
        }
        NotificationCenter.default.post(name: .openUsageDashboard, object: nil)
        try await ReviewCheck.wait("Dashboard did not reopen after leaving full-screen") { window.isVisible }
        try requireSame(geometry(window), normal, "reopening after full-screen")
    }

    static func saveFailure(_ review: ManualReviewController) {
        guard let window = review.dashboard, let root = window.contentView?.superview else { return }
        var rows = ["window=\(window.frame) minimum=\(window.contentMinSize) visible=\(window.isVisible) key=\(window.isKeyWindow) selected=\(review.store.selectedSessionID ?? "nil")"]
        func walk(_ view: NSView, _ indent: String) {
            rows.append("\(indent)\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden)")
            if let split = view as? NSSplitView {
                rows.append("\(indent)arranged=\(split.arrangedSubviews.map { "\($0.frame) collapsed=\(split.isSubviewCollapsed($0))" })")
            }
            for child in view.subviews { walk(child, indent + " ") }
        }
        walk(root, "")
        try? rows.joined(separator: "\n").write(to: review.reportURL.deletingLastPathComponent().appendingPathComponent("window-failure.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
