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
    @Published var presentedProblem: UsageProblemReference?
    @Published var showStorageSettings = false
    @Published private(set) var isRetryingProblem = false
    @Published private(set) var recoveryCompleted = 0
    @Published private(set) var recoveryTotal = 0
    @Published private(set) var recoveryResult: UsageRecoveryResult?
    @Published private var hiddenProblems: [String: String] = [:]
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
    var dataContext: UsageDataContext {
        .init(timezone: timezone, customPath: service.engineID == nil ? customPath : "",
              updateMode: updateMode, engineID: service.engineID)
    }
    @Published private(set) var maintenanceInProgress = false

    func restoreSavedData() async { await restore() }
    func prepareForAppUpdate() async throws {
        maintenanceInProgress = true
        refreshLoop?.cancel()
        historyTask?.cancel()
        startupTask?.cancel()
        publicationRetry?.cancel(); publicationRetry = nil
        widgetReloadTask?.cancel(); widgetReloadTask = nil
        await publicationTask?.value
        await historyTask?.value
        await startupTask?.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while isRefreshing || isRetryingProblem {
            guard ContinuousClock.now < deadline else { throw UsageError.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    func resumeAfterAppUpdate() {
        maintenanceInProgress = false
        preferencesChanged()
        if started { scheduleAutomaticRefresh() }
    }

    lazy var telemetry = ClaudeTelemetryCoordinator(defaults: defaults, isolated: isDemo || isManualReview)

    let isDemo: Bool
    var isManualReview = false
    @Published private(set) var reviewChatRevision = 0
    private(set) var reviewChatPresented = false
    private let service: any CCUsageServing
    private let repository: any SnapshotPersisting
    private let defaults: UserDefaults
    private let reloadWidget: () -> Void
    private let now: () -> Date
    private var schedule: RefreshSchedule
    private var cache: [String: UsageSnapshot] = [:]
    private var historicalRequest = 0
    private var acceptedHistoricalRequests: [String: Int] = [:]
    private var refreshLoop: Task<Void, Never>?
    private var wakeObserver: AnyCancellable?
    private var started = false
    private var startupTask: Task<Void, Never>?
    private var refreshIdentity = UUID()
    private var generation = 0
    private var historyTask: Task<Void, Never>?
    private var historyRetryAfter: [String: Date] = [:]
    private var todayFailure: UsageError?
    private var restored = false
    private var restoreTask: Task<Void, Never>?
    private var healthClock: Task<Void, Never>?
    @Published private var refreshFailures: [String: UsageRefreshFailure] = [:]
    private var storageFailures: [String: UsageError] = [:]
    private var presentationRevision = UUID()
    private var restoredCostIssues: [UsageCostIssue] = []
    private var publicationTask: Task<Void, Never>?
    private var publicationDirty = false
    private var publicationRetry: Task<Void, Never>?
    private var publicationFailures = 0
    private var widgetReloadTask: Task<Void, Never>?
    private var pendingWidgetContent: Data?
    private var lastWidgetContent: Data?
    private var lastWidgetReload: Date?
    private var awaitingConfigurationData = false
    private let widgetReloadDelay: TimeInterval
    private let publicationRetryDelay: TimeInterval

    init(service: any CCUsageServing = CCUsageService(), repository: any SnapshotPersisting = SnapshotRepository(),
         defaults: UserDefaults = .standard, demo: Bool = false,
         now: @escaping () -> Date = Date.init,
         widgetReloadDelay: TimeInterval = 1.5,
         publicationRetryDelay: TimeInterval = 5,
         reloadWidget: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.service = service
        self.repository = repository
        self.defaults = defaults
        self.reloadWidget = reloadWidget
        self.now = now
        hiddenProblems = defaults.dictionary(forKey: "hiddenUsageProblems") as? [String: String] ?? [:]
        self.widgetReloadDelay = widgetReloadDelay
        self.publicationRetryDelay = publicationRetryDelay
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
            cacheSnapshot(data)
            state = .loaded
        }
    }

    deinit {
        refreshLoop?.cancel(); historyTask?.cancel(); healthClock?.cancel(); restoreTask?.cancel()
        publicationTask?.cancel(); publicationRetry?.cancel(); widgetReloadTask?.cancel()
    }

    var presentationStatus: RefreshStatus { makePresentationStatus() }

    private func makePresentationStatus(publishing: Bool = false) -> RefreshStatus {
        let storage = publishing ? storageFailures.filter { $0.key != "status" }.sorted { $0.key < $1.key }.first?.value : storageError
        var knownSnapshots = cache
        for data in [todaySnapshot, previousSnapshot].compactMap({ $0 }) { knownSnapshots[data.day.cacheKey] = data }
        let costs = restoredCostIssues.filter { knownSnapshots[$0.day.cacheKey] == nil }
            + knownSnapshots.values.compactMap { UsageCostIssue(snapshot: $0) }
        let presentation = UsagePresentation(revision: presentationRevision, snapshot: todaySnapshot,
            previous: previousSnapshot, history: history, failures: refreshFailures.values.sorted { $0.day.cacheKey < $1.day.cacheKey },
            storageError: storage, costIssues: Array(costs.sorted { $0.day.cacheKey > $1.day.cacheKey }.prefix(32)), lastAttempt: lastAttempt)
        return RefreshStatus(attemptedAt: lastAttempt ?? now(), message: todayFailure?.errorDescription,
            refreshMinutes: refreshIntervals.slowMinutes, dailyBudget: dailyBudget, dataContext: dataContext,
            interfaceLanguage: interfaceLanguage, refreshIntervalSeconds: refreshInterval,
            modelExclusionPolicy: modelExclusionPolicy, presentation: presentation,
            isRecalculating: awaitingConfigurationData, publishedAt: now(), hiddenProblems: hiddenProblems)
    }

    func problems(at date: Date? = nil) -> [UsageProblem] {
        UsageHealth.problems(snapshot: todaySnapshot, history: history, status: presentationStatus, now: date ?? now())
    }

    func problems(for day: UsageDay, includeHidden: Bool = true) -> [UsageProblem] {
        let data = day == UsageDay(date: now(), timezone: timezone) ? todaySnapshot
            : cache[day.cacheKey] ?? (snapshot?.day == day ? snapshot : nil)
        return UsageHealth.problems(snapshot: data, history: history, status: presentationStatus, now: now(),
                                    scope: .day(day), includeHidden: includeHidden)
    }

    func hideProblem(_ problem: UsageProblem) {
        hiddenProblems[problem.id] = problem.dismissalFingerprint
        // Keep acknowledgements across date browsing and relaunch, bounded to a year of daily use.
        if hiddenProblems.count > 512 {
            for key in hiddenProblems.keys.sorted().prefix(hiddenProblems.count - 512) { hiddenProblems.removeValue(forKey: key) }
        }
        defaults.set(hiddenProblems, forKey: "hiddenUsageProblems")
        preferencesChanged()
    }

    private func acceptCostState(_ data: UsageSnapshot) {
        // Remove the restored record, rather than merely masking it with a cache entry.
        restoredCostIssues.removeAll { $0.day == data.day }
        if data.totals.costIsIncomplete != true {
            hiddenProblems.removeValue(forKey: UsageProblemReference(kind: .cost, day: data.day).id)
            defaults.set(hiddenProblems, forKey: "hiddenUsageProblems")
        }
    }

    private func scheduleHealthTransition() {
        healthClock?.cancel()
        guard let next = UsageHealth.transitionDates(snapshot: todaySnapshot, history: history,
            status: presentationStatus, now: now()).first else { return }
        let delay = max(0.01, next.timeIntervalSince(now()))
        healthClock = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.objectWillChange.send()
            self.scheduleHealthTransition()
        }
    }

    private func storageResult(_ failure: UsageError?, operation: String) {
        storageFailures[operation] = failure
        storageError = storageFailures.sorted { $0.key < $1.key }.first?.value
    }

    func retryProblem(_ reference: UsageProblemReference) async {
        let today = UsageDay(date: now(), timezone: timezone)
        if reference.kind == .history {
            await recoverDays(problems().flatMap(\.missingDays))
        } else {
            await recoverDays([reference.kind == .cost || reference.kind == .refresh ? reference.day ?? today : today])
        }
    }

    func retryAllProblems() async {
        await restore()
        let today = UsageDay(date: now(), timezone: timezone)
        let days = problems().flatMap { problem -> [UsageDay] in
            switch problem.reference.kind {
            case .storage, .stale, .context: return [today]
            default: return problem.reference.day.map { [$0] } ?? problem.missingDays
            }
        }
        await recoverDays(days)
    }

    private func recoverDays(_ requested: [UsageDay]) async {
        guard !isRefreshing, !isRetryingProblem, !isDemo, !maintenanceInProgress else { return }
        isRetryingProblem = true
        recoveryResult = nil; recoveryCompleted = 0
        defer { isRetryingProblem = false; scheduleAutomaticRefresh() }
        let revision = generation, context = dataContext
        await restore()
        historyTask?.cancel()
        await historyTask?.value
        let days = Dictionary(requested.filter { $0.timezone == context.timezone }.map { ($0.cacheKey, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.date > $1.date }
        recoveryTotal = days.count
        var failed = 0, incomplete = 0
        for day in days {
            guard revision == generation, !Task.isCancelled, !maintenanceInProgress else { return }
            if day == UsageDay(date: now(), timezone: context.timezone) {
                await refresh(includeSelectedDay: false)
                if refreshFailures[day.cacheKey] != nil { failed += 1 }
                else if todaySnapshot?.totals.costIsIncomplete == true { incomplete += 1 }
            } else {
                do {
                    let data = try await loadHistorical(day, context: context, revision: revision, force: true)
                    if data?.totals.costIsIncomplete == true { incomplete += 1 }
                } catch is CancellationError { return }
                catch {
                    guard revision == generation else { return }
                    failed += 1
                    refreshFailures[day.cacheKey] = .init(day: day, attemptedAt: now(), error: Self.presentable(error))
                }
            }
            guard revision == generation, !Task.isCancelled else { return }
            recoveryCompleted += 1
        }
        recoveryResult = .init(days: days, repaired: days.count - failed - incomplete,
                               incomplete: incomplete, failed: failed, completedAt: now())
        await publishStatus()
    }

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
        restoredCostIssues.removeAll { !$0.models.isEmpty && $0.models.allSatisfy { !policy.includes($0) } }
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
        startupTask = Task { [weak self] in await self?.refresh(reason: .startup) }
    }

    /// The timer task only owns the sleep. Rescheduling it never cancels a CLI
    /// request in progress (manual or automatic).
    private func scheduleAutomaticRefresh() {
        guard started, !isDemo, !maintenanceInProgress else { return }
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
        guard !isRefreshing, !isRetryingProblem else { return }
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
        guard !isDemo else { return }
        if let restoreTask { await restoreTask.value; return }
        guard !restored else { return }
        let task = Task { await self.restorePresentation() }
        restoreTask = task
        await task.value
        restoreTask = nil
    }

    private func restorePresentation() async {
        let context = dataContext
        let revision = generation
        defer { if revision == generation { restored = true; scheduleHealthTransition() } }
        do {
            let status = try await repository.readStatus()
            guard revision == generation, !Task.isCancelled else { return }
            if status?.dataContext?.canDisplay(alongside: context) == true {
                lastAttempt = status?.attemptedAt
                if let presentation = status?.presentation {
                    restoredCostIssues = presentation.costIssues
                    lastAttempt = presentation.lastAttempt
                    history = presentation.history?.applyingExclusions(modelExclusionPolicy)
                    todaySnapshot = presentation.snapshot?.applyingExclusions(modelExclusionPolicy)
                    previousSnapshot = presentation.previous?.applyingExclusions(modelExclusionPolicy)
                    for data in [todaySnapshot, previousSnapshot].compactMap({ $0 }) {
                        if data.dataContext == context { cacheSnapshot(data) }
                    }
                    snapshot = todaySnapshot?.day == selectedDay ? todaySnapshot : nil
                    if let snapshot { state = snapshot.dataContext != context || snapshot.isStale(now: now(), interval: refreshInterval) ? .stale : .loaded }
                    else { state = .idle }
                    refreshFailures = Dictionary(presentation.failures.map { ($0.day.cacheKey, $0) }, uniquingKeysWith: { _, newer in newer })
                    todayFailure = refreshFailures[UsageDay(date: now(), timezone: timezone).cacheKey]?.error
                    // Recheck failed cache operations on the next successful refresh.
                    storageResult(presentation.storageError, operation: "restored")
                    return
                }
                if let message = status?.message, let attemptedAt = status?.attemptedAt {
                    let day = UsageDay(date: attemptedAt, timezone: timezone)
                    refreshFailures[day.cacheKey] = .init(day: day, attemptedAt: attemptedAt, error: nil, legacyMessage: message)
                }
            }
        } catch { if context == dataContext { storageResult(Self.presentable(error), operation: "status") } }
        // Legacy caches, or recovery after an unreadable presentation file.
        do {
            let savedHistory = try await repository.readHistory()
            guard context == dataContext else { return }
            if savedHistory?.context.canDisplay(alongside: context) == true { history = savedHistory?.applyingExclusions(modelExclusionPolicy) }
        } catch { if context == dataContext { storageResult(Self.presentable(error), operation: "history") } }
        for slot in [SnapshotSlot.today, .yesterday] {
            do {
                let saved = try await repository.read(slot)
                guard context == dataContext else { return }
                guard let raw = saved, raw.dataContext?.canDisplay(alongside: context) == true else { continue }
                let data = raw.applyingExclusions(modelExclusionPolicy)
                if data.dataContext == context { cacheSnapshot(data) }
                if slot == .today {
                    todaySnapshot = data
                    if data.day == selectedDay { snapshot = data; state = data.dataContext != context || data.isStale(now: now(), interval: refreshInterval) ? .stale : .loaded }
                } else { previousSnapshot = data }
            } catch { if context == dataContext { storageResult(Self.presentable(error), operation: slot.rawValue) } }
        }
    }

    /// Preferences publish independently of a running or failed CLI query.
    func preferencesChanged() {
        guard !isDemo else { return }
        Task { await restore(); await publishStatus() }
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
        recoveryResult = nil
        hiddenProblems.removeAll(); defaults.removeObject(forKey: "hiddenUsageProblems")
        awaitingConfigurationData = true
        generation += 1
        schedule.reset(day: UsageDay(date: now(), timezone: timezone), at: now())
        refreshMode = schedule.mode
        if !isRefreshing { scheduleAutomaticRefresh() }
        historyTask?.cancel()
        historyTask = nil
        isLoadingHistory = false
        historyRetryAfter.removeAll()
        cache.removeAll()
        acceptedHistoricalRequests.removeAll()
        snapshot = nil
        todaySnapshot = nil
        previousSnapshot = nil
        history = nil
        todayFailure = nil
        refreshFailures.removeAll()
        restoredCostIssues.removeAll()
        error = nil
        state = .idle
        preferencesChanged()
    }

    private func publishStatus() async {
        publicationDirty = true
        publicationRetry?.cancel()
        publicationRetry = nil
        if let publicationTask { await publicationTask.value; return }
        let writer = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.drainPublications()
        }
        publicationTask = writer
        await writer.value
    }

    /// Only this loop sends writes to the repository. Reentrant callers mark
    /// it dirty; after an await it builds a new envelope from current state.
    private func drainPublications() async {
        defer { publicationTask = nil }
        while publicationDirty && !Task.isCancelled {
            publicationDirty = false
            await writeCurrentPresentation()
        }
    }

    private func writeCurrentPresentation() async {
        if refreshFailures.count > 32 {
            let recent = refreshFailures.values.sorted { $0.attemptedAt > $1.attemptedAt }.prefix(32)
            refreshFailures = Dictionary(uniqueKeysWithValues: recent.map { ($0.day.cacheKey, $0) })
        }
        presentationRevision = UUID()
        scheduleHealthTransition()
        let status = makePresentationStatus(publishing: true)
        let wasFailed = storageFailures["status"] != nil
        do {
            try await repository.writeStatus(status)
            storageResult(nil, operation: "status")
            publicationFailures = 0
            await requestWidgetReload(status, force: wasFailed)
        } catch {
            storageResult(Self.presentable(error), operation: "status")
            publicationFailures += 1
            widgetReloadTask?.cancel(); widgetReloadTask = nil; pendingWidgetContent = nil
            if !publicationDirty && !maintenanceInProgress {
                let delay = min(300, publicationRetryDelay * pow(2, Double(min(publicationFailures - 1, 6))))
                publicationRetry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard !Task.isCancelled, let self, !self.maintenanceInProgress else { return }
                    self.publicationRetry = nil
                    await self.publishStatus()
                }
            }
        }
    }

    private func requestWidgetReload(_ status: RefreshStatus, force: Bool) async {
        guard !maintenanceInProgress else { return }
        let date = now()
        let content = await Task.detached(priority: .utility) {
            WidgetPresentation(status: status, now: date).contentIdentity()
        }.value
        guard !maintenanceInProgress else { return }
        if widgetReloadTask != nil { pendingWidgetContent = content; return }
        // Renew freshness before the 10-minute stale transition, even if no
        // money changed. Never deduplicate by generatedAt or the random revision.
        guard force || content != lastWidgetContent || lastWidgetReload.map({ date < $0 || date.timeIntervalSince($0) >= 300 }) != false else { return }
        pendingWidgetContent = content
        guard widgetReloadTask == nil else { return }
        let interval = widgetReloadDelay == 0 ? 0 : max(widgetReloadDelay, 15 - max(0, lastWidgetReload.map { date.timeIntervalSince($0) } ?? 15))
        widgetReloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            guard !Task.isCancelled, let self, !self.maintenanceInProgress else { return }
            self.lastWidgetContent = self.pendingWidgetContent
            self.lastWidgetReload = self.now()
            self.pendingWidgetContent = nil
            self.widgetReloadTask = nil
            self.reloadWidget()
        }
    }

    func waitForWidgetPublication() async {
        await publicationTask?.value
        await widgetReloadTask?.value
    }

    func canMoveSelectedDay(by offset: Int) -> Bool {
        guard period == .custom, !isDemo, offset == -1 || offset == 1 else { return false }
        return selectedDay.adding(days: offset).date <= UsageDay(date: now(), timezone: timezone).date
    }

    func moveSelectedDay(by offset: Int) async {
        guard canMoveSelectedDay(by: offset) else { return }
        // Read the current selection for every click, even while an earlier report is loading.
        await selectCustomDate(selectedDay.adding(days: offset).date)
    }

    /// Month browsing is local to the calendar; choosing or stepping a day changes the report.
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

    func refresh(reason: RefreshReason = .manual, includeSelectedDay: Bool = true) async {
        guard !isDemo, !isRefreshing, !maintenanceInProgress else { return }
        schedule.prepare(day: UsageDay(date: now(), timezone: timezone), at: now())
        if reason == .manual { schedule.manualRefreshStarted() }
        refreshMode = schedule.mode
        isRefreshing = true
        let revision = generation
        let context = dataContext
        var todaySucceeded = false
        let identity = UUID()
        refreshIdentity = identity
        defer {
            if refreshIdentity == identity {
                isRefreshing = false
                if revision != generation { Task { await self.refresh(reason: .configuration) } }
                else {
                    scheduleAutomaticRefresh()
                    if todaySucceeded && !Task.isCancelled { scheduleHistoryBackfill() }
                }
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
            acceptCostState(data)
            todaySnapshot = data
            awaitingConfigurationData = false
            cacheSnapshot(data)
            if selectedDay == today { snapshot = data }
            recordHistory(data)
            // Publish the fresh snapshot before any historical scan starts.
            state = .loaded
            todaySucceeded = true
            todayFailure = nil
            refreshFailures.removeValue(forKey: today.cacheKey)
            await persist(data, slot: .today, revision: revision)
            guard revision == generation, !Task.isCancelled else { return }
            await persistHistory(revision: revision)
            guard revision == generation, !Task.isCancelled else { return }
            storageResult(nil, operation: "restored")
            await publishStatus()

            // Historical dashboard selection has priority over background history.
            guard includeSelectedDay else { return }
            repeat {
                let requested = selectedDay
                if requested == today { snapshot = todaySnapshot; break }
                do {
                    _ = try await loadHistorical(requested, context: context, revision: revision, force: reason == .manual)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // A date picked during this request still needs servicing,
                    // even if the abandoned request failed instead of succeeding.
                    guard revision == generation else { return }
                    if requested != selectedDay { continue }
                    throw error
                }
                try Task.checkCancellation()
                guard revision == generation else { return }
                if requested == selectedDay { snapshot = cache[requested.cacheKey]; break }
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
                refreshFailures[today.cacheKey] = .init(day: today, attemptedAt: lastAttempt ?? now(), error: failure)
            } else {
                refreshFailures[selectedDay.cacheKey] = .init(day: selectedDay, attemptedAt: lastAttempt ?? now(), error: failure)
            }
            await publishStatus()
        }
    }

    private func recordHistory(_ data: UsageSnapshot) {
        var updated = history?.context.canDisplay(alongside: dataContext) == true ? history! : UsageHistory(context: dataContext)
        // Keep older totals visible while each day is recalculated by the new engine.
        updated.context = dataContext
        let timestamp = now()
        updated.record(data, today: UsageDay(date: timestamp, timezone: timezone), now: timestamp)
        history = updated
    }

    private func cacheSnapshot(_ data: UsageSnapshot) {
        cache[data.day.cacheKey] = data
        // Browsing arbitrary dates must not retain every full session report for
        // the lifetime of the menu-bar app. Keep the week and the active date.
        let today = UsageDay(date: now(), timezone: timezone)
        let protected = Set((-6...0).map { today.adding(days: $0).cacheKey } + [selectedDay.cacheKey])
        let removable = cache.values.filter { !protected.contains($0.day.cacheKey) }.sorted {
            $0.generatedAt == $1.generatedAt ? $0.day.cacheKey < $1.day.cacheKey : $0.generatedAt < $1.generatedAt
        }
        for entry in removable.prefix(max(0, cache.count - 32)) {
            cache.removeValue(forKey: entry.day.cacheKey)
            acceptedHistoricalRequests.removeValue(forKey: entry.day.cacheKey)
        }
    }

    /// Foreground and backfill results share publication and persistence. Request
    /// order, not completion order, decides which successful response is current.
    private func loadHistorical(_ day: UsageDay, context: UsageDataContext, revision: Int, force: Bool) async throws -> UsageSnapshot? {
        guard !maintenanceInProgress else { throw UsageError.maintenanceInProgress }
        var data = cache[day.cacheKey]
        if force || data?.canReuse(for: day, now: now(), liveInterval: refreshInterval) != true {
            historicalRequest += 1
            let request = historicalRequest
            let fetched = try await service.fetch(day: day, customPath: context.customPath, mode: context.updateMode ?? .claudeOnly)
            try Task.checkCancellation()
            guard revision == generation else { return nil }
            guard request >= acceptedHistoricalRequests[day.cacheKey, default: 0] else { return cache[day.cacheKey] }
            acceptedHistoricalRequests[day.cacheKey] = request
            data = fetched
        }
        guard revision == generation, var data else { return nil }
        data = data.applyingExclusions(modelExclusionPolicy)
        data.dataContext = context
        acceptCostState(data)
        cacheSnapshot(data)
        refreshFailures.removeValue(forKey: day.cacheKey)
        recordHistory(data)
        if selectedDay == day { snapshot = data }
        if day == UsageDay(date: now(), timezone: context.timezone).adding(days: -1) {
            previousSnapshot = data
            await persist(data, slot: .yesterday, revision: revision)
        }
        guard revision == generation else { return nil }
        await persistHistory(revision: revision)
        guard revision == generation else { return nil }
        await publishStatus()
        return cache[day.cacheKey]
    }

    private func scheduleHistoryBackfill() {
        guard historyTask == nil, !maintenanceInProgress, !isRetryingProblem else { return }
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
                    _ = try await self.loadHistorical(day, context: context, revision: revision, force: true)
                    guard revision == self.generation else { return }
                } catch is CancellationError { return }
                catch {
                    guard revision == self.generation else { return }
                    // Failed days stay missing. Retry no more than once an hour; preserve successes.
                    self.historyRetryAfter[day.cacheKey] = self.now().addingTimeInterval(3600)
                    self.refreshFailures[day.cacheKey] = .init(day: day, attemptedAt: self.now(), error: Self.presentable(error))
                    await self.publishStatus()
                }
            }
        }
    }

    // Also allows integration checks to await only the bounded background work.
    func waitForHistoryBackfill() async { await historyTask?.value }

    private func persist(_ data: UsageSnapshot, slot: SnapshotSlot, revision: Int) async {
        do {
            try await repository.write(data, to: slot)
            if revision == generation { storageResult(nil, operation: slot.rawValue) }
        } catch { if revision == generation { storageResult(Self.presentable(error), operation: slot.rawValue) } }
    }

    private func persistHistory(revision: Int) async {
        guard revision == generation, let history else { return }
        do {
            try await repository.writeHistory(history)
            if revision == generation { storageResult(nil, operation: "history") }
        } catch { if revision == generation { storageResult(Self.presentable(error), operation: "history") } }
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
        case .problem(let reference):
            presentedProblem = reference
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
        if !isDemo, snapshot?.dataContext != dataContext || snapshot?.canReuse(for: requested, now: now(), liveInterval: refreshInterval) != true {
            Task { await self.refresh(reason: .selection) }
        }
    }

    static func presentable(_ error: Error) -> UsageError {
        error as? UsageError ?? .processFailed(-1, error.localizedDescription)
    }
}

extension UsageStore {
    func requestReviewChat(_ presented: Bool) {
        reviewChatPresented = presented
        reviewChatRevision += 1
    }

    /// Reset between scenarios; all loading/error transitions still go through refresh and restore.
    func resetForManualReview() {
        precondition(isManualReview)
        publicationRetry?.cancel(); publicationRetry = nil
        widgetReloadTask?.cancel(); widgetReloadTask = nil
        lastWidgetContent = nil; pendingWidgetContent = nil; lastWidgetReload = nil
        publicationFailures = 0
        startupTask?.cancel()
        restoreTask?.cancel()
        restoreTask = nil
        healthClock?.cancel()
        refreshLoop?.cancel()
        historyTask?.cancel()
        historyTask = nil
        refreshIdentity = UUID()
        configurationChanged()
        refreshLoop?.cancel()
        restored = false
        isRefreshing = false
        storageError = nil
        storageFailures.removeAll()
        presentedProblem = nil
        isRetryingProblem = false; recoveryResult = nil; recoveryCompleted = 0; recoveryTotal = 0
        diagnostics = nil
        diagnosticError = nil
        lastAttempt = nil
    }
}
