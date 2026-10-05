import SwiftUI
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
    private func presentationStatus() -> RefreshStatus {
        (try? SnapshotFiles.status(directory: SharedConfiguration.container))
            ?? RefreshStatus(attemptedAt: Date(), message: nil, refreshMinutes: 3, interfaceLanguage: L10n.preference)
    }
    func placeholder(in context: Context) -> UsageWidgetEntry {
        .init(date: Date(), snapshot: SampleData.multiSourceSnapshot(), previous: nil, status: presentationStatus(), history: SampleData.history())
    }
    func getSnapshot(in context: Context, completion: @escaping (UsageWidgetEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        DispatchQueue.global(qos: .utility).async { completion(readEntry()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
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
            completion(Timeline(entries: entries, policy: .after(max(next, entry.date.addingTimeInterval(60)))))
        }
    }
    private func readEntry() -> UsageWidgetEntry {
        do {
            let directory = SharedConfiguration.container
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
            return .init(date: Date(), snapshot: snapshot?.applyingExclusions(policy),
                         previous: previous?.applyingExclusions(policy),
                         status: status, history: history?.applyingExclusions(policy))
        } catch {
            Self.logger.error("Widget snapshot read failed: \(String(describing: error))")
            return .init(date: Date(), snapshot: nil, previous: nil, status: presentationStatus(), storageUnavailable: true)
        }
    }
}

struct UsageWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: UsageWidgetEntry
    var variant: UsageWidgetVariant = .summary
    var body: some View {
        let _ = L10n.preference = entry.status?.interfaceLanguage ?? .system
        UsageWidgetContent(family: family, variant: variant, history: entry.history, snapshot: entry.snapshot, previous: entry.previous,
                           status: entry.status, date: entry.date, storageUnavailable: entry.storageUnavailable)
            .environment(\.locale, (entry.status?.interfaceLanguage ?? .system).locale)
            .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }
}

struct LLMUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedConfiguration.widgetKind, provider: UsageTimelineProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(L10n.text("Сводка"))
        .description(L10n.text("Стоимость, токены и сессии всех локальных LLM-агентов за сегодня."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct LLMUsageSessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedConfiguration.sessionsWidgetKind, provider: UsageTimelineProvider()) { entry in
            UsageWidgetEntryView(entry: entry, variant: .sessions)
        }
        .configurationDisplayName(L10n.text("Сессии"))
        .description(L10n.text("Сессии за день по стоимости. Нажмите на строку, чтобы открыть сессию."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct LLMUsageTrendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedConfiguration.trendWidgetKind, provider: UsageTimelineProvider()) { entry in
            UsageWidgetEntryView(entry: entry, variant: .trend)
        }
        .configurationDisplayName(L10n.text("Динамика"))
        .description(L10n.text("Реальные расходы за 7 дней. Пробелы означают, что данные ещё не получены."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct LLMUsageWidgetBundle: WidgetBundle {
    init() {
        L10n.preference = (try? SnapshotFiles.status(directory: SharedConfiguration.container))?.interfaceLanguage ?? .system
    }
    var body: some Widget {
        LLMUsageWidget()
        LLMUsageSessionsWidget()
        LLMUsageTrendWidget()
    }
}
