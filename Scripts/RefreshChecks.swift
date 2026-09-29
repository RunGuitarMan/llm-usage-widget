import Foundation

private struct RefreshCheckFailure: Error, CustomStringConvertible { var description: String }
private func requireRefresh(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw RefreshCheckFailure(description: message) }
}

@MainActor private final class RefreshCheckClock {
    var date = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
}

// Shared by checks that need to hold a CLI request until an explicit signal.
actor RefreshFixtureService: CCUsageServing {
    var cost = 1.0
    var failure: UsageError?
    var todayRequests = 0
    var holdNext = false
    var release: CheckedContinuation<Void, Never>?
    var waiting: CheckedContinuation<Void, Never>?
    let today: UsageDay
    init(today: UsageDay = UsageDay(date: ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!)) {
        self.today = today
    }
    func configure(cost: Double = 1, failure: UsageError? = nil, holdNext: Bool = false) {
        self.cost = cost; self.failure = failure; self.holdNext = holdNext
    }
    func requestCount() -> Int { todayRequests }
    func waitUntilHeld() async {
        if release != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func finishHeldRequest() { release?.resume(); release = nil }
    func fetch(day: UsageDay, customPath: String) async throws -> UsageSnapshot {
        if day == today {
            todayRequests += 1
            if holdNext {
                holdNext = false
                await withCheckedContinuation { continuation in
                    release = continuation
                    waiting?.resume(); waiting = nil
                }
            }
            if let failure { throw failure }
        }
        var data = SampleData.multiSourceSnapshot(now: today.date.addingTimeInterval(12 * 3600))
        data.day = day
        for index in data.sessions.indices { data.sessions[index].usage.cost = 0 }
        data.sessions[0].usage.cost = day == today ? cost : 1
        return data
    }
    func diagnose(customPath: String, forceDetect: Bool) -> CLIDiagnostics { .init(path: "fixture", version: "1") }
}

private actor RefreshMemoryRepository: SnapshotPersisting {
    var snapshots: [String: UsageSnapshot] = [:]
    var status: RefreshStatus?
    var history: UsageHistory?
    func read(_ slot: SnapshotSlot) -> UsageSnapshot? { snapshots[slot.rawValue] }
    func write(_ snapshot: UsageSnapshot, to slot: SnapshotSlot) { snapshots[slot.rawValue] = snapshot }
    func readStatus() -> RefreshStatus? { status }
    func writeStatus(_ status: RefreshStatus) { self.status = status }
    func readHistory() -> UsageHistory? { history }
    func writeHistory(_ history: UsageHistory) { self.history = history }
}

enum RefreshChecks {
    @MainActor static func run(check: (String, () async throws -> Void) async -> Void) async {
        let origin = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!
        func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }
        func initialSchedule() -> RefreshSchedule {
            var schedule = RefreshSchedule()
            schedule.reset(day: UsageDay(date: origin), at: origin)
            schedule.succeeded(cost: 1, reason: .startup, at: origin)
            return schedule
        }
        func fastSchedule() -> RefreshSchedule {
            var schedule = initialSchedule()
            schedule.succeeded(cost: 2, reason: .automatic, at: at(180))
            return schedule
        }
        await check("Refresh: defaults and exact fast/medium/slow boundaries") {
            var schedule = initialSchedule()
            try requireRefresh(schedule.mode == .slow && schedule.nextRefresh == at(180), "Must start slow")
            schedule.succeeded(cost: 2, reason: .automatic, at: at(180))
            try requireRefresh(schedule.mode == .fast && schedule.nextRefresh == at(185), "Change did not accelerate")
            for second in stride(from: 185, through: 235, by: 5) {
                schedule.succeeded(cost: 2, reason: .automatic, at: at(Double(second)))
                try requireRefresh(schedule.mode == .fast, "Fast mode ended before one minute")
            }
            schedule.succeeded(cost: 2, reason: .automatic, at: at(240))
            try requireRefresh(schedule.mode == .medium && schedule.nextRefresh == at(300), "One-minute transition")
            for second in [300.0, 360] { schedule.succeeded(cost: 2, reason: .automatic, at: at(second)) }
            try requireRefresh(schedule.mode == .medium, "Medium ended before three additional minutes")
            schedule.succeeded(cost: 2, reason: .automatic, at: at(420))
            try requireRefresh(schedule.mode == .slow && schedule.nextRefresh == at(600), "Slow transition/cadence")
        }
        await check("Refresh: changes restart the quiet window and accelerate from medium") {
            var schedule = fastSchedule()
            schedule.succeeded(cost: 3, reason: .automatic, at: at(235))
            schedule.succeeded(cost: 3, reason: .automatic, at: at(290))
            try requireRefresh(schedule.mode == .fast, "Last change did not restart the minute")
            schedule.succeeded(cost: 3, reason: .automatic, at: at(295))
            try requireRefresh(schedule.mode == .medium, "Quiet window did not complete")
            schedule.succeeded(cost: 2.5, reason: .automatic, at: at(355))
            try requireRefresh(schedule.mode == .fast && schedule.nextRefresh == at(360), "Decreases must also count")
        }
        await check("Refresh: manual requests skip one fast slot without shifting cadence") {
            var schedule = fastSchedule()
            schedule.manualRefreshStarted()
            schedule.succeeded(cost: 3, reason: .manual, at: at(182))
            schedule.manualRefreshStarted()
            try requireRefresh(!schedule.consumeSkippedRefresh(at: at(184)), "Slot skipped before due")
            try requireRefresh(schedule.consumeSkippedRefresh(at: at(185)), "Next fast slot not skipped")
            try requireRefresh(schedule.nextRefresh == at(190), "Cadence shifted to manual completion")
            try requireRefresh(!schedule.consumeSkippedRefresh(at: at(190)), "Multiple clicks skipped extra slots")
            schedule.succeeded(cost: 3, reason: .automatic, at: at(190))
            schedule.succeeded(cost: 3, reason: .automatic, at: at(245))
            try requireRefresh(schedule.mode == .fast, "Manual result hid a change from automatic comparison")
            schedule.succeeded(cost: 3, reason: .automatic, at: at(250))
            try requireRefresh(schedule.mode == .medium, "Automatic change did not restart quiet window")
        }
        await check("Refresh: manual requests do not restart fast inactivity") {
            var schedule = fastSchedule()
            schedule.manualRefreshStarted()
            schedule.succeeded(cost: 99, reason: .manual, at: at(232))
            _ = schedule.consumeSkippedRefresh(at: at(235))
            schedule.succeeded(cost: 2, reason: .automatic, at: at(240))
            try requireRefresh(schedule.mode == .medium, "Manual request changed the quiet window")
        }
        await check("Refresh: manual and selection results leave medium/slow schedules untouched") {
            for medium in [false, true] {
                var schedule = medium ? fastSchedule() : initialSchedule()
                if medium { schedule.succeeded(cost: 2, reason: .automatic, at: at(240)) }
                let deadline = schedule.nextRefresh
                let mode = schedule.mode
                schedule.manualRefreshStarted()
                schedule.succeeded(cost: 100, reason: .manual, at: at(medium ? 260 : 100))
                schedule.succeeded(cost: 101, reason: .selection, at: at(medium ? 270 : 110))
                try requireRefresh(schedule.mode == mode && schedule.nextRefresh == deadline, "Manual/selection changed schedule")
                try requireRefresh(!schedule.consumeSkippedRefresh(at: deadline!), "Non-fast slot skipped")
                schedule.succeeded(cost: 101, reason: .automatic, at: deadline!)
                try requireRefresh(schedule.mode == .fast, "Manual result hid cost changes")
            }
        }
        await check("Refresh: failed queries cannot prove inactivity") {
            var schedule = fastSchedule()
            schedule.failed(reason: .automatic, at: at(235))
            try requireRefresh(schedule.mode == .fast && schedule.nextRefresh == at(240), "Failure changed mode or retried immediately")
            schedule.succeeded(cost: 2, reason: .automatic, at: at(240))
            schedule.succeeded(cost: 2, reason: .automatic, at: at(295))
            try requireRefresh(schedule.mode == .fast, "Failure counted as a quiet minute")
            schedule.succeeded(cost: 2, reason: .automatic, at: at(300))
            try requireRefresh(schedule.mode == .medium, "Recovery never resumed quiet window")
        }
        await check("Refresh: slow CLI and wake coalesce overdue slots") {
            var schedule = fastSchedule()
            schedule.succeeded(cost: 2, reason: .automatic, at: at(207))
            try requireRefresh(schedule.nextRefresh == at(210), "Overdue requests queued or cadence lost")
            schedule.succeeded(cost: 3, reason: .automatic, at: at(3600))
            try requireRefresh(schedule.mode == .fast && schedule.nextRefresh == at(3605), "Wake created a backlog")
        }
        await check("Refresh: sub-cent changes count but floating-point noise does not") {
            var schedule = initialSchedule()
            schedule.succeeded(cost: 1 + 1e-12, reason: .automatic, at: at(180))
            try requireRefresh(schedule.mode == .slow, "Floating-point noise accelerated polling")
            schedule.succeeded(cost: 1.0001, reason: .automatic, at: at(360))
            try requireRefresh(schedule.mode == .fast, "Displayed cents hid a real cost change")
        }
        await check("Refresh: day/context reset and configuration changes") {
            var schedule = fastSchedule()
            schedule.manualRefreshStarted()
            let nextDay = UsageDay(date: origin).adding(days: 1)
            schedule.prepare(day: nextDay, at: nextDay.date)
            schedule.succeeded(cost: 0, reason: .automatic, at: nextDay.date)
            try requireRefresh(schedule.mode == .slow && schedule.nextRefresh == nextDay.date.addingTimeInterval(180), "Midnight compared unrelated totals")
            schedule.configure(.init(fastSeconds: 10, mediumMinutes: 2, slowMinutes: 5), at: nextDay.date)
            try requireRefresh(schedule.nextRefresh == nextDay.date.addingTimeInterval(300), "Changed interval not applied")
            schedule.succeeded(cost: 1, reason: .automatic, at: nextDay.date.addingTimeInterval(300))
            try requireRefresh(schedule.interval == 10, "Custom fast interval ignored")
            schedule.reset(day: nextDay, at: nextDay.date.addingTimeInterval(301))
            schedule.succeeded(cost: 50, reason: .configuration, at: nextDay.date.addingTimeInterval(301))
            try requireRefresh(schedule.mode == .slow, "New source compared against old baseline")
        }
        await check("Refresh: preferences migrate to new defaults and persist all speeds") {
            let suite = "LLMUsage.RefreshPreferences.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(15, forKey: "refreshMinutes")
            let store = UsageStore(defaults: defaults, demo: true)
            try requireRefresh(store.refreshIntervals == .standard, "Legacy preference overrode new defaults")
            try requireRefresh(store.setRefreshIntervals(fastSeconds: 10, mediumMinutes: 2, slowMinutes: 5), "Valid settings rejected")
            try requireRefresh(!store.setRefreshIntervals(mediumMinutes: 5), "Equal speeds accepted")
            let reopened = UsageStore(defaults: defaults, demo: true)
            try requireRefresh(reopened.refreshIntervals == store.refreshIntervals, "Settings did not persist")
            defaults.set(-10, forKey: "fastRefreshSeconds")
            try requireRefresh(RefreshIntervals.load(from: defaults) == .standard, "Corrupt settings accepted")
        }
        await check("Refresh: widget status supports seconds and old minute-only files") {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let legacy = try decoder.decode(RefreshStatus.self, from: Data(#"{"attemptedAt":"2026-09-29T12:00:00Z","refreshMinutes":15}"#.utf8))
            try requireRefresh(legacy.refreshInterval == 900, "Old widget status no longer readable")
            let status = RefreshStatus(attemptedAt: origin, message: nil, refreshMinutes: 3, refreshIntervalSeconds: 5)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let restored = try decoder.decode(RefreshStatus.self, from: encoder.encode(status))
            try requireRefresh(restored == status && restored.refreshInterval == 5, "Seconds lost during persistence")
        }
        await check("Refresh store: real manual/automatic routing, aggregate cost, and widget interval") {
            let clock = RefreshCheckClock(), service = RefreshFixtureService(), repository = RefreshMemoryRepository()
            let suite = "LLMUsage.RefreshStore.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = UsageStore(service: service, repository: repository, defaults: defaults, now: { clock.date }, reloadWidget: {})
            await store.refresh(reason: .startup)
            await store.waitForHistoryBackfill()
            store.sourceFilter = "nonexistent"
            await service.configure(cost: 2)
            clock.advance(100)
            await store.refresh()
            try requireRefresh(store.refreshMode == .slow && store.nextAutomaticRefresh == at(180), "Manual changed slow cadence")
            clock.advance(80)
            await store.refreshAutomaticallyIfDue()
            try requireRefresh(store.refreshMode == .fast && store.nextAutomaticRefresh == at(185), "Manual hid change, or filtered amount used")
            clock.advance(3)
            await store.refresh()
            let count = await service.requestCount()
            clock.advance(2)
            await store.refreshAutomaticallyIfDue()
            let skippedCount = await service.requestCount()
            try requireRefresh(count == skippedCount && store.nextAutomaticRefresh == at(190), "Fast slot was not skipped")
            clock.advance(5)
            await store.refreshAutomaticallyIfDue()
            let resumedCount = await service.requestCount()
            let status = await repository.readStatus()
            try requireRefresh(resumedCount == count + 1 && status?.refreshInterval == 5, "Fast cadence/status did not resume")
            await store.waitForHistoryBackfill()
        }
        await check("Refresh store: overlapping manual request preserves due slow slot and rejects duplicates") {
            let clock = RefreshCheckClock(), service = RefreshFixtureService()
            let suite = "LLMUsage.RefreshOverlap.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = UsageStore(service: service, repository: RefreshMemoryRepository(), defaults: defaults, now: { clock.date }, reloadWidget: {})
            await store.refresh(reason: .startup)
            await store.waitForHistoryBackfill()
            clock.advance(179)
            await service.configure(holdNext: true)
            let manual = Task { await store.refresh() }
            await service.waitUntilHeld()
            clock.advance(2)
            await store.refresh()
            await store.refreshAutomaticallyIfDue()
            let count = await service.requestCount()
            try requireRefresh(count == 2 && store.nextAutomaticRefresh == at(180), "Overlap launched duplicate or moved deadline")
            await service.finishHeldRequest()
            await manual.value
            await store.refreshAutomaticallyIfDue()
            let finalCount = await service.requestCount()
            try requireRefresh(finalCount == 3 && store.nextAutomaticRefresh == at(360), "Overlapped automatic slot lost original cadence")
            await store.waitForHistoryBackfill()
        }
        await check("Refresh store: in-flight midnight result cannot seed the next day") {
            let clock = RefreshCheckClock(), service = RefreshFixtureService()
            let suite = "LLMUsage.RefreshMidnight.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = UsageStore(service: service, repository: RefreshMemoryRepository(), defaults: defaults, now: { clock.date }, reloadWidget: {})
            await store.refresh(reason: .startup)
            await store.waitForHistoryBackfill()
            let oldSnapshot = store.todaySnapshot
            await service.configure(cost: 50, holdNext: true)
            let automatic = Task { await store.refresh(reason: .automatic) }
            await service.waitUntilHeld()
            clock.advance(24 * 3600)
            await service.finishHeldRequest()
            await automatic.value
            try requireRefresh(store.todaySnapshot == oldSnapshot && store.state == .stale, "Old day's late result published")
            await store.refreshAutomaticallyIfDue()
            try requireRefresh(store.todaySnapshot?.day == UsageDay(date: clock.date) && store.refreshMode == .slow, "New day did not establish a slow baseline")
            await store.waitForHistoryBackfill()
        }
        await check("Refresh store: actual timer starts once, skips a manual slot, then resumes") {
            let service = RefreshFixtureService(today: UsageDay()), repository = RefreshMemoryRepository()
            let suite = "LLMUsage.RefreshTimer.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = UsageStore(service: service, repository: repository, defaults: defaults, reloadWidget: {})
            store.setRefreshIntervals(fastSeconds: 2)
            store.start()
            store.start()
            for _ in 0..<300 {
                if await service.requestCount() == 1, !store.isRefreshing { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let startupCount = await service.requestCount()
            try requireRefresh(startupCount == 1 && !store.isRefreshing, "Duplicate/missing initial refresh")
            await store.waitForHistoryBackfill()
            await service.configure(cost: 2)
            await store.refresh(reason: .automatic)
            try requireRefresh(store.refreshMode == .fast, "Timer fixture did not accelerate")
            await store.refresh()
            let manualCount = await service.requestCount()
            try await Task.sleep(for: .milliseconds(2300))
            let skippedCount = await service.requestCount()
            try requireRefresh(skippedCount == manualCount, "Sleeping timer did not skip manual slot")
            for _ in 0..<300 {
                if await service.requestCount() > manualCount, !store.isRefreshing { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let resumedCount = await service.requestCount()
            try requireRefresh(resumedCount == manualCount + 1 && !store.isRefreshing, "Timer did not resume or duplicated requests")
            await store.waitForHistoryBackfill()
        }
    }
}
