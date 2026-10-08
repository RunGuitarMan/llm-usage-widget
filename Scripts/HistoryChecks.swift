import Foundation

private struct HistoryCheckFailure: Error { var message: String }
private func requireHistory(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw HistoryCheckFailure(message: message) }
}

private actor HistoryFixtureService: CCUsageServing {
    nonisolated let engineID: String?
    init(engineID: String? = nil) { self.engineID = engineID }
    var requests: [(UsageDay, String)] = []
    var historicalDelay: Duration = .zero
    var todayDelay: Duration = .zero
    var failedDays: Set<String> = []
    func configure(historicalDelay: Duration = .zero, todayDelay: Duration = .zero, failedDays: Set<String> = []) {
        self.historicalDelay = historicalDelay
        self.todayDelay = todayDelay
        self.failedDays = failedDays
    }
    func fetch(day: UsageDay, customPath: String, mode: UsageUpdateMode) async throws -> UsageSnapshot {
        requests.append((day, customPath))
        // Deliberately return after cancellation: the store must guard late completions itself.
        try? await Task.sleep(for: day.isToday() ? todayDelay : historicalDelay)
        if failedDays.contains(day.cacheKey) { throw UsageError.timedOut }
        var result = SampleData.multiSourceSnapshot()
        result.day = day
        result.sessions[0].usage.cost = customPath.isEmpty ? 10 : 80
        return result
    }
    func diagnose(customPath: String, forceDetect: Bool) -> CLIDiagnostics { .init(path: customPath, version: "fixture") }
    func requestCount() -> Int { requests.count }
}

private actor HistoryMemoryRepository: SnapshotPersisting {
    var snapshots: [String: UsageSnapshot] = [:]
    var status: RefreshStatus?
    var history: UsageHistory?
    func read(_ slot: SnapshotSlot) -> UsageSnapshot? { snapshots[slot.rawValue] }
    func write(_ snapshot: UsageSnapshot, to slot: SnapshotSlot) { snapshots[slot.rawValue] = snapshot }
    func writeStatus(_ status: RefreshStatus) { self.status = status }
    func readStatus() -> RefreshStatus? { status }
    func readHistory() -> UsageHistory? { history }
    func writeHistory(_ history: UsageHistory) { self.history = history }
}

enum HistoryChecks {
    @MainActor static func run(check: (String, () async throws -> Void) async -> Void) async {
        await check("History: patched engine recalculates every cached day and republishes widget data") {
            let suite = "LLMUsage.EngineMigration.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let repository = HistoryMemoryRepository()
            let oldService = HistoryFixtureService(engineID: "ccusage/20.0.26/contract-1")
            let old = UsageStore(service: oldService, repository: repository, defaults: defaults, reloadWidget: {})
            await old.refresh()
            await old.waitForHistoryBackfill()
            let newService = HistoryFixtureService(engineID: "ccusage/20.0.26-llmusage.3/contract-2")
            var reloads = 0
            let updated = UsageStore(service: newService, repository: repository, defaults: defaults, reloadWidget: { reloads += 1 })
            await updated.refresh()
            await updated.waitForHistoryBackfill()
            await updated.waitForWidgetPublication()
            let count = await newService.requestCount()
            let today = await repository.read(.today)
            let yesterday = await repository.read(.yesterday)
            let history = await repository.readHistory()
            try requireHistory(count == 7 && history?.days.count == 7, "Old engine totals skipped recalculation")
            try requireHistory(today?.dataContext == updated.dataContext && yesterday?.dataContext == updated.dataContext
                               && history?.context == updated.dataContext && reloads >= 1, "Widget files or invalidations kept the old engine")
            let restarted = UsageStore(service: newService, repository: repository, defaults: defaults, reloadWidget: {})
            await restarted.refresh()
            await restarted.waitForHistoryBackfill()
            let afterRestart = await newService.requestCount()
            try requireHistory(afterRestart == 8, "Recalculated history was not reusable after restart")
        }
        await check("History: missing differs from zero; partial yesterday must be refetched") {
            let now = ISO8601DateFormatter().date(from: "2026-09-29T10:00:00Z")!
            let today = UsageDay(date: now)
            let context = UsageDataContext(timezone: "UTC", customPath: "")
            var history = UsageHistory(context: context)
            var zero = UsageSnapshot(generatedAt: now, day: today.adding(days: -2), sessions: [])
            zero.dataContext = context
            history.record(zero, today: today)
            var partial = zero
            partial.day = today.adding(days: -1)
            partial.generatedAt = partial.day.date.addingTimeInterval(3600)
            history.record(partial, today: today)
            let points = history.points(ending: today)
            try requireHistory(points.count == 7 && points.filter { $0.total == nil }.count == 5, "Missing days became zero")
            try requireHistory(points[4].total?.usage.cost == 0, "Confirmed zero lost")
            try requireHistory(history.missingCompletedDays(ending: today, now: now).contains(partial.day), "Partial yesterday frozen as final")
            try requireHistory(!history.missingCompletedDays(ending: today, now: now).contains(zero.day), "Fresh completed day fetched again")
            try requireHistory(history.missingCompletedDays(ending: today, now: now.addingTimeInterval(6 * 3600)).contains(zero.day), "Late logs never refresh")
            try requireHistory(points.knownUsage.costIsIncomplete == true, "Missing-day sum is not a lower bound")
        }
        await check("History: DST range and source/timezone isolation") {
            let now = ISO8601DateFormatter().date(from: "2026-03-10T10:00:00Z")!
            let today = UsageDay(date: now, timezone: "America/New_York")
            let context = UsageDataContext(timezone: today.timezone, customPath: "/one")
            var history = UsageHistory(context: context)
            var data = UsageSnapshot(generatedAt: now, day: today.adding(days: -1), sessions: [])
            data.dataContext = .init(timezone: today.timezone, customPath: "/two")
            history.record(data, today: today)
            try requireHistory(history.days.isEmpty, "Cross-source history accepted")
            data.dataContext = context
            history.record(data, today: today)
            let keys = history.points(ending: today).map { $0.day.key }
            try requireHistory(keys == ["20260304", "20260305", "20260306", "20260307", "20260308", "20260309", "20260310"], "DST skipped/duplicated a day")
            data.day = UsageDay(date: now)
            history.record(data, today: today)
            try requireHistory(history.days.count == 1, "Cross-timezone snapshot accepted")
        }
        await check("Budget: opt-in finite amount, overrun and incomplete prices") {
            for invalid in [0.0, -1, Double.infinity, Double.nan] {
                try requireHistory(DailyBudget(limit: invalid, usage: .zero) == nil, "Invalid budget accepted")
            }
            let over = DailyBudget(limit: 10, usage: TokenUsage(cost: 12))!
            let partial = DailyBudget(limit: 10, usage: TokenUsage(cost: 3, costIsIncomplete: true))!
            let partialOver = DailyBudget(limit: 10, usage: TokenUsage(cost: 12, costIsIncomplete: true))!
            try requireHistory(over.isOver && over.fraction == 1 && over.difference == 2, "Overrun clipped into remaining allowance")
            try requireHistory(!partial.caption.contains("Осталось") && !partialOver.caption.contains("≥") && partialOver.caption.contains(UsageFormat.cost(2)), "Budget diagnostics changed the currency format or promised remaining budget")
        }
        await check("History: atomic round-trip and invalid cache rejection") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = SnapshotRepository(directory: directory)
            let history = SampleData.history(now: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
            try await repository.writeHistory(history)
            let restored = try await repository.readHistory()
            try requireHistory(restored == history, "History round-trip")
            var bad = history
            bad.days.append(bad.days[0])
            try await repository.writeHistory(bad)
            do {
                _ = try await repository.readHistory()
                throw HistoryCheckFailure(message: "Duplicate/oversized history accepted")
            } catch is UsageError { }
        }
        await check("Store history: today first, bounded backfill, restart reuse") {
            let suite = "LLMUsage.HistoryChecks.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let service = HistoryFixtureService()
            await service.configure(historicalDelay: .milliseconds(40))
            let repository = HistoryMemoryRepository()
            let store = UsageStore(service: service, repository: repository, defaults: defaults, reloadWidget: {})
            try requireHistory(store.dailyBudget == nil, "Budget enabled by default")
            await store.refresh()
            try requireHistory(store.todaySnapshot != nil && !store.isRefreshing && store.history?.days.count == 1, "History blocked today's UI")
            await store.waitForHistoryBackfill()
            let initial = await service.requestCount()
            try requireHistory(initial == 7 && store.history?.days.count == 7, "Backfill failed to cover seven days")
            await store.refresh()
            await store.waitForHistoryBackfill()
            let refreshed = await service.requestCount()
            try requireHistory(refreshed == 8, "Completed days scanned on every refresh")
            let restarted = UsageStore(service: service, repository: repository, defaults: defaults, reloadWidget: {})
            await restarted.refresh()
            await restarted.waitForHistoryBackfill()
            let afterRestart = await service.requestCount()
            try requireHistory(afterRestart == 9 && restarted.history?.days.count == 7, "Persisted cache not reused after restart")
        }
        await check("Store history: a failed day preserves successes and uses retry cooldown") {
            let suite = "LLMUsage.HistoryChecks.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let service = HistoryFixtureService()
            let failed = UsageDay().adding(days: -3)
            await service.configure(failedDays: [failed.cacheKey])
            let repository = HistoryMemoryRepository()
            let store = UsageStore(service: service, repository: repository, defaults: defaults, reloadWidget: {})
            await store.refresh()
            await store.waitForHistoryBackfill()
            try requireHistory(store.history?.days.count == 6 && store.error == nil, "Background failure discarded success")
            try requireHistory(store.history?.points(ending: UsageDay()).first { $0.day == failed }?.total == nil, "Failed day fabricated as zero")
            await store.refresh()
            await store.waitForHistoryBackfill()
            let requests = await service.requestCount()
            try requireHistory(requests == 8, "Failed day retried on each today refresh")
        }
        await check("Store history: configuration change rejects late source results") {
            let suite = "LLMUsage.HistoryChecks.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let service = HistoryFixtureService()
            await service.configure(historicalDelay: .milliseconds(70))
            let repository = HistoryMemoryRepository()
            let store = UsageStore(service: service, repository: repository, defaults: defaults, reloadWidget: {})
            await store.refresh()
            try await Task.sleep(for: .milliseconds(10))
            store.customPath = "/fixture/new-source"
            store.timezone = "Europe/Moscow"
            try requireHistory(store.history == nil && store.todaySnapshot == nil, "Old configuration remains visible")
            await store.refresh()
            await store.waitForHistoryBackfill()
            let saved = await repository.readHistory()
            let today = await repository.read(.today)
            try requireHistory(saved?.context == store.dataContext && saved?.days.count == 7, "Old background result crossed configuration")
            try requireHistory(today?.dataContext == store.dataContext && today?.sessions.first?.usage.cost == 80, "Old source snapshot persisted as new")
        }
        await check("Store history: damaged history cannot hide a cached today's snapshot") {
            let suite = "LLMUsage.HistoryChecks.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
            let repository = SnapshotRepository(directory: directory)
            var cached = SampleData.multiSourceSnapshot(now: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
            cached.dataContext = .init(timezone: "UTC", customPath: "")
            try await repository.write(cached, to: .today)
            try SnapshotFiles.write(["invalid": true], name: "daily-history-v1.json", directory: directory)
            let service = HistoryFixtureService()
            await service.configure(failedDays: [UsageDay().cacheKey])
            let store = UsageStore(service: service, repository: repository, defaults: defaults, reloadWidget: {})
            await store.refresh()
            try requireHistory(store.todaySnapshot == cached && store.snapshot == cached && store.state == .stale,
                               "Optional history failure discarded a valid saved snapshot")
        }
        await check("Store preferences: budget publishes during failed/in-flight refresh") {
            let suite = "LLMUsage.HistoryChecks.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let service = RefreshFixtureService(today: UsageDay())
            await service.configure(failure: .timedOut, holdNext: true)
            let repository = HistoryMemoryRepository()
            let store = UsageStore(service: service, repository: repository, defaults: defaults, reloadWidget: {})
            let task = Task { await store.refresh() }
            defer {
                task.cancel()
                Task { await service.finishHeldRequest() }
            }
            await service.waitUntilHeld()
            try requireHistory(store.setBudgetAmount(17.5) && !store.setBudgetAmount(.infinity), "Budget validation")
            store.budgetEnabled = true
            store.menuContent = .trend
            try await waitForCheck("Budget was not published while CLI was held") {
                await repository.readStatus()?.dailyBudget == 17.5
            }
            let during = await repository.readStatus()
            try requireHistory(during?.dailyBudget == 17.5 && store.isRefreshing, "Budget waits for CLI")
            await service.finishHeldRequest()
            await task.value
            let after = await repository.readStatus()
            try requireHistory(after?.dailyBudget == 17.5 && after?.message != nil, "Failed fetch erased budget")
            let restarted = UsageStore(service: service, repository: repository, defaults: defaults, reloadWidget: {})
            try requireHistory(restarted.dailyBudget == 17.5 && restarted.menuContent == .trend, "Preference persistence")
        }
    }
}
