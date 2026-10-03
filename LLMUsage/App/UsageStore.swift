import Foundation
import Combine
import WidgetKit
import AppKit

enum LoadingState: Equatable { case idle, loading, loaded, error, stale }
enum DataPeriod: String, CaseIterable, Identifiable {
    case today = "Сегодня", yesterday = "Вчера", custom = "Другая дата"
    var id: String { rawValue }
    var title: String { L10n.key(rawValue) }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var tab: DashboardTab = .overview
    @Published var sessionList = SessionListState()
    @Published private(set) var sessionNavigationID = UUID()
    @Published var selectedSessionID: String?
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var todaySnapshot: UsageSnapshot?
    @Published private(set) var previousSnapshot: UsageSnapshot?
    @Published private(set) var history: UsageHistory?
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var state: LoadingState = .idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var isTesting = false
    @Published private(set) var error: UsageError?
    @Published private(set) var storageError: UsageError?
    @Published private(set) var diagnostics: CLIDiagnostics?
    @Published private(set) var diagnosticError: UsageError?
    @Published private(set) var lastAttempt: Date?
    @Published var period: DataPeriod = .today
    @Published var customDate = Date()
    @Published var sourceFilter = ""
    @Published var updateMode: UsageUpdateMode {
        didSet {
            defaults.set(updateMode.rawValue, forKey: "updateMode")
            if oldValue != updateMode {
                sourceFilter = ""
                selectedSessionID = nil
                configurationChanged()
            }
        }
    }
    @Published var customPath: String { didSet { defaults.set(customPath, forKey: "customPath"); if oldValue != customPath { configurationChanged() } } }
    @Published var timezone: String { didSet { defaults.set(timezone, forKey: "timezone"); if oldValue != timezone { configurationChanged() } } }
    @Published private(set) var refreshIntervals: RefreshIntervals
    @Published private(set) var refreshMode: RefreshMode = .slow
    var refreshInterval: TimeInterval { schedule.interval }
    var nextAutomaticRefresh: Date? { schedule.nextRefresh }
    @Published var compactMenuBar: Bool { didSet { defaults.set(compactMenuBar, forKey: "compactMenuBar") } }

    @Published var interfaceLanguage: InterfaceLanguage {
        didSet {
            defaults.set(interfaceLanguage.rawValue, forKey: "interfaceLanguage")
            L10n.preference = interfaceLanguage
            preferencesChanged()
        }
    }
    @Published var menuContent: MenuContentMode { didSet { defaults.set(menuContent.rawValue, forKey: "menuContent") } }
    @Published var budgetEnabled: Bool { didSet { defaults.set(budgetEnabled, forKey: "budgetEnabled"); preferencesChanged() } }
    @Published private(set) var budgetAmount: Double
    @Published private(set) var modelExclusionPolicy: ModelExclusionPolicy
    var dailyBudget: Double? { budgetEnabled ? DailyBudget.validAmount(budgetAmount) : nil }
    var dataContext: UsageDataContext { .init(timezone: timezone, customPath: customPath, updateMode: updateMode) }

    let isDemo: Bool
    private let service: any CCUsageServing
    private let repository: any SnapshotPersisting
    private let defaults: UserDefaults
    private let reloadWidget: () -> Void
    private let now: () -> Date
    private var schedule: RefreshSchedule
    private var cache: [String: UsageSnapshot] = [:]
    private var refreshLoop: Task<Void, Never>?
    private var wakeObserver: AnyCancellable?
    private var started = false
    private var generation = 0
    private var historyTask: Task<Void, Never>?
    private var historyRetryAfter: [String: Date] = [:]
    private var todayFailure: UsageError?
    private var restored = false

    init(service: any CCUsageServing = CCUsageService(), repository: any SnapshotPersisting = SnapshotRepository(),
         defaults: UserDefaults = .standard, demo: Bool = false,
         now: @escaping () -> Date = Date.init,
         reloadWidget: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.service = service
        self.repository = repository
        self.defaults = defaults
        self.reloadWidget = reloadWidget
        self.now = now
        let intervals = RefreshIntervals.load(from: defaults)
        refreshIntervals = intervals
        schedule = RefreshSchedule(intervals: intervals)
        isDemo = demo
        updateMode = demo ? .allAgents : UsageUpdateMode(rawValue: defaults.string(forKey: "updateMode") ?? "") ?? .claudeOnly
        interfaceLanguage = InterfaceLanguage(rawValue: defaults.string(forKey: "interfaceLanguage") ?? "") ?? .system
        customPath = defaults.string(forKey: "customPath") ?? ""
        let savedZone = defaults.string(forKey: "timezone") ?? "UTC"
        timezone = TimeZone(identifier: savedZone) == nil ? "UTC" : savedZone
        compactMenuBar = defaults.bool(forKey: "compactMenuBar")
        menuContent = MenuContentMode(rawValue: defaults.string(forKey: "menuContent") ?? "") ?? .summary
        budgetEnabled = defaults.bool(forKey: "budgetEnabled")
        budgetAmount = DailyBudget.validAmount(defaults.object(forKey: "budgetAmount") as? Double) ?? 25
        modelExclusionPolicy = .init(overrides: defaults.dictionary(forKey: "modelInclusionOverrides") as? [String: Bool] ?? [:])
        L10n.preference = interfaceLanguage
        if demo {
            var data = SampleData.multiSourceSnapshot()
            data.dataContext = dataContext
            data.day = UsageDay(date: data.generatedAt, timezone: timezone)
            data = data.applyingExclusions(modelExclusionPolicy)
            history = SampleData.history(now: data.generatedAt, context: dataContext).applyingExclusions(modelExclusionPolicy)
            history?.record(data, today: data.day)
            snapshot = data
            todaySnapshot = data
            cache[data.day.cacheKey] = data
            state = .loaded
        }
    }

    deinit { refreshLoop?.cancel(); historyTask?.cancel() }

    var selectedDay: UsageDay {
        let today = UsageDay(date: now(), timezone: timezone)
        switch period {
        case .today: return today
        case .yesterday: return today.adding(days: -1)
        case .custom: return UsageDay(date: customDate, timezone: timezone)
        }
    }
    var selectedSession: UsageSession? {
        snapshot?.sessions.first { $0.id == selectedSessionID }
            ?? snapshot?.sessions.first { $0.sourceID == "claude" && $0.rawID == selectedSessionID }
    }
    var displaySnapshot: UsageSnapshot? { snapshot?.filtered(source: sourceFilter) }
    var selectedModels: [String] { Array(Set(displaySnapshot?.sessions.flatMap(\.models) ?? [])).sorted() }

    var knownModels: [String] {
        var names = Array(modelExclusionPolicy.overrides.keys)
        for data in cache.values {
            for session in data.sessions { names += session.models + session.modelBreakdowns.map(\.id) }
        }
        for day in history?.days ?? [] { names += day.usageComponents?.flatMap(\.models) ?? [] }
        return Array(Set(names.map(ModelExclusionPolicy.key).filter { !$0.isEmpty })).sorted()
    }

    var excludedModels: [String] { knownModels.filter { !modelExclusionPolicy.includes($0) } }

    func setModelIncluded(_ included: Bool, model: String) {
        let key = ModelExclusionPolicy.key(model)
        guard !key.isEmpty, modelExclusionPolicy.overrides[key] != included else { return }
        var policy = modelExclusionPolicy
        policy.overrides[key] = included
        modelExclusionPolicy = policy
        defaults.set(policy.overrides, forKey: "modelInclusionOverrides")
        cache = cache.mapValues { $0.applyingExclusions(policy) }
        snapshot = snapshot?.applyingExclusions(policy)
        todaySnapshot = todaySnapshot?.applyingExclusions(policy)
        previousSnapshot = previousSnapshot?.applyingExclusions(policy)
        history = history?.applyingExclusions(policy)
        // Widget readers apply the latest policy to raw values retained in every file.
        // This also avoids racing a preference change with an in-flight CLI write.
        preferencesChanged()
    }

    func start() {
        guard !started, !isDemo else { return }
        started = true
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshAutomaticallyIfDue() }
            }
        Task { [weak self] in await self?.refresh(reason: .startup) }
    }

    /// The timer task only owns the sleep. Rescheduling it never cancels a CLI
    /// request in progress (manual or automatic).
    private func scheduleAutomaticRefresh() {
        guard started, !isDemo else { return }
        refreshLoop?.cancel()
        let date = now()
        let day = UsageDay(date: date, timezone: timezone)
        schedule.prepare(day: day, at: date)
        refreshMode = schedule.mode
        let deadline = min(schedule.nextRefresh ?? date, day.end)
        let delay = max(0, deadline.timeIntervalSince(date))
        refreshLoop = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.refreshLoop = nil
            await self.refreshAutomaticallyIfDue()
        }
    }

    func refreshAutomaticallyIfDue() async {
        guard !isDemo else { return }
        let date = now()
        schedule.prepare(day: UsageDay(date: date, timezone: timezone), at: date)
        refreshMode = schedule.mode
        if schedule.consumeSkippedRefresh(at: date) {
            scheduleAutomaticRefresh()
            return
        }
        // The current request's defer will re-arm the timer. A medium/slow
        // deadline remains due even when a manual request overlaps that slot.
        guard !isRefreshing else { return }
        if let deadline = schedule.nextRefresh, date >= deadline {
            await refresh(reason: .automatic)
        } else {
            scheduleAutomaticRefresh()
        }
    }

    @discardableResult
    func setRefreshIntervals(fastSeconds: Int? = nil, mediumMinutes: Int? = nil, slowMinutes: Int? = nil) -> Bool {
        let intervals = RefreshIntervals(fastSeconds: fastSeconds ?? refreshIntervals.fastSeconds,
                                         mediumMinutes: mediumMinutes ?? refreshIntervals.mediumMinutes,
                                         slowMinutes: slowMinutes ?? refreshIntervals.slowMinutes)
        guard intervals.isValid else { return false }
        guard intervals != refreshIntervals else { return true }
        refreshIntervals = intervals
        intervals.save(to: defaults)
        schedule.configure(intervals, at: now())
        if !isRefreshing { scheduleAutomaticRefresh() }
        preferencesChanged()
        return true
    }

    private func restore() async {
        guard !restored else { return }
        restored = true
        let context = dataContext
        // History is optional: a damaged history file must not hide a valid today's snapshot.
        do {
            let savedHistory = try await repository.readHistory()
            guard context == dataContext else { return }
            if savedHistory?.context == context { history = savedHistory?.applyingExclusions(modelExclusionPolicy) }
        } catch { if context == dataContext { storageError = Self.presentable(error) } }
        for slot in [SnapshotSlot.today, .yesterday] {
            do {
                let saved = try await repository.read(slot)
                guard context == dataContext else { return }
                guard let raw = saved, raw.dataContext == context else { continue }
                let data = raw.applyingExclusions(modelExclusionPolicy)
                cache[data.day.cacheKey] = data
                if slot == .today {
                    todaySnapshot = data
                    if data.day == selectedDay { snapshot = data; state = data.isStale(now: now(), interval: refreshInterval) ? .stale : .loaded }
                } else { previousSnapshot = data }
            } catch { if context == dataContext { storageError = Self.presentable(error) } }
        }
    }

    /// Preferences publish independently of a running or failed CLI query.
    func preferencesChanged() {
        guard !isDemo else { return }
        Task { await publishStatus() }
    }

    @discardableResult
    func setBudgetAmount(_ amount: Double) -> Bool {
        guard let amount = DailyBudget.validAmount(amount) else { return false }
        budgetAmount = amount
        defaults.set(amount, forKey: "budgetAmount")
        preferencesChanged()
        return true
    }

    private func configurationChanged() {
        generation += 1
        schedule.reset(day: UsageDay(date: now(), timezone: timezone), at: now())
        refreshMode = schedule.mode
        if !isRefreshing { scheduleAutomaticRefresh() }
        historyTask?.cancel()
        historyTask = nil
        isLoadingHistory = false
        historyRetryAfter.removeAll()
        cache.removeAll()
        snapshot = nil
        todaySnapshot = nil
        previousSnapshot = nil
        history = nil
        todayFailure = nil
        error = nil
        state = .idle
        preferencesChanged()
    }

    private func publishStatus() async {
        let status = RefreshStatus(attemptedAt: lastAttempt ?? now(), message: todayFailure?.errorDescription,
                                   refreshMinutes: refreshIntervals.slowMinutes, dailyBudget: dailyBudget, dataContext: dataContext,
                                   interfaceLanguage: interfaceLanguage, refreshIntervalSeconds: refreshInterval,
                                   modelExclusionPolicy: modelExclusionPolicy)
        do { try await repository.writeStatus(status) }
        catch { storageError = Self.presentable(error) }
        reloadWidget()
    }

    /// The calendar browses locally; only a confirmed day changes the report.
    func selectCustomDate(_ date: Date) async {
        let day = UsageDay(date: date, timezone: timezone)
        guard day.date <= UsageDay(date: now(), timezone: timezone).date else { return }
        guard period != .custom || selectedDay != day else { return }
        customDate = day.date
        period = .custom
        await selectPeriod()
    }

    func selectPeriod() async {
        selectedSessionID = nil
        snapshot = cache[selectedDay.cacheKey]
        if isDemo { return }
        if let snapshot, snapshot.canReuse(for: selectedDay, now: now(), liveInterval: refreshInterval) {
            state = .loaded
            return
        }
        await refresh(reason: .selection)
    }

    func refresh(reason: RefreshReason = .manual) async {
        guard !isDemo, !isRefreshing else { return }
        schedule.prepare(day: UsageDay(date: now(), timezone: timezone), at: now())
        if reason == .manual { schedule.manualRefreshStarted() }
        refreshMode = schedule.mode
        isRefreshing = true
        let revision = generation
        let context = dataContext
        var todaySucceeded = false
        defer {
            isRefreshing = false
            if revision != generation { Task { await self.refresh(reason: .configuration) } }
            else {
                scheduleAutomaticRefresh()
                if todaySucceeded && !Task.isCancelled { scheduleHistoryBackfill() }
            }
        }
        await restore()
        guard revision == generation, !Task.isCancelled else { return }
        state = .loading
        lastAttempt = now()
        error = nil
        let today = UsageDay(date: now(), timezone: context.timezone)
        schedule.prepare(day: today, at: now())
        refreshMode = schedule.mode
        do {
            var data = try await service.fetch(day: today, customPath: context.customPath, mode: context.updateMode ?? .claudeOnly)
            try Task.checkCancellation()
            guard revision == generation else { return }
            // A query spanning midnight must not seed today's schedule with
            // yesterday's amount. The timer will request the new day once.
            guard today == UsageDay(date: now(), timezone: context.timezone) else {
                state = snapshot == nil ? .idle : .stale
                return
            }
            schedule.succeeded(cost: data.totals.cost, reason: reason, at: now())
            refreshMode = schedule.mode
            data = data.applyingExclusions(modelExclusionPolicy)
            data.dataContext = context
            todaySnapshot = data
            cache[today.cacheKey] = data
            if selectedDay == today { snapshot = data }
            recordHistory(data)
            // Publish the fresh snapshot before any historical scan starts.
            state = .loaded
            todaySucceeded = true
            todayFailure = nil
            await persist(data, slot: .today, revision: revision)
            guard revision == generation, !Task.isCancelled else { return }
            await persistHistory(revision: revision)
            guard revision == generation, !Task.isCancelled else { return }
            await publishStatus()

            // Historical dashboard selection has priority over background history.
            repeat {
                let requested = selectedDay
                if requested == today { snapshot = todaySnapshot; break }
                var historical = cache[requested.cacheKey]
                if reason == .manual || historical?.canReuse(for: requested, now: now(), liveInterval: refreshInterval) != true {
                    historical = try await service.fetch(day: requested, customPath: context.customPath, mode: context.updateMode ?? .claudeOnly)
                }
                try Task.checkCancellation()
                guard revision == generation, var historical else { return }
                historical = historical.applyingExclusions(modelExclusionPolicy)
                historical.dataContext = context
                cache[requested.cacheKey] = historical
                recordHistory(historical)
                await persistHistory(revision: revision)
                guard revision == generation else { return }
                if requested == selectedDay { snapshot = historical.applyingExclusions(modelExclusionPolicy); break }
            } while !Task.isCancelled
            state = .loaded
        } catch is CancellationError {
            if revision == generation {
                state = snapshot == nil ? .idle : .stale
                if !todaySucceeded { schedule.failed(reason: reason, at: now()) }
            }
        } catch {
            guard revision == generation else { return }
            let failure = Self.presentable(error)
            self.error = failure
            state = snapshot == nil ? .error : .stale
            if !todaySucceeded {
                schedule.failed(reason: reason, at: now())
                todayFailure = failure
                await publishStatus()
            }
        }
    }

    private func recordHistory(_ data: UsageSnapshot) {
        var updated = history ?? UsageHistory(context: dataContext)
        updated.record(data, today: UsageDay(date: now(), timezone: timezone))
        history = updated
    }

    private func scheduleHistoryBackfill() {
        guard historyTask == nil else { return }
        let revision = generation
        let context = dataContext
        let today = UsageDay(date: now(), timezone: context.timezone)
        let pending = (history ?? UsageHistory(context: context)).missingCompletedDays(ending: today, now: now())
            .filter { (historyRetryAfter[$0.cacheKey] ?? .distantPast) <= now() }
        guard !pending.isEmpty else { return }
        isLoadingHistory = true
        historyTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == self.generation { self.historyTask = nil; self.isLoadingHistory = false }
            }
            for day in pending {
                guard !Task.isCancelled, revision == self.generation,
                      today == UsageDay(date: self.now(), timezone: context.timezone) else { return }
                // Another successful dated query may have filled the gap meanwhile.
                if self.history?.missingCompletedDays(ending: today, now: self.now()).contains(day) == false { continue }
                do {
                    var data = try await self.service.fetch(day: day, customPath: context.customPath, mode: context.updateMode ?? .claudeOnly)
                    try Task.checkCancellation()
                    guard revision == self.generation else { return }
                    data = data.applyingExclusions(self.modelExclusionPolicy)
                    data.dataContext = context
                    self.recordHistory(data)
                    self.cache[day.cacheKey] = data
                    if self.selectedDay == day { self.snapshot = data }
                    if day == today.adding(days: -1) {
                        self.previousSnapshot = data
                        await self.persist(data, slot: .yesterday, revision: revision)
                    }
                    guard revision == self.generation else { return }
                    await self.persistHistory(revision: revision)
                    guard revision == self.generation else { return }
                    self.reloadWidget()
                } catch is CancellationError { return }
                catch {
                    guard revision == self.generation else { return }
                    // Failed days stay missing. Retry no more than once an hour; preserve successes.
                    self.historyRetryAfter[day.cacheKey] = self.now().addingTimeInterval(3600)
                }
            }
        }
    }

    // Also allows integration checks to await only the bounded background work.
    func waitForHistoryBackfill() async { await historyTask?.value }

    private func persist(_ data: UsageSnapshot, slot: SnapshotSlot, revision: Int) async {
        do {
            try await repository.write(data, to: slot)
            if revision == generation { storageError = nil }
        } catch { if revision == generation { storageError = Self.presentable(error) } }
    }

    private func persistHistory(revision: Int) async {
        guard revision == generation, let history else { return }
        do { try await repository.writeHistory(history) }
        catch { if revision == generation { storageError = Self.presentable(error) } }
    }

    func testCLI(autoDetect: Bool = false) async {
        guard !isTesting, !isDemo else { return }
        isTesting = true
        diagnosticError = nil
        defer { isTesting = false }
        if autoDetect { customPath = "" }
        do { diagnostics = try await service.diagnose(customPath: customPath, forceDetect: autoDetect) }
        catch { diagnostics = nil; diagnosticError = Self.presentable(error) }
    }

    func applyCLISettings() async {
        await testCLI()
        await refresh(reason: .configuration)
    }

    func navigate(_ route: UsageRoute) {
        sourceFilter = ""
        switch route {
        case .overview:
            sessionList = .init()
            tab = .overview
            selectedSessionID = nil
            period = .today
            snapshot = todaySnapshot
            if !isDemo, todaySnapshot?.day != selectedDay { Task { await self.refresh(reason: .selection) } }
        case .sessions: navigateSessions(day: nil, id: nil)
        case .settings: tab = .settings; selectedSessionID = nil
        case .session(let id): navigateSessions(day: nil, id: id)
        case .datedSessions(let day): navigateSessions(day: day, id: nil)
        case .datedSession(let id, let day): navigateSessions(day: day, id: id)
        }
    }

    private func navigateSessions(day: UsageDay?, id: String?) {
        if let day, timezone != day.timezone { timezone = day.timezone }
        let today = UsageDay(date: now(), timezone: timezone)
        let requested = day ?? today
        sessionList = .init(isExpanded: true, sort: sessionList.sort)
        tab = .overview
        period = requested == today ? .today : .custom
        if period == .custom { customDate = requested.date }
        snapshot = cache[requested.cacheKey] ?? (todaySnapshot?.day == requested ? todaySnapshot : nil)
        selectedSessionID = id
        sessionNavigationID = UUID()
        if !isDemo, snapshot?.canReuse(for: requested, now: now(), liveInterval: refreshInterval) != true {
            Task { await self.refresh(reason: .selection) }
        }
    }

    static func presentable(_ error: Error) -> UsageError {
        error as? UsageError ?? .processFailed(-1, error.localizedDescription)
    }
}
