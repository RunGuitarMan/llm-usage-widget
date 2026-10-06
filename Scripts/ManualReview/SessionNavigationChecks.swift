import AppKit

@MainActor enum SessionNavigationChecks {
    static func run(_ review: ManualReviewController) async throws {
        let store = review.store
        let window = review.dashboard!
        for language in [InterfaceLanguage.english, .russian] {
            review.language = language
            review.changePresentation()
            try await ReviewCheck.select("session-links", in: review)
            let host = window.contentView!
            let sidebar = ReviewCheck.sidebar(in: host)!.enclosingScrollView
            let scrolls = ReviewCheck.views(NSScrollView.self, in: host)
            guard let scroll = scrolls.first(where: { $0 !== sidebar }) else {
                try ReviewCheck.require(false, "Missing production Statistics viewport"); return
            }
            store.sessionList.setExpanded(false)
            try await ReviewCheck.settle()
            let compactHeight = scroll.documentView!.frame.height
            store.sessionList.setExpanded(true)
            try await ReviewCheck.wait("Expanding sessions did not grow the shared viewport") {
                scroll.documentView!.frame.height > compactHeight + 1000
                    && ReviewCheck.views(NSScrollView.self, in: host).count == 2
            }
            store.sessionList.setExpanded(false)
            try await ReviewCheck.wait("Collapsing sessions did not restore compact content") {
                abs(scroll.documentView!.frame.height - compactHeight) < 1
            }
            store.sessionList = .init(isExpanded: true, query: "claude-navigation-0")
            try await ReviewCheck.wait("Filtered viewport did not appear") { scroll.documentView!.frame.height < compactHeight }
            store.navigate(.session("navigation-19"))
            try await ReviewCheck.wait("Deep link did not clear search and reveal its session") {
                store.selectedSessionID == "navigation-19" && atBottom(scroll)
            }
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            store.navigate(.session("navigation-19"))
            try await ReviewCheck.wait("Repeated link did not reveal its session") { atBottom(scroll) }
            let expandedHeight = scroll.documentView!.frame.height
            let selectedOffset = scroll.contentView.bounds.origin.y
            store.sessionList.query = "claude-navigation-1"
            try await ReviewCheck.wait("Search did not reveal the first results") {
                scroll.documentView!.frame.height < expandedHeight
                    && scroll.contentView.bounds.origin.y < selectedOffset - 300 && !atBottom(scroll)
            }
            store.sessionList.model = "claude-navigation-0"
            store.sessionList.query = ""
            try await ReviewCheck.wait("Model filter retained a hidden selection") { store.selectedSessionID == nil }
            try ReviewCheck.require(review.dashboard === window && scroll.window === window, "Navigation replaced the production scene/viewport")
            print("PASS Session expansion, filtering and repeated links in production scene in \(language.rawValue)")
        }
    }

    private static func atBottom(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView, document.frame.height > scroll.contentView.bounds.height * 2 else { return false }
        return scroll.contentView.bounds.origin.y > 0 && document.frame.height - scroll.contentView.bounds.maxY < 100
    }
}
