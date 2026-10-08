import Foundation

/// Only external I/O is replaced. UsageStore still performs restore, refresh, cache and error handling.
@MainActor final class ReviewFixtureService: CCUsageServing {
    private var fixture = ReviewFixture.normal
    private var revision = 0
    private(set) var fetchCount = 0
    func configure(_ fixture: ReviewFixture) { revision += 1; self.fixture = fixture }
    func releaseResponse() { fixture = .normal }
    func fetch(day: UsageDay, customPath: String, mode: UsageUpdateMode) async throws -> UsageSnapshot {
        fetchCount += 1
        let request = revision
        repeat {
            try await Task.sleep(for: .milliseconds(120))
            guard request == revision else { throw CancellationError() }
        } while fixture == .loading || fixture == .refreshing
        if fixture == .missing { throw UsageError.missingExecutable }
        if fixture == .failure || fixture == .multiple { throw UsageError.timedOut }
        if fixture == .gaps && day != UsageDay(timezone: day.timezone) { throw UsageError.timedOut }
        var data = fixture.snapshot(day: day) ?? SampleData.multiSourceSnapshot()
        data.day = day
        return data
    }
    func diagnose(customPath: String, forceDetect: Bool) async throws -> CLIDiagnostics {
        if fixture == .missing { throw UsageError.missingExecutable }
        return .init(path: "/ui-review/ccusage", version: "Изолированный тестовый источник")
    }
}

@MainActor final class ReviewRepository: SnapshotPersisting {
    private var snapshots: [SnapshotSlot: UsageSnapshot] = [:]
    private var history: UsageHistory?
    private var status: RefreshStatus?
    private var unavailable = false
    func configure(_ fixture: ReviewFixture, context: UsageDataContext) {
        unavailable = fixture == .storage
        snapshots = [:]
        status = nil
        history = SampleData.history(context: context)
        if fixture == .gaps, var value = history {
            value.days = value.days.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            history = value
        }
        if [.failure, .refreshing, .stale, .multiple].contains(fixture) {
            var cached = SampleData.multiSourceSnapshot()
            cached.day = UsageDay(timezone: context.timezone)
            cached.generatedAt = Date().addingTimeInterval(-7200)
            if fixture == .multiple { cached.sessions[0].usage.costIsIncomplete = true }
            cached.dataContext = context
            snapshots[.today] = cached
        }
    }
    private func checkAccess() throws {
        if unavailable { throw UsageError.sharedContainer("Тестовая ошибка доступа к хранилищу") }
    }
    func read(_ slot: SnapshotSlot) async throws -> UsageSnapshot? { try checkAccess(); return snapshots[slot] }
    func write(_ snapshot: UsageSnapshot, to slot: SnapshotSlot) async throws { try checkAccess(); snapshots[slot] = snapshot }
    func writeStatus(_ status: RefreshStatus) async throws { try checkAccess(); self.status = status }
    func readStatus() async throws -> RefreshStatus? { try checkAccess(); return status }
    func readHistory() async throws -> UsageHistory? { try checkAccess(); return history }
    func writeHistory(_ history: UsageHistory) async throws { try checkAccess(); self.history = history }
}
