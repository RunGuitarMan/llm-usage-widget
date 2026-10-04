import AppKit
import SwiftUI

private struct NavigationFixtureService: CCUsageServing {
    func fetch(day: UsageDay, customPath: String, mode: UsageUpdateMode) async throws -> UsageSnapshot {
        .init(generatedAt: Date(), day: day, sessions: (0..<20).map { index in
            UsageSession(id: "navigation-\(index)", models: ["claude-navigation-\(index)"],
                         usage: .init(input: 100, cost: Double(20 - index)))
        })
    }
    func diagnose(customPath: String, forceDetect: Bool) async throws -> CLIDiagnostics {
        .init(path: "fixture", version: "fixture")
    }
}

/// Exercise session expansion and navigation in the dashboard's shared native viewport.
@main struct SessionNavigationChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "LLMUsageNavigationChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = UsageStore(service: NavigationFixtureService(), repository: SnapshotRepository(directory: directory),
                               defaults: defaults, reloadWidget: {})
        await store.refresh()
        for language in [InterfaceLanguage.english, .russian] {
            store.interfaceLanguage = language
            store.selectedSessionID = nil
            store.sessionList = .init()
            let host = NSHostingView(rootView: DashboardView(store: store).contentPreview
                .transaction { $0.disablesAnimations = true })
            let window = NSWindow(contentRect: .init(x: -8000, y: -8000, width: 850, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            try await wait("Statistics viewport did not appear") {
                guard let scroll = scrollViews(in: host).first else { return false }
                guard let document = scroll.documentView, document.frame.height > 1 else { return false }
                return scrollViews(in: host).count == 1
            }
            let scroll = scrollViews(in: host).first!
            let compactHeight = scroll.documentView!.frame.height
            store.sessionList.setExpanded(true)
            try await wait("Expanding sessions did not grow the main scroll content") {
                scroll.documentView!.frame.height > compactHeight + 1000
                    && scrollViews(in: host).count == 1 && scrollViews(in: host).first === scroll
            }
            store.sessionList.setExpanded(false)
            try await wait("Collapsing sessions did not restore the compact content height") {
                abs(scroll.documentView!.frame.height - compactHeight) < 1 && scrollViews(in: host).count == 1
            }
            store.sessionList = .init(isExpanded: true, query: "claude-navigation-0")
            try await wait("Filtered session viewport did not appear") {
                scroll.documentView!.frame.height < compactHeight
            }
            print("PASS Session expansion uses only the main Statistics scroll view in \(language.rawValue)")
            store.navigate(.session("navigation-19"))
            try await wait("Deep link failed to reveal its session after clearing search in \(language)") {
                store.selectedSessionID == "navigation-19" && atBottom(host)
            }
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            store.navigate(.session("navigation-19"))
            try await wait("Repeated link to the same session failed to reveal it") { atBottom(host) }

            // Normal search changes reveal the first result below the dashboard summary.
            let expandedHeight = scroll.documentView!.frame.height
            let selectedOffset = scroll.contentView.bounds.origin.y
            store.sessionList.query = "claude-navigation-1"
            try await wait("Search failed to reveal the start of its results") {
                scroll.documentView!.frame.height < expandedHeight
                    && scroll.contentView.bounds.origin.y < selectedOffset - 300
                    && !atBottom(host)
            }
            store.sessionList.model = "claude-navigation-0"
            store.sessionList.query = ""
            try await wait("Model filter retained a hidden selection") { store.selectedSessionID == nil }
            print("PASS Session links reveal the selected row after asynchronous filtering and repeated navigation in \(language.rawValue)")
        }
    }

    @MainActor private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }
    @MainActor private static func atBottom(_ host: NSView) -> Bool {
        guard let scroll = scrollViews(in: host).first, let document = scroll.documentView,
              document.frame.height > scroll.contentView.bounds.height * 2 else { return false }
        // The last row is followed by the session footer and the dashboard's bottom padding.
        return scroll.contentView.bounds.origin.y > 0 && document.frame.height - scroll.contentView.bounds.maxY < 100
    }
    @MainActor private static func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "SessionNavigationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
