import Foundation
import WidgetKit
import OSLog

struct UsageWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: UsageSnapshot?
    var previous: UsageSnapshot?
    var status: RefreshStatus?
    var history: UsageHistory? = nil
    var storageUnavailable = false
}

struct UsageTimelineProvider: TimelineProvider {
    private static let logger = Logger(subsystem: "local.ClaudeUsage.Widget", category: "Snapshot")
    var directory: URL? = SharedConfiguration.container
    var now: () -> Date = Date.init
    var kind: String = SharedConfiguration.widgetKind

    private func presentationStatus() -> RefreshStatus {
        (try? SnapshotFiles.status(directory: directory))
            ?? RefreshStatus(attemptedAt: now(), message: nil, refreshMinutes: 3, interfaceLanguage: L10n.preference)
    }
    func placeholder(in context: Context) -> UsageWidgetEntry {
        previewEntry()
    }
    func getSnapshot(in context: Context, completion: @escaping (UsageWidgetEntry) -> Void) {
        if context.isPreview { completion(previewEntry()); return }
        DispatchQueue.global(qos: .utility).async {
            let entry = readEntry()
            recordDelivery(entry, family: context.family, phase: "snapshot")
            completion(entry)
        }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let timeline = makeTimeline()
            if let entry = timeline.entries.first { recordDelivery(entry, family: context.family, phase: "timeline") }
            completion(timeline)
        }
    }
    private func recordDelivery(_ entry: UsageWidgetEntry, family: WidgetFamily, phase: String) {
        let bundle = Bundle.main.bundleIdentifier ?? "unknown"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        // No totals, session IDs, paths or source content in this diagnostic receipt.
        Self.logger.notice("WidgetDelivery bundle=\(bundle, privacy: .public) version=\(version, privacy: .public) kind=\(kind, privacy: .public) family=\(family.rawValue) phase=\(phase, privacy: .public) generation=\(entry.snapshot?.generatedAt.timeIntervalSince1970 ?? 0) storageUnavailable=\(entry.storageUnavailable)")
    }
    func makeTimeline() -> Timeline<UsageWidgetEntry> {
        let entry = readEntry()
        let interval = entry.status?.refreshInterval ?? 180
        let next = min(entry.date.addingTimeInterval(interval), entry.snapshot?.day.end ?? entry.date.addingTimeInterval(interval))
        var entries = [entry]
        if let snapshot = entry.snapshot {
            // Pre-scheduled entries update labels even when the app is closed or macOS
            // delays a new timeline request. Yesterday's cost is never relabeled today.
            let transitions = [snapshot.generatedAt.addingTimeInterval(max(interval * 2, 600) + 1), snapshot.day.end]
            for date in Set(transitions).sorted() where date > entry.date {
                var transition = entry
                transition.date = date
                entries.append(transition)
            }
        }
        return Timeline(entries: entries, policy: .after(max(next, entry.date.addingTimeInterval(60))))
    }
    /// Gallery previews must be synchronous and independent of disk access.
    func previewEntry() -> UsageWidgetEntry {
        let date = now()
        let snapshot = SampleData.multiSourceSnapshot(now: date)
        return .init(date: date, snapshot: snapshot, previous: nil,
                     status: .init(attemptedAt: date, message: nil, refreshMinutes: 3),
                     history: SampleData.history(now: date))
    }

    func readEntry() -> UsageWidgetEntry {
        do {
            let status = try SnapshotFiles.status(directory: directory)
            let policy = status?.modelExclusionPolicy ?? ModelExclusionPolicy()
            L10n.preference = status?.interfaceLanguage ?? .system
            let stored = try SnapshotFiles.read(.today, directory: directory)
            let snapshot = status?.dataContext == nil || status?.dataContext.map { stored?.dataContext?.canDisplay(alongside: $0) == true } == true ? stored : nil
            let savedPrevious = try? SnapshotFiles.read(.yesterday, directory: directory)
            let previous = status?.dataContext == nil || status?.dataContext.map { savedPrevious?.dataContext?.canDisplay(alongside: $0) == true } == true ? savedPrevious : nil
            let savedHistory = try? SnapshotFiles.history(directory: directory)
            let history = status?.dataContext.map { savedHistory?.context.canDisplay(alongside: $0) == true } == true ? savedHistory : nil
            Self.logger.notice("Snapshot read: present=\(snapshot != nil), sessions=\(snapshot?.sessions.count ?? 0), generatedAt=\(snapshot?.generatedAt.timeIntervalSince1970 ?? 0), localFiles=\(SharedConfiguration.usesLocalWidgetStorage), historyDays=\(history?.days.count ?? 0), language=\(L10n.preference.rawValue, privacy: .public), resolvedLanguage=\(L10n.language.rawValue, privacy: .public)")
            return .init(date: now(), snapshot: snapshot?.applyingExclusions(policy),
                         previous: previous?.applyingExclusions(policy),
                         status: status, history: history?.applyingExclusions(policy))
        } catch {
            Self.logger.error("Widget snapshot read failed: \(String(describing: error))")
            return .init(date: now(), snapshot: nil, previous: nil, status: presentationStatus(), storageUnavailable: true)
        }
    }
}
