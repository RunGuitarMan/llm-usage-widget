import Foundation
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#elseif !PORTABLE_CHECKS && !MANUAL_REVIEW
@testable import LLMUsage
#endif

private struct WidgetFailure: Error, CustomStringConvertible { var description: String }
private func requireWidget(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw WidgetFailure(description: message) }
}

private actor PublicationRepository: SnapshotPersisting {
    var status: RefreshStatus?
    var snapshots: [SnapshotSlot: UsageSnapshot] = [:]
    var history: UsageHistory?
    var hold = false
    var fail = false
    var active = 0
    var maximumActive = 0
    var attempts = 0
    func control(hold: Bool = false, fail: Bool = false) { self.hold = hold; self.fail = fail }
    func read(_ slot: SnapshotSlot) -> UsageSnapshot? { snapshots[slot] }
    func write(_ snapshot: UsageSnapshot, to slot: SnapshotSlot) { snapshots[slot] = snapshot }
    func readStatus() -> RefreshStatus? { status }
    func readHistory() -> UsageHistory? { history }
    func writeHistory(_ history: UsageHistory) { self.history = history }
    func writeStatus(_ status: RefreshStatus) async throws {
        active += 1; attempts += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        while hold { try await Task.sleep(for: .milliseconds(5)) }
        if fail { throw UsageError.sharedContainer("injected publication failure") }
        self.status = status
    }
}

enum WidgetStabilityScenarios {
    @MainActor static func run(check: (String, () async throws -> Void) async -> Void) async {
        let date = Date(timeIntervalSince1970: 1_791_288_000)
        let context = UsageDataContext(timezone: "UTC", customPath: "")
        func status(_ snapshot: UsageSnapshot?) -> RefreshStatus {
            .init(attemptedAt: date, message: nil, refreshMinutes: 3, dataContext: context,
                  presentation: .init(snapshot: snapshot, previous: nil, history: nil))
        }
        func sample() -> UsageSnapshot {
            var value = SampleData.snapshot(now: date); value.dataContext = context
            return value
        }
        func wait(_ message: String, until condition: () async -> Bool) async throws {
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while !(await condition()) {
                try requireWidget(ContinuousClock.now < end, message)
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        await check("Widget: signed development app and extension share an isolated directory") {
            let root = URL(fileURLWithPath: "/group")
            let app = SharedConfiguration.appGroupDirectory(root: root, bundleIdentifier: "local.fixture", channel: "development")
            let widget = SharedConfiguration.appGroupDirectory(root: root, bundleIdentifier: "local.fixture.Widget", channel: "development")
            let release = SharedConfiguration.appGroupDirectory(root: root, bundleIdentifier: "local.fixture", channel: "release")
            try requireWidget(app == widget && app != release && release == root, "Development publication can replace release data")
        }
        await check("Widget: fallback cadence ignores fast mode and past midnight; transitions are unique") {
            let tomorrow = UsageDay(date: date).end
            try requireWidget(WidgetPresentation.nextReload(now: date, dayEnd: tomorrow, storageUnavailable: false) == date.addingTimeInterval(1200), "Fast polling leaked into WidgetKit")
            try requireWidget(WidgetPresentation.nextReload(now: tomorrow, dayEnd: tomorrow, storageUnavailable: false) == tomorrow.addingTimeInterval(1200), "Past day causes one-minute polling")
            try requireWidget(WidgetPresentation.nextReload(now: tomorrow.addingTimeInterval(-30), dayEnd: tomorrow, storageUnavailable: false) == tomorrow, "Midnight was postponed")
            var value = sample(); value.generatedAt = tomorrow.addingTimeInterval(-601)
            let transitions = UsageHealth.transitionDates(snapshot: value, history: nil, status: status(value), now: tomorrow.addingTimeInterval(-600))
            try requireWidget(transitions == [tomorrow], "Coincident stale/midnight transitions were duplicated")
        }
        await check("Widget: 100k sessions produce bounded rows, exact totals, history and round-trip") {
            var value = sample()
            value.sessions = (0..<100_000).map { i in
                UsageSession(id: "session-\(i)", models: ["paid"], usage: .init(input: Int64(i + 1), cost: Double(i % 23)))
            }
            let started = ContinuousClock.now
            let projection = WidgetPresentation(status: status(value), now: date)
            try projection.validate()
            let data = try JSONEncoder().encode(projection)
            let roundTrip = try JSONDecoder().decode(WidgetPresentation.self, from: data)
            try requireWidget(roundTrip == projection && projection.snapshot?.totals == value.totals && projection.snapshot?.sessionCount == 100_000,
                              "Projection changed totals/count or lost precision")
            try requireWidget(Array(SessionSort.cost.sorted(projection.snapshot!.sessions).prefix(4)) == Array(SessionSort.cost.sorted(value.sessions).prefix(4)), "Projection changed the cost ranking")
            try requireWidget(projection.snapshot!.sessions.count <= 7 && data.count < 32_768, "Extension payload grew with report size")
            try requireWidget(projection.history?.days.first?.usage == value.totals, "Projection lost today's chart point")
            print("PASS Widget projection measurement: 100000 sessions -> \(data.count) bytes, \(started.duration(to: .now))")
        }
        await check("Widget: validation precedes replacement; legacy history survives absent context") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("widget-publication-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let missing: WidgetPresentation? = try SnapshotFiles.readValue(name: WidgetPresentation.filename, directory: directory,
                maximumBytes: WidgetPresentation.maximumBytes, dateDecoding: .deferredToDate)
            try requireWidget(missing == nil, "Missing compact file is a clean install, not a storage failure")
            let repository = SnapshotRepository(directory: directory)
            var fractional = sample(); fractional.generatedAt = date.addingTimeInterval(0.1234567)
            let good = status(fractional)
            try await repository.writeStatus(good)
            let path = directory.appendingPathComponent(WidgetPresentation.filename)
            let saved = try Data(contentsOf: path)
            var invalid = good; invalid.presentation?.snapshot?.sessions.append(sample().sessions[0])
            do { try await repository.writeStatus(invalid); throw WidgetFailure(description: "Published invalid duplicate session") }
            catch is UsageError { }
            let afterRejectedWrite = try Data(contentsOf: path)
            try requireWidget(afterRejectedWrite == saved, "Rejected document replaced good widget data")
            var decoded: WidgetPresentation? = try SnapshotFiles.readValue(name: WidgetPresentation.filename, directory: directory, maximumBytes: WidgetPresentation.maximumBytes, dateDecoding: .deferredToDate)
            try decoded?.validate()
            try requireWidget(decoded?.snapshot?.totals == sample().totals && decoded?.snapshot?.generatedAt == fractional.generatedAt, "Read after publication changed totals")
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            try requireWidget((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Published file permissions are not private")
            let history = SampleData.history(now: date, context: context)
            try await repository.writeHistory(history)
            try await repository.write(sample(), to: .today)
            try await repository.writeStatus(.init(attemptedAt: date, message: nil, refreshMinutes: 3))
            let legacy = try SnapshotFiles.presentation(directory: directory)
            try requireWidget(legacy.snapshot != nil && legacy.history != nil, "Legacy nil-context hid only history")
            try Data(repeating: 32, count: WidgetPresentation.maximumBytes + 1).write(to: path)
            do {
                decoded = try SnapshotFiles.readValue(name: WidgetPresentation.filename, directory: directory, maximumBytes: WidgetPresentation.maximumBytes, dateDecoding: .deferredToDate)
                throw WidgetFailure(description: "Unbounded widget read")
            } catch is UsageError { }
        }
        await check("Widget: overlapping publications serialize and converge to newest preferences") {
            let suite = "widget-order-\(UUID())", repository = PublicationRepository()
            let defaults = UserDefaults(suiteName: suite)!
            let originalLanguage = L10n.preference
            defer { defaults.removePersistentDomain(forName: suite); L10n.preference = originalLanguage }
            let store = UsageStore(repository: repository, defaults: defaults, now: { date }, widgetReloadDelay: 0, reloadWidget: {})
            await repository.control(hold: true)
            store.budgetEnabled = true
            try await wait("First publication never started") { await repository.active == 1 }
            for amount in [10.0, 20, 30, 40] { _ = store.setBudgetAmount(amount) }
            store.interfaceLanguage = .english
            // Give competing tasks a chance to reach the writer while it is held.
            try await Task.sleep(for: .milliseconds(30))
            await repository.control()
            await store.waitForWidgetPublication()
            let latest = await repository.readStatus(), concurrent = await repository.maximumActive
            try requireWidget(concurrent == 1 && latest?.dailyBudget == 40 && latest?.interfaceLanguage == .english,
                              "Old/in-flight publication overwrote newest settings")
        }
        await check("Widget: failed publication never reloads and retries current state without a CLI refresh") {
            let suite = "widget-retry-\(UUID())", repository = PublicationRepository()
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var reloads = 0
            let store = UsageStore(repository: repository, defaults: defaults, now: { date }, widgetReloadDelay: 0,
                                   publicationRetryDelay: 0.02, reloadWidget: { reloads += 1 })
            await repository.control(fail: true)
            store.budgetEnabled = true
            try await wait("Failure not reported") { store.storageError != nil }
            try requireWidget(reloads == 0, "Failed write consumed a reload")
            await repository.control()
            try await wait("No automatic publication recovery") { reloads > 0 && store.storageError == nil }
            let latest = await repository.readStatus()
            try requireWidget(latest?.dailyBudget != nil, "Retry did not publish current preferences")
        }
        await check("Widget: unchanged publications skip reloads but renew freshness periodically") {
            let suite = "widget-heartbeat-\(UUID())", repository = PublicationRepository()
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var clock = date, reloads = 0
            let store = UsageStore(repository: repository, defaults: defaults, now: { clock }, widgetReloadDelay: 0, reloadWidget: { reloads += 1 })
            for offset in [0.0, 5, 301] {
                clock = date.addingTimeInterval(offset)
                let previousAttempts = await repository.attempts
                store.preferencesChanged()
                try await wait("Publication did not run") { await repository.attempts > previousAttempts }
                await store.waitForWidgetPublication()
                try requireWidget(reloads == (offset < 300 ? 1 : 2), "Duplicate reload or missing freshness heartbeat")
            }
        }
        await check("Widget: preference burst coalesces to one reload of the final publication") {
            let suite = "widget-coalesce-\(UUID())", repository = PublicationRepository()
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var reloads = 0
            let store = UsageStore(repository: repository, defaults: defaults, now: { date }, widgetReloadDelay: 0.1, reloadWidget: { reloads += 1 })
            store.budgetEnabled = true
            for amount in [10.0, 20, 30, 40] { _ = store.setBudgetAmount(amount) }
            try await wait("Final preferences not published") { await repository.readStatus()?.dailyBudget == 40 }
            await store.waitForWidgetPublication()
            try requireWidget(reloads == 1, "A preference burst exhausted multiple reloads")
        }
        await check("Widget: content dedup retains changes, partial days and stale recovery") {
            let first = WidgetPresentation(status: status(sample()), now: date)
            var next = sample(); next.generatedAt = date.addingTimeInterval(5)
            var nextStatus = status(next); nextStatus.attemptedAt = date.addingTimeInterval(5)
            let second = WidgetPresentation(status: nextStatus, now: date.addingTimeInterval(5))
            try requireWidget(first.contentIdentity() == second.contentIdentity(), "Bookkeeping defeated content deduplication")
            nextStatus.dailyBudget = 42
            try requireWidget(first.contentIdentity() != WidgetPresentation(status: nextStatus, now: date).contentIdentity(), "Budget change was deduplicated")
            nextStatus = status(sample()); nextStatus.isRecalculating = true
            try requireWidget(first.contentIdentity() != WidgetPresentation(status: nextStatus, now: date).contentIdentity(), "Recalculation state was hidden")
            let original = L10n.preference
            let english = UsageLocalizer(language: .english), russian = UsageLocalizer(language: .russian)
            try requireWidget(english.text("Сегодня") == "Today" && russian.text("Сегодня") == "Сегодня" && L10n.preference == original,
                              "Widget localization mutates another entry's language")
        }
    }
}
