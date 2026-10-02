import SwiftUI

struct TranscriptTimingBadge: View {
    var timing: TranscriptTiming?
    var kind: TranscriptTiming.Kind
    var timezone: String
    @State private var details = false

    private var value: TranscriptTiming { timing ?? .init(kind: kind) }
    var body: some View {
        Button { details.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "stopwatch")
                if value.evidence == .timestamps && value.duration != nil { Text("≈") }
                Text(value.valueText)
                if value.status == .interrupted { Image(systemName: "stop.circle") }
            }.font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(value.title + ": " + value.valueText)
            .accessibilityLabel(value.title + ": " + value.valueText)
            .popover(isPresented: $details, arrowEdge: .bottom) {
                TranscriptTimingDetails(timing: value, timezone: timezone).padding(18).frame(width: 340)
            }
    }
}

struct TranscriptTimingDetails: View {
    var timing: TranscriptTiming
    var timezone: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(timing.title).font(.system(size: 12, weight: .semibold))
            row(L10n.text("Длительность"), timing.valueText)
            if let start = timing.start { row(L10n.text("Начало"), date(start)) }
            if let end = timing.end { row(L10n.text("Окончание"), date(end)) }
            if timing.duration != nil { Text(timing.sourceTitle).foregroundStyle(.secondary) }
            if timing.status == .interrupted { Text(L10n.text("Выполнение прервано")).foregroundStyle(.orange) }
            if timing.kind == .processing {
                Divider()
                row("TTFT", timing.timeToFirstToken.map(TranscriptTimingFormat.duration) ?? L10n.text("Нет данных о времени"))
                Text(L10n.text("TTFT — время до первого токена всего запроса.")).foregroundStyle(.secondary)
                if let rate = timing.tokensPerSecond {
                    row(L10n.text("Средняя скорость запроса"), TranscriptTimingFormat.rate(rate))
                    row(L10n.text("В минуту"), L10n.text("\(TranscriptTimingFormat.number(rate * 60)) токенов/мин"))
                    if let tokens = timing.outputTokens { row(L10n.text("Выходные токены"), UsageFormat.exact(tokens)) }
                } else {
                    row(L10n.text("Средняя скорость запроса"), L10n.text("Нет данных о времени"))
                }
                Text(L10n.text("Общее время включает рассуждения, инструменты и ожидание. Скорость рассчитана по выходным токенам этого запроса, включая рассуждения; это не скорость чистой генерации.")).foregroundStyle(.secondary)
                Text(L10n.text("Время отдельных системных инструкций в журнале не выделено.")).foregroundStyle(.secondary)
            } else if timing.evidence == .timestamps && timing.duration != nil {
                Text(L10n.text("Интервал между началом и завершением события в журнале может включать накладные расходы.")).foregroundStyle(.secondary)
            } else if timing.kind == .tool && timing.duration != nil {
                Text(L10n.text("Длительность измерена агентом; границы события могут включать накладные расходы.")).foregroundStyle(.secondary)
            }
            if timing.duration == nil && timing.status == .complete {
                Text(L10n.text("Журнал не содержит достаточных данных. Промежуток между соседними сообщениями не считается временем генерации.")).foregroundStyle(.secondary)
            }
        }.font(.system(size: 11))
    }
    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
    private func date(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("d MMM y HH:mm:ss.SSS")
        return formatter.string(from: value)
    }
}
