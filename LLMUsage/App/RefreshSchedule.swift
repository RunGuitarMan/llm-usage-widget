import Foundation

enum RefreshMode: String, CaseIterable, Sendable {
    case slow, fast, medium

    var title: String {
        switch self {
        case .slow: return L10n.text("Медленный")
        case .fast: return L10n.text("Быстрый")
        case .medium: return L10n.text("Средний")
        }
    }
}

enum RefreshReason {
    case startup, automatic, manual, selection, configuration

    var updatesSchedule: Bool {
        self == .startup || self == .automatic || self == .configuration
    }
}

struct RefreshIntervals: Equatable, Sendable {
    static let fastOptions = [2, 5, 10, 15, 30]
    static let mediumOptions = [1, 2, 3, 5, 10, 15]
    static let slowOptions = [3, 5, 10, 15, 30, 60]
    static let standard = RefreshIntervals(fastSeconds: 5, mediumMinutes: 1, slowMinutes: 3)

    var fastSeconds: Int
    var mediumMinutes: Int
    var slowMinutes: Int

    var isValid: Bool {
        Self.fastOptions.contains(fastSeconds) && Self.mediumOptions.contains(mediumMinutes)
            && Self.slowOptions.contains(slowMinutes) && mediumMinutes < slowMinutes
    }

    func interval(for mode: RefreshMode) -> TimeInterval {
        switch mode {
        case .fast: return Double(fastSeconds)
        case .medium: return Double(mediumMinutes) * 60
        case .slow: return Double(slowMinutes) * 60
        }
    }

    static func load(from defaults: UserDefaults) -> Self {
        let result = Self(fastSeconds: defaults.object(forKey: "fastRefreshSeconds") as? Int ?? standard.fastSeconds,
                          mediumMinutes: defaults.object(forKey: "mediumRefreshMinutes") as? Int ?? standard.mediumMinutes,
                          slowMinutes: defaults.object(forKey: "slowRefreshMinutes") as? Int ?? standard.slowMinutes)
        // The old fixed refreshMinutes preference must not override the new defaults.
        return result.isValid ? result : .standard
    }

    func save(to defaults: UserDefaults) {
        defaults.set(fastSeconds, forKey: "fastRefreshSeconds")
        defaults.set(mediumMinutes, forKey: "mediumRefreshMinutes")
        defaults.set(slowMinutes, forKey: "slowRefreshMinutes")
    }
}

/// Pure scheduling policy. Dates are supplied by the caller so boundary cases do
/// not need real sleeps or CLI requests. Only automatic/configuration results
/// update the cost baseline; manual/selection results cannot hide an increase.
struct RefreshSchedule {
    private(set) var intervals: RefreshIntervals
    private(set) var mode: RefreshMode = .slow
    private(set) var day: UsageDay?
    private(set) var nextRefresh: Date?
    private var baseline: Double?
    private var unchangedSince: Date?
    private var skipNextFastRefresh = false

    init(intervals: RefreshIntervals = .standard) { self.intervals = intervals }

    var interval: TimeInterval { intervals.interval(for: mode) }

    mutating func reset(day: UsageDay, at now: Date) {
        self = Self(intervals: intervals)
        self.day = day
        nextRefresh = now
    }

    mutating func prepare(day: UsageDay, at now: Date) {
        if self.day != day { reset(day: day, at: now) }
    }

    mutating func configure(_ intervals: RefreshIntervals, at now: Date) {
        guard intervals.isValid, intervals != self.intervals else { return }
        let previousInterval = interval
        self.intervals = intervals
        if interval != previousInterval {
            nextRefresh = now.addingTimeInterval(interval)
            skipNextFastRefresh = false
        }
    }

    mutating func manualRefreshStarted() {
        // Repeated clicks before the same scheduled slot replace that slot once.
        if mode == .fast { skipNextFastRefresh = true }
    }

    mutating func consumeSkippedRefresh(at now: Date) -> Bool {
        guard mode == .fast, skipNextFastRefresh, let nextRefresh, now >= nextRefresh else { return false }
        skipNextFastRefresh = false
        advanceDeadline(past: now)
        return true
    }

    mutating func succeeded(cost: Double, reason: RefreshReason, at now: Date) {
        guard reason.updatesSchedule else { return }
        let previousMode = mode
        let hadBaseline = baseline != nil
        if let baseline {
            // Compare dollars before display rounding; ignore floating-point noise.
            let tolerance = max(1e-9, max(abs(baseline), abs(cost)) * 1e-12)
            if abs(cost - baseline) > tolerance {
                mode = .fast
                unchangedSince = now
                self.baseline = cost
            } else if mode != .slow {
                if unchangedSince == nil { unchangedSince = now }
                let quietFor = now.timeIntervalSince(unchangedSince!)
                if mode == .fast && quietFor >= 60 {
                    mode = .medium
                    unchangedSince = now
                } else if mode == .medium && quietFor >= 180 {
                    mode = .slow
                    unchangedSince = nil
                }
            }
        } else {
            baseline = cost
        }
        skipNextFastRefresh = false
        if mode != previousMode || !hadBaseline {
            nextRefresh = now.addingTimeInterval(interval)
        } else {
            advanceDeadline(past: now)
        }
    }

    mutating func failed(reason: RefreshReason, at now: Date) {
        guard reason.updatesSchedule else { return }
        // A failed query is not evidence of inactivity. Start a fresh quiet
        // window on the next successful comparison, retaining the last cost.
        unchangedSince = nil
        advanceDeadline(past: now)
    }

    private mutating func advanceDeadline(past now: Date) {
        guard let nextRefresh else { self.nextRefresh = now.addingTimeInterval(interval); return }
        guard nextRefresh <= now else { return }
        // Keep the cadence and coalesce overdue slots, including after sleep or
        // a request that took longer than its interval. Never build a backlog.
        let slots = floor(now.timeIntervalSince(nextRefresh) / interval) + 1
        self.nextRefresh = nextRefresh.addingTimeInterval(slots * interval)
    }
}
