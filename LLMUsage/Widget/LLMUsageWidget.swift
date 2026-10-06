import SwiftUI
import WidgetKit
import OSLog

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
        StaticConfiguration(kind: SharedConfiguration.sessionsWidgetKind, provider: UsageTimelineProvider(kind: SharedConfiguration.sessionsWidgetKind)) { entry in
            UsageWidgetEntryView(entry: entry, variant: .sessions)
        }
        .configurationDisplayName(L10n.text("Сессии"))
        .description(L10n.text("Сессии за день по стоимости. Нажмите на строку, чтобы открыть сессию."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct LLMUsageTrendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedConfiguration.trendWidgetKind, provider: UsageTimelineProvider(kind: SharedConfiguration.trendWidgetKind)) { entry in
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
