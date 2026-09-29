import XCTest
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#else
@testable import LLMUsage
#endif

actor TestUsageService: CCUsageServing {
    var failure: UsageError?
    var requested: [UsageDay] = []
    func fail(_ error: UsageError?) { failure = error }
    func fetch(day: UsageDay, customPath: String, mode: UsageUpdateMode) async throws -> UsageSnapshot {
        requested.append(day)
        if let failure { throw failure }
        var data = SampleData.snapshot()
        data.day = day
        return data
    }
    func diagnose(customPath: String, forceDetect: Bool) async throws -> CLIDiagnostics {
        if let failure { throw failure }
        return .init(path: "/fixture/ccusage", version: "fixture 1.0")
    }
}

actor TestSnapshotRepository: SnapshotPersisting {
    var snapshots: [String: UsageSnapshot] = [:]
    var status: RefreshStatus?
    var history: UsageHistory?
    func read(_ slot: SnapshotSlot) -> UsageSnapshot? { snapshots[slot.rawValue] }
    func write(_ snapshot: UsageSnapshot, to slot: SnapshotSlot) { snapshots[slot.rawValue] = snapshot }
    func readStatus() -> RefreshStatus? { status }
    func readHistory() -> UsageHistory? { history }
    func writeHistory(_ history: UsageHistory) { self.history = history }
    func writeStatus(_ status: RefreshStatus) { self.status = status }
}

final class UsageStoreTests: XCTestCase {
    @MainActor func testFailureKeepsLastSuccessfulSnapshot() async throws {
        let service = TestUsageService()
        let repository = TestSnapshotRepository()
        let suite = "LLMUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(service: service, repository: repository, defaults: defaults, reloadWidget: {})
        await store.refresh()
        let successful = try XCTUnwrap(store.snapshot)
        XCTAssertEqual(store.state, .loaded)
        await service.fail(.timedOut)
        await store.refresh()
        XCTAssertEqual(store.state, .stale)
        XCTAssertEqual(store.snapshot, successful)
        let persisted = await repository.read(.today)
        XCTAssertEqual(persisted, successful)
        XCTAssertEqual(store.error, .timedOut)
    }
    @MainActor func testHistoricalSelectionDoesNotOverwriteWidgetToday() async throws {
        let suite = "LLMUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = TestSnapshotRepository()
        let store = UsageStore(service: TestUsageService(), repository: repository, defaults: defaults, reloadWidget: {})
        store.period = .custom
        store.customDate = Date().addingTimeInterval(-4 * 86400)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.day, store.selectedDay)
        let widget = await repository.read(.today)
        XCTAssertTrue(try XCTUnwrap(widget).day.isToday())
        XCTAssertNotEqual(widget?.day, store.selectedDay)
        store.navigate(.overview)
        XCTAssertEqual(store.period, .today)
        XCTAssertEqual(store.snapshot?.day, widget?.day)
    }
    @MainActor func testMissingCLIProducesErrorWithoutFakeZeroUsage() async {
        let service = TestUsageService()
        await service.fail(.missingExecutable)
        let suite = "LLMUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(service: service, repository: TestSnapshotRepository(), defaults: defaults, reloadWidget: {})
        await store.refresh()
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.state, .error)
        XCTAssertFalse(store.isRefreshing)
    }
    @MainActor func testSourceFilterLeavesWidgetTotalsUnchangedAndRoutesResetIt() {
        let store = UsageStore(demo: true)
        let total = store.todaySnapshot?.totals.total
        store.sourceFilter = "codex"
        XCTAssertEqual(store.displaySnapshot?.sessions.count, 1)
        XCTAssertEqual(store.selectedModels, ["gpt-6-astra"])
        XCTAssertEqual(store.todaySnapshot?.totals.total, total)
        XCTAssertNotEqual(store.displaySnapshot?.totals.total, total)
        store.navigate(.overview)
        XCTAssertEqual(store.sourceFilter, "")
        store.navigate(.session("11111111-1111-4111-8111-111111111111"))
        XCTAssertEqual(store.selectedSession?.sourceID, "claude")
    }

}
