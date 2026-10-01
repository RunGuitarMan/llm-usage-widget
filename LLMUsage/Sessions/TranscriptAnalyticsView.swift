import SwiftUI

enum TranscriptAnalysisTab: String, CaseIterable, Identifiable {
    case chat, expensive, tools
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: return L10n.text("Чат")
        case .expensive: return L10n.text("Дорогие обращения")
        case .tools: return L10n.text("Инструменты")
        }
    }
}

enum TranscriptUsageFormat {
    static func cost(_ usage: TokenUsage) -> String {
        guard usage.costIsIncomplete != true else { return L10n.text("Стоимость неизвестна") }
        return "$" + usage.cost.formatted(.number.locale(L10n.locale).precision(.fractionLength(2...6)))
    }
}

struct TranscriptTokenLine: View {
    var usage: TokenUsage
    var body: some View {
        HStack(spacing: 12) {
            TokenDistribution(usage: usage, height: 6)
                .frame(minWidth: 80, maxWidth: .infinity)
                .help(usage.categories.map { "\($0.title): \(UsageFormat.exact(usage.value(for: $0)))" }.joined(separator: "\n"))
            Text(UsageFormat.tokens(usage.total)).foregroundStyle(.secondary)
                .frame(minWidth: 45, alignment: .trailing)
            Text(usage.costIsIncomplete == true ? "—" : TranscriptUsageFormat.cost(usage))
                .fontWeight(.medium).foregroundStyle(.primary).frame(minWidth: 76, alignment: .trailing)
                .help(TranscriptUsageFormat.cost(usage))
        }.font(.system(size: 11)).monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("\(UsageFormat.exact(usage.total)) токенов") + ", " + TranscriptUsageFormat.cost(usage)
                + ", " + usage.categories.map { "\($0.title): \(UsageFormat.exact(usage.value(for: $0)))" }.joined(separator: ", "))
    }
}

struct TranscriptTokenLegend: View {
    var usage: TokenUsage
    var body: some View {
        HStack(spacing: 16) {
            ForEach(usage.categories) { category in
                HStack(spacing: 5) {
                    Circle().fill(category.color).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(category.title)
                }.help(UsageFormat.exact(usage.value(for: category)) + L10n.text(" токенов"))
            }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }
}

struct TranscriptUsageBadge: View {
    var event: TranscriptEvent
    var requests: [TranscriptRequest]
    var supported: Bool
    var policy: ModelExclusionPolicy
    var jump: (String) -> Void = { _ in }
    @State private var details = false

    var body: some View {
        if !requests.isEmpty {
            HStack(spacing: 10) {
                if let first = requests.first {
                    let shared = first.anchorID != event.id
                    Button { if let id = first.anchorID { jump(id) } } label: {
                        HStack(spacing: 4) {
                            if shared { Image(systemName: "link") }
                            Text("#" + (first.id.components(separatedBy: "-").last ?? first.id))
                        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).disabled(!shared)
                        .help(shared ? L10n.text("Общий расход обращения, не отдельная плата за сообщение. Перейти к началу обращения.") : L10n.text("Обращение к модели"))
                }
                Button { details.toggle() } label: {
                    TranscriptTokenLine(usage: requests.reduce(.zero) { $0 + $1.usage })
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(L10n.text("Состав расхода обращения"))
                if requests.allSatisfy(\.isReplay) { Image(systemName: "arrow.uturn.backward").help(L10n.text("Перенесённая история")) }
                if requests.contains(where: { !policy.includes($0.modelForAccounting) }) {
                    Image(systemName: "minus.circle").help(L10n.text("Не учитывается в итогах"))
                }
            }.foregroundStyle(.secondary)
                .popover(isPresented: $details, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(requests) { request in TranscriptRequestDetails(request: request, policy: policy) }
                        }.padding(18)
                    }.frame(width: 330).frame(maxHeight: 450)
                }
        } else if supported {
            Text(L10n.text("Расход не записан")).font(.system(size: 10)).foregroundStyle(.secondary)
                .help(event.kind == .user ? L10n.text("Input включает весь контекст обращения. Отдельный расход пользовательского сообщения в журнале не записан.") : L10n.text("Расход не записан"))
        }
    }
}

struct TranscriptRequestDetails: View {
    var request: TranscriptRequest
    var policy: ModelExclusionPolicy
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.model.isEmpty ? L10n.text("Модель неизвестна") : request.model).font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
            TokenUsageDetails(usage: request.usage)
            if request.reasoning > 0 {
                HStack {
                    Text((request.usage.additional ?? 0) > 0 ? L10n.text("Рассуждения в дополнительных токенах") : L10n.text("В том числе рассуждения в Output"))
                    Spacer()
                    Text(UsageFormat.exact(request.reasoning)).monospacedDigit()
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Divider()
            Text(TranscriptUsageFormat.cost(request.usage)).font(.system(size: 14, weight: .semibold))
            if let speed = request.billing.speed { Text("Service tier: " + speed).font(.system(size: 10)).foregroundStyle(.secondary) }
            if !policy.includes(request.modelForAccounting) { Text(L10n.text("Не учитывается в итогах")).font(.system(size: 11)).foregroundStyle(.secondary) }
            if request.isReplay { Text(L10n.text("Перенесённая история")).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}

struct TranscriptMetricsView: View {
    var summary: TranscriptUsageSummary
    var transcript: SessionTranscript
    var expected: TokenUsage?
    var isLoading: Bool
    var error: String?
    @State private var details = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !transcript.usageSupported {
                Label(L10n.text("Детализация расхода для этого источника недоступна"), systemImage: "info.circle")
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { amount; Spacer(minLength: 8); status }
                    VStack(alignment: .leading, spacing: 6) { amount; status }
                }
                if !summary.requests.isEmpty {
                    TokenDistribution(usage: summary.reported, height: 6)
                    TranscriptTokenLegend(usage: summary.reported)
                }
                if summary.included.total != summary.reported.total || summary.included.cost != summary.reported.cost {
                    Text(L10n.text("Учтено: \(TranscriptUsageFormat.cost(summary.included)) · \(UsageFormat.tokens(summary.included.total)) токенов"))
                        .foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.orange).lineLimit(2).help(error) }
            }
        }.font(.system(size: 11))
    }
    private var amount: some View {
        HStack(spacing: 6) {
            if summary.requests.isEmpty { Text(L10n.text("Нет данных о расходе")) }
            else {
            Text(TranscriptUsageFormat.cost(summary.reported)).fontWeight(.semibold)
            Text("·")
            Text(L10n.text("\(UsageFormat.tokens(summary.reported.total)) токенов"))
            Text("·")
            Text(L10n.text("Обращений: \(summary.requests.count)"))
            }
        }.foregroundStyle(.secondary)
    }
    private var status: some View {
        Button { details.toggle() } label: {
            if isLoading { Label(L10n.text("Расчёт стоимости…"), systemImage: "clock") }
            else if let expected, summary.reconciles(with: expected, transcript: transcript) {
                Label(L10n.text("Сумма совпадает"), systemImage: "checkmark.circle").foregroundStyle(.green)
            } else {
                Label(expected == nil ? L10n.text("Итог по журналу") : L10n.text("Сверка неполная"), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain).popover(isPresented: $details) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Сверка расходов")).font(.headline)
                if let expected {
                    Text(L10n.text("Отчёт: \(TranscriptUsageFormat.cost(expected)) · \(UsageFormat.exact(expected.total)) токенов"))
                    Text(L10n.text("Журнал: \(TranscriptUsageFormat.cost(summary.reported)) · \(UsageFormat.exact(summary.reported.total)) токенов"))
                    if !summary.reconciles(with: expected, transcript: transcript) {
                        Text(L10n.text("Нераспределённые токены: \(expected.total - summary.reported.total)"))
                        if expected.costIsIncomplete != true, summary.reported.costIsIncomplete != true {
                            Text(L10n.text("Разница стоимости: \((expected.cost - summary.reported.cost).formatted(.currency(code: "USD").precision(.fractionLength(2...6))))"))
                        }
                    }
                } else { Text(L10n.text("Вся сессия. Без сверки с дневным отчётом.")) }
                if transcript.imported { Text(L10n.text("Выбран отдельный файл; соответствие сессии не подтверждено.")) }
                if summary.unknownDates > 0 { Text(L10n.text("Без времени: \(summary.unknownDates) обращений")) }
                if transcript.usageUncertain { Text(L10n.text("Часть исходных данных не подтверждена.")) }
            }.font(.system(size: 12)).padding(18).frame(width: 360, alignment: .leading)
        }
    }
}

struct TranscriptAnalysisView: View {
    var tab: TranscriptAnalysisTab
    var transcript: SessionTranscript
    var summary: TranscriptUsageSummary
    var query: String
    var policy: ModelExclusionPolicy
    var jump: (String) -> Void
    @State private var selected: String?
    private var events: [String: TranscriptEvent] { Dictionary(uniqueKeysWithValues: transcript.events.map { ($0.id, $0) }) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if tab == .expensive {
                    let lookup = events
                    let requests = summary.expensiveRequests.filter { request in
                        query.isEmpty || request.model.localizedCaseInsensitiveContains(query)
                            || request.eventIDs.contains { lookup[$0]?.matches(query) == true }
                    }
                    if requests.isEmpty { empty }
                    ForEach(requests) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(request.model.isEmpty ? L10n.text("Модель неизвестна") : request.model).fontWeight(.medium)
                                    if let event = request.eventIDs.compactMap({ lookup[$0] }).first {
                                        Text(event.text.isEmpty ? event.title : event.text).lineLimit(2).foregroundStyle(.secondary)
                                    }
                                    if !policy.includes(request.modelForAccounting) { Text(L10n.text("Не учитывается в итогах")).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 8)
                                Button { selected = request.id } label: { Image(systemName: "info.circle") }
                                    .help(L10n.text("Состав расхода обращения"))
                                    .popover(isPresented: Binding(get: { selected == request.id }, set: { if !$0 { selected = nil } })) {
                                        TranscriptRequestDetails(request: request, policy: policy).padding(18).frame(width: 330)
                                    }
                                Button { if let id = request.anchorID { jump(id) } } label: { Image(systemName: "arrow.up.forward") }
                                    .help(L10n.text("Перейти к сообщению"))
                            }.buttonStyle(.borderless)
                            TranscriptTokenLine(usage: request.usage)
                        }.font(.system(size: 12)).padding(.vertical, 14)
                        Divider()
                    }
                } else {
                    Text(L10n.text("Связанные обращения, не отдельная цена инструмента")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 12)
                    let tools = summary.tools.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) }
                    if tools.isEmpty { empty }
                    ForEach(tools) { tool in
                        VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 16) {
                            Text(tool.id).fontWeight(.medium).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Text(L10n.text("Вызовов: \(tool.count)")).monospacedDigit()
                            Menu {
                                ForEach(Array(tool.eventIDs.enumerated()), id: \.element) { index, id in
                                    Button(L10n.text("Вызов \(index + 1)")) { jump(id) }
                                }
                            } label: { Image(systemName: "arrow.up.forward") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.text("Перейти к вызову"))
                        }
                        if !tool.requestIDs.isEmpty { TranscriptTokenLine(usage: tool.usage) }
                        else { Text(L10n.text("Стоимость неизвестна")).foregroundStyle(.secondary) }
                        }.font(.system(size: 12)).padding(.vertical, 14)
                        Divider()
                    }
                }
            }.padding(.horizontal, 28).padding(.vertical, 18)
        }
    }
    private var empty: some View {
        Text(L10n.text("Нет данных для показа")).font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 30)
    }
}
