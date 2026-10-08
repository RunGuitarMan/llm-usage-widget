import Foundation

/// Bounded, display-only data. Full reports remain in the application's cache;
/// the extension never decodes thousands of sessions to draw seven rows.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    var generatedAt: Date
    var day: UsageDay
    var totals: TokenUsage
    var sessionCount: Int
    var sessions: [UsageSession]

    init(_ source: UsageSnapshot) {
        generatedAt = source.generatedAt
        day = source.day
        totals = source.totals
        totals.reportedAmounts = nil
        sessionCount = source.sessions.count
        // Keep both rankings, with bounded auxiliary memory and no full sort.
        func top(_ sort: SessionSort, count: Int) -> [UsageSession] {
            source.sessions.reduce(into: []) { rows, item in
                rows.append(item)
                rows = Array(sort.sorted(rows).prefix(count))
            }
        }
        var seen = Set<String>()
        sessions = (top(.tokens, count: 3) + top(.cost, count: 4))
            .filter { seen.insert($0.id).inserted }.map { session in
                var row = session
                row.projectPath = nil
                row.modelBreakdowns = []
                row.usage.reportedAmounts = nil
                row.models = Array(row.models.prefix(8)).map { String($0.prefix(256)) }
                return row
            }
    }

    func isStale(now: Date, interval: TimeInterval = 180) -> Bool {
        now >= UsageHealth.staleDate(generatedAt: generatedAt, interval: interval) || !day.isToday(now: now)
    }
}

struct WidgetPresentation: Codable, Equatable, Sendable {
    static let filename = "widget-presentation-v1.json"
    static let maximumBytes = 512 * 1024
    static let fallbackInterval: TimeInterval = 20 * 60
    struct State: Codable, Equatable, Sendable {
        var date: Date
        var problems: [UsageProblem]
    }
    var schemaVersion = 1
    var writerVersion: String
    var writerBuild: String
    var snapshot: WidgetSnapshot?
    var previous: WidgetSnapshot?
    var history: UsageHistory?
    var status: RefreshStatus
    var states: [State]

    init(status source: RefreshStatus, now: Date? = nil) {
        writerVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        writerBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let policy = source.modelExclusionPolicy ?? .init()
        func visible(_ snapshot: UsageSnapshot?) -> UsageSnapshot? {
            guard source.dataContext == nil || source.dataContext.map({ snapshot?.dataContext?.canDisplay(alongside: $0) == true }) == true else { return nil }
            return snapshot?.applyingExclusions(policy)
        }
        let current = visible(source.presentation?.snapshot)
        let prior = visible(source.presentation?.previous)
        let rawHistory = source.presentation?.history
        let historyMatches = source.dataContext.map { rawHistory?.context.canDisplay(alongside: $0) == true } ?? true
        var visibleHistory = historyMatches ? rawHistory?.applyingExclusions(policy) : nil
        if var current {
            let context = source.dataContext ?? current.dataContext ?? .init(timezone: current.day.timezone, customPath: "")
            if visibleHistory == nil { visibleHistory = .init(context: context) }
            current.dataContext = visibleHistory!.context
            visibleHistory?.record(current, today: UsageDay(date: now ?? source.publishedAt ?? source.attemptedAt, timezone: context.timezone), now: now ?? source.publishedAt ?? source.attemptedAt)
        }
        snapshot = current.map(WidgetSnapshot.init)
        previous = prior.map(WidgetSnapshot.init)
        history = visibleHistory
        // History charts need aggregates, not model accounting or raw amounts.
        history?.days = visibleHistory?.days.map { day in
            var value = day
            value.usageComponents = nil
            value.reportedUsage = nil
            value.usage.reportedAmounts = nil
            return value
        } ?? []
        status = source
        status.presentation = nil
        status.modelExclusionPolicy = nil
        // Keep health semantics separate from the provider's fallback schedule.
        let date = now ?? source.publishedAt ?? source.attemptedAt
        let dates = [date] + UsageHealth.transitionDates(snapshot: current, history: visibleHistory, status: source, now: date)
        states = dates.map { date in
            let problems = UsageHealth.problems(snapshot: current, history: visibleHistory, status: source, now: date)
                .prefix(64).map { problem in
                    var result = problem
                    result.models = []
                    result.missingDays = []
                    result.legacyMessage = result.legacyMessage.map { String($0.prefix(512)) }
                    // Widget links open full diagnostics in the app. Do not copy
                    // CLI stderr, transcript content or local paths into this file.
                    switch result.error {
                    case .processFailed(let code, _): result.error = .processFailed(code, "")
                    case .invalidPath: result.error = .invalidPath("")
                    case .malformedJSON: result.error = .malformedJSON("")
                    case .sharedContainer: result.error = .sharedContainer("")
                    default: break
                    }
                    return result
                }
            return State(date: date, problems: Array(problems))
        }
    }

    func problems(at date: Date) -> [UsageProblem] {
        states.last(where: { $0.date <= date })?.problems ?? states.first?.problems ?? []
    }

    static func nextReload(now: Date, dayEnd: Date?, storageUnavailable: Bool) -> Date {
        let fallback = now.addingTimeInterval(storageUnavailable ? 5 * 60 : fallbackInterval)
        guard let dayEnd, dayEnd > now else { return fallback }
        return min(fallback, dayEnd)
    }

    /// Content identity excludes collection bookkeeping but preserves partial-day
    /// history, errors, settings and recalculation state. A periodic heartbeat
    /// refreshes generatedAt even when the totals did not change.
    func contentIdentity() -> Data {
        var value = self
        value.snapshot?.generatedAt = .distantPast
        value.previous?.generatedAt = .distantPast
        value.status.attemptedAt = .distantPast
        value.status.publishedAt = nil
        value.history?.days = history?.days.map { day in
            var copy = day
            copy.capturedAt = day.isPartialDay ? day.day.date : day.day.end
            return copy
        } ?? []
        value.states = states.prefix(1).map { state in
            var copy = state
            copy.date = .distantPast
            copy.problems = state.problems.map { problem in
                var copy = problem; copy.attemptedAt = nil; copy.lastSuccess = nil
                return copy
            }
            return copy
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    func validate() throws {
        func valid(_ snapshot: WidgetSnapshot?) -> Bool {
            guard let snapshot else { return true }
            guard snapshot.sessions.count <= 7, (0...100_000).contains(snapshot.sessionCount),
                  TimeZone(identifier: snapshot.day.timezone) != nil,
                  snapshot.day == UsageDay(date: snapshot.day.date, timezone: snapshot.day.timezone),
                  snapshot.totals.cost.isFinite, (0...1e17).contains(snapshot.totals.cost) else { return false }
            var remaining: Int64 = 500_000_000_000_000_000
            for amount in [snapshot.totals.input, snapshot.totals.output, snapshot.totals.cacheCreate, snapshot.totals.cacheRead, snapshot.totals.additional ?? 0] {
                guard amount >= 0, amount <= remaining else { return false }; remaining -= amount
            }
            return true
        }
        guard schemaVersion == 1, valid(snapshot), valid(previous),
              (history?.days.count ?? 0) <= 7, !states.isEmpty, states.count <= 3,
              states.allSatisfy({ $0.problems.count <= 64 }), status.presentation == nil,
              states.map(\.date) == Array(Set(states.map(\.date))).sorted() else {
            throw UsageError.sharedContainer("Invalid saved widget presentation")
        }
        // Reuse the same value validation for bounded rows and daily aggregates.
        let envelope = UsagePresentation(snapshot: snapshot.map { .init(generatedAt: $0.generatedAt, day: $0.day, sessions: $0.sessions) },
            previous: previous.map { .init(generatedAt: $0.generatedAt, day: $0.day, sessions: $0.sessions) }, history: history)
        var checking = status; checking.presentation = envelope
        try SnapshotFiles.validate(checking)
        guard try JSONEncoder().encode(self).count <= Self.maximumBytes else { throw UsageError.outputTooLarge }
    }
}
