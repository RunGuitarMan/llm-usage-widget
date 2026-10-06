#if MANUAL_REVIEW
import AppKit

@MainActor enum ManualReviewChecks {
    static func run(_ review: ManualReviewController) async throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "ManualReview", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(350)) }
        func select(_ id: String) async throws {
            review.select(id)
            await review.selectionTask?.value
            try await settle()
            try await ReviewCheck.waitForToolbar(review)
        }
        func toolbar() throws {
            try ReviewCheck.toolbar(review)
        }
        try require(review.connectedToAppRoot, "Review did not attach to the production AppRootView")
        guard let window = review.dashboard else { try require(false, "Missing production scene"); return }
        try require(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]), "Window lost production controls")
        try require(window.toolbarStyle == .unified, "Wrong production toolbar style")
        try require(window.collectionBehavior.contains(.fullScreenPrimary)
                    && !window.collectionBehavior.contains(.fullScreenAuxiliary)
                    && !window.collectionBehavior.contains(.fullScreenNone),
                    "Dashboard cannot enter its own full-screen Space")
        try require(!review.store.isDemo, "Review disabled product controls using demo mode")
        try require(Set(ReviewScenario.all.map(\.id)).count == ReviewScenario.all.count, "Duplicate scenario IDs")
        try await WindowChromeChecks.run(review)
        try await WindowChecks.run(review)
        try await SessionNavigationChecks.run(review)
        for scenario in ReviewScenario.all {
            try await select(scenario.id)
            try require(review.dashboard === window, "Scenario replaced the production window")
            if case let .dashboard(_, _, option) = scenario.target {
                try toolbar()
                if option == "inspector" {
                    try require(review.store.selectedSessionID != nil, "Inspector selection lost during scenario transition")
                }
            }
            if case .chat = scenario.target {
                try require(window.attachedSheet != nil, "Chat bypassed the production sheet: \(scenario.id), selection=\(review.store.selectedSessionID ?? "nil"), requested=\(review.store.reviewChatPresented)")
            }
        }
        print("PASS Catalogue: \(ReviewScenario.all.count) scenarios in production scene and chat sheets")
        review.language = .russian
        review.appearance = .dark
        review.size = .compact
        review.changePresentation()
        for _ in 0..<3 {
            try await select("chat-partial")
            try await select("chat-long")
            try await Task.sleep(for: .milliseconds(500))
            try require(window.attachedSheet != nil, "Long chat lost its sheet in dark compact layout")
        }
        print("PASS Long-message layout remains responsive across dark compact sheet transitions")
        try await select("inspector-long")
        try require(review.store.selectedSessionID != nil, "Closing chat discarded the inspector scenario selection")
        for language in [InterfaceLanguage.russian, .english] {
            review.language = language
            review.changePresentation()
            var counts: [Int: Int] = [:]
            for pass in 0..<3 {
                for step in 0...6 {
                    try await select("transition-\(step)")
                    try toolbar()
                    let count = window.toolbar?.items.compactMap(\.view).count ?? 0
                    if pass == 0 { counts[step] = count }
                    else { try require(count == counts[step], "Toolbar accumulated controls across transitions") }
                }
            }
        }
        print("PASS Production toolbar transitions in RU/EN")
        try await select("overview-failure")
        try require(review.store.error != nil && review.store.snapshot != nil, "Cached error did not use repository restore")
        let fetches = review.service.fetchCount
        review.service.releaseResponse()
        await review.store.refresh()
        try require(review.service.fetchCount > fetches && review.store.error == nil && review.store.state == .loaded,
                    "Refresh did not go through the real service/store lifecycle")
        try await select("overview-loading")
        try require(review.store.snapshot == nil && review.store.isRefreshing, "Loading did not hold a real request")
        review.recoverSource()
        for _ in 0..<30 {
            if !review.store.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(review.store.state == .loaded, "Held response did not complete through UsageStore")
        try await select("overview-loading")
        try await select("overview-empty")
        try await Task.sleep(for: .milliseconds(300))
        try require(review.store.snapshot?.sessions.isEmpty == true && !review.store.isRefreshing,
                    "Obsolete loading request overwrote a new scenario")
        print("PASS Real restore/refresh/error recovery and obsolete-request isolation")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try ManualReviewController(reportDirectory: directory)
        defer { report.cleanup() }
        report.save(status: "issue", notes: "Заметка\nВторая строка")
        let reloaded = try ManualReviewController(reportDirectory: directory)
        defer { reloaded.cleanup() }
        try require(reloaded.currentRecord.status == "issue" && reloaded.currentRecord.notes.contains("\n"), "Notes did not survive restart")
        reloaded.appearance = .dark
        try require(reloaded.currentRecord.status == "unreviewed", "Appearance variants share status")
        reloaded.selectedID = "chat-long"
        reloaded.language = .english
        reloaded.size = .wide
        reloaded.save(notes: "Continue here")
        let resumed = try ManualReviewController(reportDirectory: directory)
        defer { resumed.cleanup() }
        try require(resumed.selectedID == "chat-long" && resumed.appearance == .dark
                    && resumed.language == .english && resumed.size == .wide && resumed.currentRecord.notes == "Continue here",
                    "Catalogue position/presentation did not survive restart")
        let badDirectory = directory.appendingPathComponent("invalid")
        try FileManager.default.createDirectory(at: badDirectory, withIntermediateDirectories: true)
        let original = Data("not-json".utf8)
        let badURL = badDirectory.appendingPathComponent("review-progress.json")
        try original.write(to: badURL)
        let invalid = try ManualReviewController(reportDirectory: badDirectory)
        defer { invalid.cleanup() }
        invalid.save(notes: "Must preserve unreadable report")
        try require(invalid.persistenceError != nil && (try Data(contentsOf: badURL)) == original, "Unreadable report overwritten")
    }
}
#endif
