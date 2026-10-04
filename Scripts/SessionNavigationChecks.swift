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

/// Exercise the asynchronous search and the actual native session viewport.
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
            store.sessionList = .init(isExpanded: true, query: "claude-navigation-0")
            let host = NSHostingView(rootView: DashboardSessionsSection(store: store)
                .padding(20).frame(width: 850).transaction { $0.disablesAnimations = true })
            let window = NSWindow(contentRect: .init(x: -8000, y: -8000, width: 850, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            try await wait("Filtered session viewport did not appear") {
                guard let scroll = scrollView(in: host) else { return false }
                guard let document = scroll.documentView, document.frame.height > 1 else { return false }
                return document.frame.height - scroll.contentView.bounds.height < 1
            }
            store.navigate(.session("navigation-19"))
            try await wait("Deep link failed to reveal its session after clearing search in \(language)") {
                store.selectedSessionID == "navigation-19" && atBottom(host)
            }
            let scroll = scrollView(in: host)!
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            store.navigate(.session("navigation-19"))
            try await wait("Repeated link to the same session failed to reveal it") { atBottom(host) }

            // Normal search changes still start at the top; excluded selections are cleared.
            store.sessionList.query = "claude-navigation-1"
            try await wait("Search failed to reset the viewport to the top") {
                scrollView(in: host)?.contentView.bounds.origin.y == 0
            }
            store.sessionList.model = "claude-navigation-0"
            store.sessionList.query = ""
            try await wait("Model filter retained a hidden selection") { store.selectedSessionID == nil }
            print("PASS Session links reveal the selected row after asynchronous filtering and repeated navigation in \(language.rawValue)")
        }
    }

    @MainActor private static func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
    @MainActor private static func atBottom(_ host: NSView) -> Bool {
        guard let scroll = scrollView(in: host), let document = scroll.documentView,
              document.frame.height > scroll.contentView.bounds.height * 2 else { return false }
        return scroll.contentView.bounds.origin.y > 0 && document.frame.height - scroll.contentView.bounds.maxY < 12
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
