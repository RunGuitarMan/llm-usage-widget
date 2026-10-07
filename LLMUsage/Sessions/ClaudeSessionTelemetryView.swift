import SwiftUI

struct ClaudeSessionTelemetryView: View {
    @ObservedObject var coordinator: ClaudeTelemetryCoordinator
    var session: UsageSession
    var transcript: SessionTranscript?
    var day: UsageDay?
    var timezone: String
    var pricingKey: String?
    var navigate: (String) -> Void
    @State private var expanded = false
    @State private var result: TelemetryReconciliation?
    @State private var showExport = false
    private var sid: String { session.rawID.lowercased() }
    private var available: Bool { coordinator.snapshot.sessions[sid]?.isEmpty == false }
    private struct UpdateKey: Hashable {
        var revision: Int; var transcriptID: UUID?; var priced: Int; var price: Double; var day: String?
    }
    private var updateKey: UpdateKey { .init(revision: coordinator.sessionRevisions[sid] ?? 0, transcriptID: transcript?.id,
        priced: transcript?.requests.filter(\.priced).count ?? 0, price: transcript?.requests.reduce(0) { $0 + $1.usage.cost } ?? 0, day: day?.key) }
    private func t(_ ru: String, _ en: String) -> String { TelemetryText.choose(ru, en) }
    var body: some View {
        Group {
            if available || coordinator.enabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button { expanded.toggle() } label: {
                            Label(t("Телеметрия", "Telemetry"), systemImage: expanded ? "chevron.down" : "chevron.right")
                        }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).accessibilityIdentifier("chat-telemetry-toggle")
                        Text(coordinator.enabled ? coordinator.statusText : t("Сбор выключен", "Collection off")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(t("Экспорт…", "Export…")) { showExport = true }.font(.caption).disabled(!available)
                    }
                    if !available {
                        Text(t("Ожидаем API-события этой сессии. Отсутствие событий не означает нулевой расход.", "Waiting for this session’s API events. No events does not mean zero cost.")).font(.caption).foregroundStyle(.secondary)
                    } else if let result {
                        Text(t("Сопоставлено \(result.matched) из \(result.mainRequests) основных запросов", "Matched \(result.matched) of \(result.mainRequests) main requests"))
                            .font(.caption).accessibilityIdentifier("chat-telemetry-coverage")
                        if expanded {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    Text(t("Телеметрия дополняет расчёт JSONL + modelUsage; расходы повторно не начисляются. Сбор может быть частичным даже при совпадении всех видимых запросов.", "Telemetry supplements JSONL + modelUsage accounting without adding charges again. Collection can be partial even when every visible request matches."))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let claude = result.claudeMatchedCost, let app = result.appMatchedCost {
                                        Text("Claude: \(money(claude)) · LLM Usage: \(money(Decimal(app)))").font(.caption.monospaced())
                                        Text(t("Один и тот же набор сопоставленных запросов. Разница может быть связана с тарифами или версией расчёта.", "The same matched request set. Differences can come from rates or pricing versions.")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let matches = result.snapshotCountersMatch {
                                        Text(matches ? t("Счётчики всей сессии совпали с валидным snapshot; это не доказывает полноту всех скрытых вызовов.", "Whole-session counters match the validated snapshot; this does not prove coverage of every hidden call.") : t("Телеметрия не покрывает счётчики всей сессии из snapshot.", "Telemetry does not cover the whole-session snapshot counters.")).font(.caption)
                                        if let claude = result.sessionClaudeCost, let app = result.sessionAppCost {
                                            Text(t("Контекст всей сессии", "Whole-session context") + ": Claude \(money(claude)) · LLM Usage \(money(Decimal(app)))").font(.caption.monospaced())
                                        }
                                    }
                                    DisclosureGroup(t("Интервалы и ограничения сбора", "Collection intervals and limitations")) {
                                        ForEach(Array(coordinator.snapshot.coverage.intervals.enumerated()), id: \.offset) { _, interval in
                                            Text("\(UsageFormat.date(interval.start, timezone: timezone, includeTime: true)) → \(interval.end.map { UsageFormat.date($0, timezone: timezone, includeTime: true) } ?? t("сейчас", "now"))").font(.caption)
                                        }
                                        Text(t("Удалено: \(coordinator.snapshot.coverage.removed); повреждено: \(coordinator.snapshot.coverage.corrupted). API duration — время отдельного вызова; сумма параллельных вызовов не является длительностью сессии. TTL и отсутствующие попытки не восстанавливаются.", "Removed: \(coordinator.snapshot.coverage.removed); damaged: \(coordinator.snapshot.coverage.corrupted). API duration measures one call; parallel durations do not equal session elapsed time. TTL and missing attempts are not inferred."))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    rows(result.rows.filter { ![.service, .error].contains($0.match) }, heading: t("Основные и несопоставленные обращения", "Main and unlinked requests"))
                                    rows(result.rows.filter { $0.match == .service }, heading: t("Служебные вызовы · уже учтены в snapshot при его наличии", "Service calls · already accounted for when a valid snapshot exists"))
                                    rows(result.rows.filter { $0.match == .error }, heading: t("API-ошибки", "API errors"))
                                    if result.rows.isEmpty { Text(t("В выбранном периоде событий нет.", "No events in this period.")).font(.caption) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 260)
                        }
                    }
                }.padding(.horizontal, 24).padding(.vertical, 10).background(.quaternary.opacity(0.18))
                    .accessibilityIdentifier("chat-telemetry")
            }
        }
        .background { if ManualReviewController.active != nil { TelemetryReviewProbe(kind: "chat", value: result?.matched ?? 0, action: { expanded = true }) } }
        .task(id: updateKey) {
            guard available else { result = nil; return }
            let sid = sid, transcript = transcript, day = day
            do {
                let events = try await coordinator.store.events(sessionID: sid)
                let work = Task.detached(priority: .utility) { ClaudeTelemetryReconciler.reconcile(sessionID: sid, events: events, transcript: transcript, day: day) }
                let value = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
                guard !Task.isCancelled else { return }; result = value
            } catch { result = nil }
        }
        .sheet(isPresented: $showExport) {
            ClaudeTelemetryExportView(coordinator: coordinator, timezone: timezone, pricingKey: pricingKey, initialIDs: [sid],
                                      initialTranscripts: transcript.map { [sid: $0] } ?? [:])
        }
    }
    @ViewBuilder private func rows(_ rows: [TelemetryReconciliation.Row], heading: String) -> some View {
        if !rows.isEmpty {
            Text(heading).font(.system(size: 12, weight: .semibold))
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(name(row)).font(.caption.bold())
                        Spacer()
                        Text(UsageFormat.date(row.event.date, timezone: timezone, includeTime: true)).font(.caption).foregroundStyle(.secondary)
                        if row.match == .matched, let id = row.request?.anchorID {
                            Button(t("К сообщению", "Go to message")) { navigate(id) }.font(.caption)
                        }
                    }
                    Text(row.event.model ?? t("Модель неизвестна", "Unknown model")).font(.caption).foregroundStyle(.secondary)
                    if let duration = row.event.durationMS { Text("API: \(duration.formatted(.number.precision(.fractionLength(0...2)))) ms").font(.caption.monospaced()) }
                    if row.match == .error {
                        Text("HTTP: \(row.event.statusCode.map(String.init) ?? "—") · " + t("Счётчик попыток: ", "Reported attempts: ") + (row.event.attempt.map(String.init) ?? "—") + " · \(errorName(row.event.errorCategory))").font(.caption)
                    } else {
                        Text("In \(number(row.event.input)) · Out \(number(row.event.output)) · Read \(number(row.event.cacheRead)) · Write \(number(row.event.cacheWrite))").font(.caption.monospaced())
                        Text("Claude: \(row.event.cost.map(money) ?? "—") · LLM Usage: \(row.request.flatMap { $0.priced ? money(Decimal($0.usage.cost)) : nil } ?? "—")").font(.caption.monospaced())
                        if row.match == .countersDiffer, let request = row.request {
                            Text("JSONL: In \(request.usage.input) · Out \(request.usage.output) · Read \(request.usage.cacheRead) · Write \(request.usage.cacheCreate)").font(.caption.monospaced()).foregroundStyle(.orange)
                        }
                    }
                    if row.event.usesReceiveTime { Text(t("Использовано время получения: время события отсутствует.", "Receive time used: event timestamp is missing.")).font(.caption).foregroundStyle(.secondary) }
                    if row.event.microsDisagree { Text(t("Цена в micros отличается от decimal-оценки Claude.", "Micros differ from Claude’s decimal estimate.")).font(.caption).foregroundStyle(.orange) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private func number(_ value: Int64?) -> String { value.map(String.init) ?? "—" }
    private func money(_ value: Decimal) -> String {
        var input = value, rounded = Decimal()
        NSDecimalRound(&rounded, &input, 9, .plain)
        return "$" + NSDecimalNumber(decimal: rounded).stringValue
    }
    private func errorName(_ category: ClaudeTelemetryEvent.ErrorCategory?) -> String {
        switch category {
        case .authentication: return t("Авторизация", "Authentication")
        case .rateLimit: return t("Лимит запросов", "Rate limit")
        case .server: return t("Ошибка сервера", "Server error")
        case .request: return t("Ошибка запроса", "Request error")
        default: return t("Категория неизвестна", "Unknown category")
        }
    }
    private func name(_ row: TelemetryReconciliation.Row) -> String {
        switch row.match {
        case .matched: return t("Сопоставлено", "Matched")
        case .countersDiffer: return t("ID совпал; счётчики неполны или различаются", "Same ID; counters missing or different")
        case .modelDiffers: return t("ID совпал; модель различается", "Same ID; model differs")
        case .ambiguous: return t("Не сопоставлено — неоднозначный ID", "Unlinked — ambiguous ID")
        case .unlinked: return t("Не сопоставлено", "Unlinked")
        case .conflict: return t("Конфликт данных одного ID; не суммируется", "Conflicting data for one ID; not summed")
        case .error: return t("Ошибка API", "API error")
        case .service:
            if row.event.source == .title { return t("Название сессии", "Session title") }
            if row.event.source == .rename { return t("Переименование сессии", "Session rename") }
            return t("Сжатие контекста", "Context compaction")
        }
    }
}
