import Foundation
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#elseif !PORTABLE_CHECKS && !MANUAL_REVIEW
@testable import LLMUsage
#endif

private struct HealthCheckFailure: Error, CustomStringConvertible { var description: String }
private func requireHealth(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw HealthCheckFailure(description: message) }
}

private actor HealthService: CCUsageServing {
    var date: Date
    var failures: [String: UsageError] = [:]
    var held = false
    var incomplete: [String: UsageCostReason] = [:]
    var calls: [String: Int] = [:]
    init(date: Date) { self.date = date }
    func fail(_ error: UsageError?, day: UsageDay) { failures[day.cacheKey] = error }
    func hold(_ held: Bool) { self.held = held }
    func cost(_ reason: UsageCostReason?, day: UsageDay) { incomplete[day.cacheKey] = reason }
    func setDate(_ date: Date) { self.date = date }
    func count(_ day: UsageDay) -> Int { calls[day.cacheKey, default: 0] }
    func fetch(day: UsageDay, customPath: String, mode: UsageUpdateMode) async throws -> UsageSnapshot {
        calls[day.cacheKey, default: 0] += 1
        while held { try await Task.sleep(for: .milliseconds(10)) }
        if let error = failures[day.cacheKey] { throw error }
        var data = SampleData.snapshot(now: date)
        data.day = day
        if let reason = incomplete[day.cacheKey] {
            data.sessions[0].usage.costIsIncomplete = true
            data.sessions[0].costReasons = [reason]
        }
        return data
    }
    func diagnose(customPath: String, forceDetect: Bool) -> CLIDiagnostics { .init(path: "fixture", version: "1") }
}

private actor HealthRepository: SnapshotPersisting {
    var snapshots: [SnapshotSlot: UsageSnapshot] = [:]
    var status: RefreshStatus?
    var history: UsageHistory?
    var statusUnavailable = false
    func failStatus(_ unavailable: Bool) { statusUnavailable = unavailable }
    func read(_ slot: SnapshotSlot) -> UsageSnapshot? { snapshots[slot] }
    func write(_ snapshot: UsageSnapshot, to slot: SnapshotSlot) { snapshots[slot] = snapshot }
    func readStatus() -> RefreshStatus? { status }
    func writeStatus(_ status: RefreshStatus) throws {
        if statusUnavailable { throw UsageError.sharedContainer("fixture: status is unwritable") }
        self.status = status
    }
    func readHistory() -> UsageHistory? { history }
    func writeHistory(_ history: UsageHistory) { self.history = history }
}

enum UsageHealthScenarios {
    @MainActor static func run(check: (String, () async throws -> Void) async -> Void) async {
        let now = ISO8601DateFormatter().date(from: "2026-10-06T12:00:00Z")!
        let today = UsageDay(date: now, timezone: "UTC")
        let context = UsageDataContext(timezone: "UTC", customPath: "")
        func snapshot(_ generatedAt: Date = now) -> UsageSnapshot {
            var data = SampleData.snapshot(now: generatedAt)
            data.day = today
            data.dataContext = context
            return data
        }
        func status(_ data: UsageSnapshot, failures: [UsageRefreshFailure] = []) -> RefreshStatus {
            .init(attemptedAt: now, message: nil, refreshMinutes: 3, dataContext: context,
                  presentation: .init(snapshot: data, previous: nil, history: nil, failures: failures, lastAttempt: now))
        }
        await check("Health: pure age, exact deadline and midnight share one policy") {
            let data = snapshot(now.addingTimeInterval(-601))
            let issues = UsageHealth.problems(snapshot: data, status: status(data), now: now)
            try requireHealth(issues.map(\.reference.kind) == [.stale], "Pure stale state requires a CLI error")
            let fresh = snapshot()
            let deadline = UsageHealth.staleDate(generatedAt: now, interval: 180)
            try requireHealth(UsageHealth.problems(snapshot: fresh, now: deadline.addingTimeInterval(-1)).isEmpty, "Stale before deadline")
            try requireHealth(UsageHealth.problems(snapshot: fresh, now: deadline).first?.reference.kind == .stale, "Missed stale transition")
            try requireHealth(UsageHealth.transitionDates(snapshot: fresh, history: nil, status: nil, now: now).contains(deadline), "Widget timeline missed deadline")
            let midnight = today.end
            var late = fresh; late.generatedAt = midnight.addingTimeInterval(-5)
            try requireHealth(UsageHealth.problems(snapshot: late, now: midnight).first?.reference.day == today, "Midnight relabeled old data")
            try requireHealth(!UsageHealth.transitionDates(snapshot: nil, history: nil, status: nil, now: now).isEmpty, "Empty timeline lost rollover")
        }
        await check("Health: simultaneous failures, stale data and unknown prices are retained and ordered") {
            var data = snapshot(now.addingTimeInterval(-7200))
            data.sessions[0].usage.costIsIncomplete = true
            var state = status(data, failures: [.init(day: today, attemptedAt: now, error: .timedOut)])
            state.presentation?.storageError = .sharedContainer("fixture")
            let issues = UsageHealth.problems(snapshot: data, status: state, now: now)
            try requireHealth(issues.map(\.reference.kind) == [.storage, .refresh, .stale, .cost], "One warning masked another")
            try requireHealth(issues.last?.models.isEmpty == false, "Missing-price models were lost")
            let encoded = try JSONEncoder().encode(state)
            let restored = try JSONDecoder().decode(RefreshStatus.self, from: encoded)
            try requireHealth(UsageHealth.problems(snapshot: restored.presentation?.snapshot, status: restored, now: now) == issues, "Persisted widget/app problem parity failed")
            let savedLanguage = L10n.preference
            defer { L10n.preference = savedLanguage }
            L10n.preference = .english
            try requireHealth(issues[1].title == "ccusage timed out", "Error stayed in the saved language")
            for problem in issues {
                try requireHealth(problem.explanation.range(of: "[А-Яа-я]", options: .regularExpression) == nil, "Untranslated problem explanation")
            }
        }
        await check("Health: historic incomplete prices are reported without false historical staleness") {
            let fresh = snapshot()
            var history = UsageHistory(context: context)
            var old = fresh; old.day = today.adding(days: -2); old.sessions[0].usage.costIsIncomplete = true
            history.record(old, today: today, now: now)
            let issues = UsageHealth.problems(snapshot: fresh, history: history, status: status(fresh), now: now)
            try requireHealth(issues.contains { $0.reference == .init(kind: .cost, day: old.day) }, "Historical unknown price disappeared")
            try requireHealth(!issues.contains { $0.reference.kind == .stale }, "A historical date was treated as stale live data")
            try requireHealth(issues.contains { $0.reference.kind == .history && !$0.missingDays.isEmpty }, "History gaps missing from shared issues")
        }
        await check("Health: atomic envelope wins over independently replaced legacy files") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("health-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = SnapshotRepository(directory: directory)
            let old = snapshot(now.addingTimeInterval(-7200)), fresh = snapshot()
            try await repository.writeStatus(status(old, failures: [.init(day: today, attemptedAt: now, error: .timedOut)]))
            try await repository.write(fresh, to: .today)
            let published = try SnapshotFiles.presentation(directory: directory)
            try requireHealth(published.snapshot == old, "Reader mixed fresh legacy data with older diagnostics")
            try await repository.writeStatus(status(fresh))
            let updated = try SnapshotFiles.presentation(directory: directory)
            try requireHealth(updated.snapshot == fresh && UsageHealth.problems(snapshot: updated.snapshot, status: updated.status, now: now).isEmpty, "Successful envelope retained warning")
            try Data("corrupt legacy snapshot".utf8).write(to: directory.appendingPathComponent(SnapshotSlot.today.rawValue), options: .atomic)
            let intact = try SnapshotFiles.presentation(directory: directory)
            try requireHealth(intact.snapshot == fresh && !intact.storageUnavailable, "Damaged legacy snapshot overrode the valid envelope")
            try await repository.write(fresh, to: .today)
            try Data("corrupt status".utf8).write(to: directory.appendingPathComponent("refresh-status.json"), options: .atomic)
            do { _ = try SnapshotFiles.presentation(directory: directory); throw HealthCheckFailure(description: "Corrupt envelope fell back to a legacy snapshot") }
            catch is UsageError { }
            var corrupt = status(fresh)
            corrupt.presentation?.snapshot?.sessions.append(fresh.sessions[0])
            do { try await repository.writeStatus(corrupt); throw HealthCheckFailure(description: "Invalid publication accepted") }
            catch is UsageError { }
            try SnapshotFiles.write(corrupt, name: "refresh-status.json", directory: directory)
            do { _ = try SnapshotFiles.presentation(directory: directory); throw HealthCheckFailure(description: "Corrupt envelope accepted") }
            catch is UsageError { }
            try await repository.writeStatus(.init(attemptedAt: now, message: "legacy failure", refreshMinutes: 3, dataContext: context))
            let legacy = try SnapshotFiles.presentation(directory: directory)
            try requireHealth(legacy.snapshot == fresh && UsageHealth.problems(snapshot: legacy.snapshot, status: legacy.status, now: now).first?.legacyMessage == "legacy failure", "Legacy status lost its failure")
            try Data("corrupt history".utf8).write(to: directory.appendingPathComponent("daily-history-v1.json"))
            let recovered = try SnapshotFiles.presentation(directory: directory)
            try requireHealth(recovered.snapshot == fresh && recovered.storageUnavailable, "Damaged optional legacy history discarded a valid current report")
        }
        await check("Health: dated problem links round-trip and reject malformed contexts") {
            for kind in UsageProblemKind.allCases {
                for day in [nil, Optional(today)] {
                    let route = UsageRoute.problem(.init(kind: kind, day: day))
                    try requireHealth(UsageRoute(url: route.url) == route, "Problem route lost context")
                }
            }
            for text in ["llmusage://problem/unknown", "llmusage://problem/stale/extra", "llmusage://problem/stale?day=20260230&timezone=UTC", "llmusage://problem/stale?day=20261006&timezone=UTC&day=20261006"] {
                try requireHealth(UsageRoute(url: URL(string: text)!) == nil, "Accepted malformed problem route")
            }
        }
        await check("Widget activation: cold URL survives reopen until navigation is ready") {
            let activation = UsageActivation()
            let route = UsageRoute.datedSession("fixture-session", today.adding(days: -1))
            var received: [UsageRoute?] = []
            activation.open(route.url)
            activation.open(URL(string: "https://example.com")!)
            activation.present() // AppKit may also send a reopen during launch.
            try requireHealth(received.isEmpty, "Cold URL was delivered before a scene existed")
            activation.install { received.append($0) }
            try requireHealth(received == [route], "Cold URL or dated session was replaced by a plain reopen")
            activation.install { received.append($0) }
            try requireHealth(received.count == 1, "Reattaching the root replayed an old URL")
            activation.open(UsageRoute.settings.url)
            activation.present()
            try requireHealth(received == [route, .settings, nil], "Warm URL/reopen delivery failed")
        }
        await check("Widget activation: last launch URL wins; malformed URLs never open a window") {
            let activation = UsageActivation()
            var received: [UsageRoute?] = []
            activation.open(URL(string: "llmusage://problem/unknown")!)
            activation.install { received.append($0) }
            try requireHealth(received.isEmpty, "Invalid URL queued an activation")
            let cold = UsageActivation()
            cold.open(UsageRoute.overview.url)
            cold.open(UsageRoute.settings.url)
            cold.install { received.append($0) }
            try requireHealth(received == [.settings], "Launch opened an obsolete destination")
        }
        await check("Health: a repaired cost replaces the widget's incomplete amount and warning together") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("widget-parity-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = SnapshotRepository(directory: directory)
            var old = snapshot()
            old.sessions[0].usage.cost = 14
            old.sessions[0].usage.costIsIncomplete = true
            var fresh = old
            fresh.sessions[0].usage.cost = 29
            fresh.sessions[0].usage.costIsIncomplete = false
            var published = status(old)
            published.presentation?.costIssues = [UsageCostIssue(snapshot: old)!]
            try await repository.writeStatus(published)
            try await repository.write(fresh, to: .today)
            let before = try SnapshotFiles.presentation(directory: directory)
            try requireHealth(before.snapshot?.totals == old.totals, "Unpublished amount leaked into old warning")
            published.presentation?.snapshot = fresh
            published.presentation?.costIssues = []
            try await repository.writeStatus(published)
            let after = try SnapshotFiles.presentation(directory: directory)
            try requireHealth(after.snapshot?.totals == fresh.totals
                && !UsageHealth.problems(snapshot: after.snapshot, status: after.status, now: now).contains { $0.reference.kind == .cost },
                "Widget kept an old amount or an incomplete-cost warning after the successful report")
        }
        await check("Health: store preserves dated failures across restart and retries their actual day") {
            let suite = "health-\(UUID())"
            let prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            let service = HealthService(date: now), repository = HealthRepository()
            let store = UsageStore(service: service, repository: repository, defaults: prefs, now: { now }, reloadWidget: {})
            await store.refresh(); await store.waitForHistoryBackfill()
            let failedDay = today.adding(days: -10)
            await service.fail(.timedOut, day: failedDay)
            await store.selectCustomDate(failedDay.date)
            let expected = UsageProblemReference(kind: .refresh, day: failedDay)
            store.navigate(.overview)
            try requireHealth(store.problems().map(\.reference) == [expected], "Historic failure was hidden or attributed to today")
            let published = await repository.readStatus()
            try requireHealth(UsageHealth.problems(snapshot: published?.presentation?.snapshot, history: published?.presentation?.history, status: published, now: now) == store.problems(), "Store and persisted widget state disagree")
            let reopened = UsageStore(service: service, repository: repository, defaults: prefs, now: { now }, reloadWidget: {})
            reopened.navigate(.problem(expected))
            await reopened.restoreSavedData()
            try requireHealth(reopened.problems() == store.problems() && reopened.presentedProblem == expected, "Cold launch lost selected diagnostic")
            await service.fail(nil, day: failedDay)
            await reopened.retryProblem(expected)
            try requireHealth(reopened.problems().isEmpty && reopened.selectedDay == today, "Retry did not repair the failed day or changed the selected day")
        }
        await check("Health: browsing ten incomplete dates never contaminates today's app or widget") {
            let suite = "health-scope-\(UUID())", repository = HealthRepository(), service = HealthService(date: now)
            let prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            for offset in 1...10 { await service.cost(.sourceIncomplete, day: today.adding(days: -offset)) }
            let store = UsageStore(service: service, repository: repository, defaults: prefs, now: { now }, widgetReloadDelay: 0, reloadWidget: {})
            await store.refresh(); await store.waitForHistoryBackfill()
            for offset in 1...10 {
                let day = today.adding(days: -offset)
                await store.selectCustomDate(day.date)
                let scoped = store.problems(for: day)
                try requireHealth(scoped.map(\.reference) == [.init(kind: .cost, day: day)], "Selected day leaked other dates or became stale")
                try requireHealth(store.problems(for: today).isEmpty, "History browsing contaminated today's report")
                let widget = WidgetPresentation(status: store.presentationStatus, now: now)
                try requireHealth(widget.problems(at: now).isEmpty, "History browsing contaminated the widget")
            }
            try requireHealth(store.problems().filter { $0.reference.kind == .cost }.count == 10, "Explicit diagnostics lost historical issues")
            store.navigate(.overview)
            try requireHealth(store.problems(for: store.selectedDay).isEmpty, "Returning to today retained old warnings")
        }
        await check("Health: acknowledgements survive retries and restart; new causes are visible") {
            let suite = "health-dismiss-\(UUID())", repository = HealthRepository(), service = HealthService(date: now)
            let prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            await service.cost(.sourceIncomplete, day: today)
            let store = UsageStore(service: service, repository: repository, defaults: prefs, now: { now }, widgetReloadDelay: 0, reloadWidget: {})
            await store.refresh(); await store.waitForHistoryBackfill()
            let issue = store.problems(for: today).first!
            store.hideProblem(issue)
            await store.retryProblem(issue.reference)
            try requireHealth(store.problems(for: today, includeHidden: false).isEmpty, "Retry resurrected an acknowledged limitation")
            try requireHealth(WidgetPresentation(status: store.presentationStatus, now: now).problems(at: now).isEmpty, "Widget ignored acknowledgement")
            let reopened = UsageStore(service: service, repository: repository, defaults: prefs, now: { now }, widgetReloadDelay: 0, reloadWidget: {})
            await reopened.restoreSavedData()
            try requireHealth(reopened.problems(for: today, includeHidden: false).isEmpty && reopened.problems(for: today).count == 1, "Relaunch lost acknowledgement or hid detailed diagnostics")
            await service.cost(.sourceMismatch, day: today)
            await reopened.retryProblem(issue.reference)
            try requireHealth(reopened.problems(for: today, includeHidden: false).count == 1, "A different cause stayed hidden")
            try requireHealth(reopened.recoveryResult?.incomplete == 1 && reopened.recoveryResult?.failed == 0, "Partial retry has no explicit outcome")
            await service.cost(nil, day: today)
            await reopened.retryProblem(issue.reference)
            try requireHealth(reopened.recoveryResult?.repaired == 1 && reopened.problems(for: today).isEmpty, "Repair retained warning")
            await service.cost(.sourceIncomplete, day: today)
            await reopened.retryProblem(issue.reference)
            try requireHealth(reopened.problems(for: today, includeHidden: false).count == 1, "A new occurrence after repair stayed hidden")
        }
        await check("Health: explicit recovery forces all seven dates and reports partial and failed outcomes") {
            let suite = "health-recovery-\(UUID())", repository = HealthRepository(), service = HealthService(date: now)
            let prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            for offset in 0...6 { await service.cost(.missingPrice, day: today.adding(days: -offset)) }
            let store = UsageStore(service: service, repository: repository, defaults: prefs, now: { now }, widgetReloadDelay: 0, reloadWidget: {})
            await store.refresh(); await store.waitForHistoryBackfill()
            await store.retryAllProblems()
            for offset in 0...6 {
                let count = await service.count(today.adding(days: -offset))
                try requireHealth(count == 2, "Explicit recovery reused an incomplete historical report or fetched it twice")
            }
            try requireHealth(store.recoveryResult?.incomplete == 7 && store.recoveryCompleted == 7, "Recovery did not report unchanged partial data")
            for offset in 0...4 { await service.cost(nil, day: today.adding(days: -offset)) }
            await service.fail(.timedOut, day: today.adding(days: -6))
            await store.retryAllProblems()
            try requireHealth(store.recoveryResult?.repaired == 5 && store.recoveryResult?.incomplete == 1 && store.recoveryResult?.failed == 1,
                              "Mixed recovery outcomes were collapsed into success")
            try requireHealth(store.problems(for: today).isEmpty, "A historical retry failure contaminated today")
            await repository.failStatus(true)
            await store.retryProblem(.init(kind: .cost, day: today))
            await repository.failStatus(false)
            await store.retryAllProblems()
            try requireHealth(store.recoveryResult?.days.contains(today) == true && store.storageError == nil, "Bulk recovery did not retry a global storage problem")
        }
        await check("Health: repaired restored issues never return after cache eviction or relaunch") {
            let suite = "health-eviction-\(UUID())", repository = HealthRepository(), service = HealthService(date: now.addingTimeInterval(-1))
            let prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            let day = today.adding(days: -10)
            var old = snapshot(); old.day = day; old.sessions[0].usage.costIsIncomplete = true
            var saved = status(snapshot())
            saved.presentation?.costIssues = [UsageCostIssue(snapshot: old)!]
            try await repository.writeStatus(saved)
            let store = UsageStore(service: service, repository: repository, defaults: prefs, now: { now }, widgetReloadDelay: 0, reloadWidget: {})
            await store.restoreSavedData()
            let reference = UsageProblemReference(kind: .cost, day: day)
            await store.retryProblem(reference)
            await service.setDate(now)
            for offset in 11...50 { await store.retryProblem(.init(kind: .cost, day: today.adding(days: -offset))) }
            try requireHealth(!store.problems().contains { $0.reference == reference }, "Cache eviction resurrected a repaired warning")
            let reopened = UsageStore(service: service, repository: repository, defaults: prefs, now: { now }, reloadWidget: {})
            await reopened.restoreSavedData()
            try requireHealth(!reopened.problems().contains { $0.reference == reference }, "Repaired warning was persisted again")
        }
        await check("Health: an early preference write cannot replace un-restored saved reports with an empty envelope") {
            let suite = "health-\(UUID())"
            let isolated = UserDefaults(suiteName: suite)!
            defer { isolated.removePersistentDomain(forName: suite) }
            let service = HealthService(date: now), repository = HealthRepository()
            let saved = snapshot(now.addingTimeInterval(-7200))
            await repository.write(saved, to: .today)
            await repository.writeHistory(SampleData.history(now: now, context: context))
            await service.fail(.timedOut, day: today)
            let store = UsageStore(service: service, repository: repository, defaults: isolated, now: { now }, reloadWidget: {})
            store.interfaceLanguage = .english
            await Task.yield()
            await store.refresh()
            try requireHealth(store.todaySnapshot == saved && store.history?.days.count == 7, "Preference publication erased cached data before restore")
        }
        await check("Health: retry retains failure until success; storage failure survives unrelated successful writes") {
            let suite = "health-\(UUID())"
            let prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            let service = HealthService(date: now), repository = HealthRepository()
            let store = UsageStore(service: service, repository: repository, defaults: prefs, now: { now }, reloadWidget: {})
            await store.refresh(); await store.waitForHistoryBackfill()
            await service.fail(.timedOut, day: today)
            await store.refresh()
            await service.hold(true)
            let retry = Task { await store.refresh() }
            for _ in 0..<100 where !store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
            try requireHealth(store.isRefreshing && store.problems().contains { $0.reference.kind == .refresh }, "Starting retry erased the active failure")
            await service.fail(nil, day: today); await service.hold(false); await retry.value
            try requireHealth(store.problems().isEmpty, "Success did not clear failure")
            await repository.failStatus(true)
            await store.refresh()
            try requireHealth(store.problems().first?.reference.kind == .storage, "Status write failure was ignored")
            await store.refresh()
            try requireHealth(store.problems().first?.reference.kind == .storage, "Snapshot success erased status failure")
            await repository.failStatus(false)
            await store.retryProblem(.init(kind: .storage))
            let published = await repository.readStatus()
            try requireHealth(store.problems().isEmpty && published?.presentation?.storageError == nil, "Storage recovery remained stuck")
        }
    }
}
