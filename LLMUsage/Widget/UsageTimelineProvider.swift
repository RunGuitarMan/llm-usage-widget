import Foundation
import WidgetKit
import OSLog

struct UsageWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
    var previous: WidgetSnapshot?
    var status: RefreshStatus?
    var history: UsageHistory? = nil
    var storageUnavailable = false
    var presentation: WidgetPresentation? = nil
    var problems: [UsageProblem] {
        if storageUnavailable { return [.init(reference: .init(kind: .storage))] }
        return presentation?.problems(at: date) ?? []
    }
}

struct UsageTimelineProvider: TimelineProvider {
    private static let logger = Logger(subsystem: "local.ClaudeUsage.Widget", category: "Snapshot")
    private var directoryOverride: URL?
    private var resolvesSharedDirectory = true
    var directory: URL? { resolvesSharedDirectory ? SharedConfiguration.container : directoryOverride }
    var now: () -> Date = Date.init
    var kind: String = SharedConfiguration.widgetKind

    init(now: @escaping () -> Date = Date.init, kind: String = SharedConfiguration.widgetKind) {
        self.now = now; self.kind = kind
    }
    init(directory: URL?, now: @escaping () -> Date = Date.init, kind: String = SharedConfiguration.widgetKind) {
        self.directoryOverride = directory; self.resolvesSharedDirectory = false
        self.now = now; self.kind = kind
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
        let writer = entry.presentation.map { "\($0.writerVersion)(\($0.writerBuild))" } ?? "legacy"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        // No totals, session IDs, paths or source content in this diagnostic receipt.
        Self.logger.notice("WidgetDelivery bundle=\(bundle, privacy: .public) version=\(version, privacy: .public) writer=\(writer, privacy: .public) kind=\(kind, privacy: .public) family=\(family.rawValue) phase=\(phase, privacy: .public) generation=\(entry.snapshot?.generatedAt.timeIntervalSince1970 ?? 0) storageUnavailable=\(entry.storageUnavailable)")
    }
    func makeTimeline() -> Timeline<UsageWidgetEntry> {
        let entry = readEntry()
        let next = WidgetPresentation.nextReload(now: entry.date, dayEnd: entry.snapshot?.day.end,
                                                storageUnavailable: entry.storageUnavailable)
        var entries = [entry]
        for date in Array(Set(entry.presentation?.states.map(\.date) ?? [])).sorted() where date > entry.date {
            var transition = entry
            transition.date = date
            entries.append(transition)
        }
        return Timeline(entries: entries, policy: .after(next))
    }
    /// Gallery previews must be synchronous and independent of disk access.
    func previewEntry() -> UsageWidgetEntry {
        let date = now()
        let snapshot = SampleData.multiSourceSnapshot(now: date)
        let status = RefreshStatus(attemptedAt: date, message: nil, refreshMinutes: 3,
            presentation: .init(snapshot: snapshot, previous: nil, history: SampleData.history(now: date)))
        return entry(WidgetPresentation(status: status, now: date), at: date)
    }

    private func entry(_ data: WidgetPresentation, at date: Date) -> UsageWidgetEntry {
        .init(date: date, snapshot: data.snapshot, previous: data.previous, status: data.status,
              history: data.history, presentation: data)
    }

    func readEntry() -> UsageWidgetEntry {
        do {
            if let data: WidgetPresentation = try SnapshotFiles.readValue(name: WidgetPresentation.filename,
                directory: directory, maximumBytes: WidgetPresentation.maximumBytes, dateDecoding: .deferredToDate) {
                try data.validate()
                return entry(data, at: now())
            }
            // Upgrade/clean-install fallback only. A damaged current document
            // must not silently resurrect a different context from legacy files.
            let legacy = try SnapshotFiles.presentation(directory: directory)
            var status = legacy.status ?? RefreshStatus(attemptedAt: .distantPast, message: nil, refreshMinutes: 3)
            status.presentation = .init(snapshot: legacy.snapshot, previous: legacy.previous, history: legacy.history)
            var result = entry(WidgetPresentation(status: status, now: now()), at: now())
            result.storageUnavailable = legacy.storageUnavailable
            return result
        } catch {
            Self.logger.error("Widget snapshot read failed: \(String(describing: error))")
            return .init(date: now(), snapshot: nil, previous: nil, status: nil, storageUnavailable: true)
        }
    }
}
