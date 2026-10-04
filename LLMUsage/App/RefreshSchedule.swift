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
        self == .startup || self == .automatic || self == .manual || self == .configuration
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
/// not need real sleeps or CLI requests. Manual and automatic results share the
/// cost baseline and quiet windows; selection-only results leave them untouched.
struct RefreshSchedule {
    private(set) var intervals: RefreshIntervals
    private(set) var mode: RefreshMode = .slow
    private(set) var day: UsageDay?
    private(set) var nextRefresh: Date?
    private var baseline: Double?
    private var unchangedSince: Date?
    private var skipNextFastRefresh = false
    private var lastObservedTime: Date?

    init(intervals: RefreshIntervals = .standard) { self.intervals = intervals }

    var interval: TimeInterval { intervals.interval(for: mode) }

    mutating func reset(day: UsageDay, at now: Date) {
        self = Self(intervals: intervals)
        self.day = day
        nextRefresh = now
        lastObservedTime = now
    }

    mutating func prepare(day: UsageDay, at now: Date) {
        if self.day != day { reset(day: day, at: now) }
        observeTime(at: now)
    }

    private mutating func observeTime(at now: Date) {
        // Sleep uses a monotonic clock, while deadlines and quiet windows use
        // wall time. Rebase them after a backward correction, even within a day.
        if let day, lastObservedTime.map({ now < $0 }) == true { reset(day: day, at: now) }
        lastObservedTime = now
    }

    mutating func configure(_ intervals: RefreshIntervals, at now: Date) {
        guard intervals.isValid, intervals != self.intervals else { return }
        observeTime(at: now)
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
        observeTime(at: now)
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
        // A manual result updates the policy immediately, but keeps the existing
        // cadence (and pending fast-slot skip) while the mode stays the same.
        // A mode change or first baseline must arm the corresponding interval.
        if reason == .manual, mode == previousMode, hadBaseline { return }
        skipNextFastRefresh = false
        if mode != previousMode || !hadBaseline {
            nextRefresh = now.addingTimeInterval(interval)
        } else {
            advanceDeadline(past: now)
        }
    }

    mutating func failed(reason: RefreshReason, at now: Date) {
        guard reason.updatesSchedule else { return }
        observeTime(at: now)
        // A failed query is not evidence of inactivity. Start a fresh quiet
        // window on the next successful comparison, retaining the last cost.
        unchangedSince = nil
        if reason != .manual { advanceDeadline(past: now) }
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
