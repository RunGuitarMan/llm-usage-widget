#if MANUAL_REVIEW
import AppKit

/// In-process assertions against the shipping scene. Never constructs a product window or host.
@MainActor enum ReviewCheck {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NSError(domain: "ReviewCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }

    static func wait(_ message: String, until condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while try !condition() {
            try require(ContinuousClock.now < deadline, message)
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    static func sidebar(in view: NSView) -> NSTableView? {
        views(NSTableView.self, in: view).first { $0.effectiveStyle == .sourceList }
    }

    static func toolbar(_ review: ManualReviewController) throws {
        guard let window = review.dashboard, let toolbar = window.toolbar else {
            try require(false, "Missing production toolbar: \(review.selectedID)"); return
        }
        let store = review.store
        let controls = toolbar.items.compactMap(\.view)
        let menus = controls.flatMap { views(NSPopUpButton.self, in: $0) }
        let showsPeriod = store.tab != .settings
        let count = 2 + (showsPeriod ? 1 : 0) + (showsPeriod && store.period == .custom ? 1 : 0)
        let context = "\(store.tab) / \(store.period) / \(store.interfaceLanguage.rawValue)"
        try require(controls.count == count, "Duplicate/missing toolbar controls in \(context): \(controls.count), expected \(count)")
        try require(menus.count == (showsPeriod ? 1 : 0), "Duplicate/missing period menu in \(context)")
        if let menu = menus.first {
            try require(menu.isEnabled && menu.title == store.period.title, "Stale or disabled period menu in \(context)")
        }
        // A manually hosted DashboardView centres these controls. Test the actual scene's placement.
        if let trailing = controls.last {
            let frame = trailing.convert(trailing.bounds, to: nil)
            try require(frame.maxX > window.frame.width - 80 && frame.maxX <= window.frame.width,
                        "Toolbar actions are not at the trailing window edge in \(context): \(frame)")
        }
        try require(window.toolbarStyle == .unified, "Dashboard lost its shipping toolbar style")
        try require(window.collectionBehavior.contains(.fullScreenPrimary)
                    && !window.collectionBehavior.contains(.fullScreenAuxiliary)
                    && !window.collectionBehavior.contains(.fullScreenNone), "Dashboard lost native full-screen behavior")
    }

    static func waitForToolbar(_ review: ManualReviewController) async throws {
        // Locale changes replace the SwiftUI subtree; wait for its native toolbar transaction.
        do {
            try await wait("Production toolbar did not settle after \(review.selectedID)") {
                (try? toolbar(review)) != nil
            }
        } catch {
            // Preserve the specific native-layout failure rather than just a timeout.
            try toolbar(review)
            throw error
        }
        try toolbar(review)
    }

    static func select(_ id: String, in review: ManualReviewController) async throws {
        review.select(id)
        await review.selectionTask?.value
        try await settle()
        try await waitForToolbar(review)
    }

    @discardableResult static func bounds(_ view: NSView, in host: NSView) throws -> Int {
        guard !view.isHiddenOrHasHiddenAncestor else { return 0 }
        var count = 0
        if view is NSSplitView || view is NSScrollView || view is NSSearchField {
            let rect = view.convert(view.bounds, to: host)
            try require(rect.minX >= -1 && rect.maxX <= host.bounds.width + 1,
                        "\(type(of: view)) escapes production window: \(rect), width \(host.bounds.width)")
            count += 1
        }
        for child in view.subviews { count += try bounds(child, in: host) }
        return count
    }

    static func resize(_ window: NSWindow, width: CGFloat, height: CGFloat = 620) async throws {
        window.setContentSize(.init(width: width, height: height))
        try await settle()
        window.contentView?.layoutSubtreeIfNeeded()
        try await settle()
        guard let host = window.contentView else { try require(false, "Window lost production content"); return }
        try require(try bounds(host, in: host) > 0, "Geometry check did not reach the native viewport")
        try require(abs(host.bounds.width - width) <= 1, "Window did not fit requested width \(width): \(host.bounds)")
    }
}
#endif
