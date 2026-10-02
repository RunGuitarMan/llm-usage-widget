import SwiftUI

struct SessionsView: View {
    @ObservedObject var store: UsageStore
    @StateObject private var results: SearchResults<SessionSearchRequest, SessionSearchResult>
    @State private var search = ""
    @State private var model = ""
    @State private var sort = SessionSort.cost
    @State private var searchFocusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var filterEffects

    init(store: UsageStore) {
        self.store = store
        let request = SessionSearchRequest(sessions: store.snapshot?.sessions ?? [], source: store.sourceFilter)
        _results = StateObject(wrappedValue: SearchResults(
            initial: (try? SessionSearchResult.evaluate(request)) ?? .init(),
            evaluate: { try SessionSearchResult.evaluate($0) }))
    }

    private var searchRequest: SessionSearchRequest {
        .init(sessions: store.snapshot?.sessions ?? [], source: store.sourceFilter, query: search, model: model, sort: sort)
    }
    private var sessions: [UsageSession] { results.value.sessions }

    var body: some View {
        VStack(spacing: 0) {
            sessionHeader
            if sessions.isEmpty {
                EmptyUsageView(title: search.isEmpty && model.isEmpty ? L10n.text("Пока нет сессий") : L10n.text("Ничего не найдено"),
                               message: L10n.text("Выберите другой день или измените фильтры."))
                    .frame(maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    Table(sessions, selection: $store.selectedSessionID) {
                        TableColumn(L10n.text("Сессия")) { session in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.modelLabel).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                HStack(spacing: 5) {
                                    if geometry.size.width < 620 {
                                        Circle().fill(UsageSource.color(session.sourceID)).frame(width: 5, height: 5)
                                        Text(session.sourceLabel).font(.system(size: 10))
                                    }
                                    if geometry.size.width < 500 {
                                        Text(L10n.text("· \(UsageFormat.tokens(session.usage.total)) токенов")).font(.system(size: 10))
                                    } else {
                                        Text(session.shortID).font(.system(size: 10, design: .monospaced))
                                    }
                                }.foregroundStyle(.secondary)
                            }.padding(.vertical, 3).help(session.rawID)
                        }.width(min: 130, ideal: geometry.size.width < 500 ? 150 : 220, max: .infinity)
                        TableColumn(L10n.text("Стоимость")) { Text(UsageFormat.cost($0.usage)).fontWeight(.medium).monospacedDigit() }.width(min: 76, ideal: 90)
                        if geometry.size.width >= 500 {
                            TableColumn(L10n.text("Токены")) { Text(UsageFormat.tokens($0.usage.total)).monospacedDigit() }.width(min: 65, ideal: 85)
                        }
                        if geometry.size.width >= 620 {
                            TableColumn(L10n.text("Источник")) { SourceBadge(source: $0.sourceID) }.width(min: 85, ideal: 110)
                        }
                        if geometry.size.width >= 740 {
                            TableColumn(L10n.text("Активность")) { session in
                                Text(activityLabel(session)).foregroundStyle(.secondary).lineLimit(1)
                                    .help(UsageFormat.activity(session, timezone: store.timezone))
                            }.width(min: 75, ideal: 100)
                        }
                    }
                    .tableStyle(.inset).alternatingRowBackgrounds(.disabled)
                    .scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let id = ids.first {
                            Button(L10n.text("Подробности"), systemImage: "sidebar.right") { store.selectedSessionID = id }
                            Button(L10n.text("Скопировать ID"), systemImage: "doc.on.doc") {
                                let rawID = sessions.first { $0.id == id }?.rawID ?? id
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rawID, forType: .string)
                            }
                        }
                    }
                }
            }
            HStack {
                Text(L10n.text("Сессии: \(sessions.count)"))
                Spacer()
                Text(UsageFormat.cost(results.value.total))
            }.font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 22).padding(.vertical, 12)
        }
        .task(id: searchRequest) {
            await results.update(searchRequest, delay: search.isEmpty ? .zero : .milliseconds(120))
        }
        .background {
            Button(L10n.text("Найти сессию")) { searchFocusRequest += 1 }
                .keyboardShortcut("f").hidden().accessibilityHidden(true)
        }
        .onChange(of: store.sourceFilter) { _, _ in model = "" }
        .onChange(of: store.selectedModels) { _, models in
            if !model.isEmpty && !models.contains(model) { model = "" }
        }
        .onChange(of: sessions.map(\.id)) { _, visibleIDs in
            guard results.completedInput == searchRequest else { return }
            if let selected = store.selectedSessionID, store.selectedSession != nil, !visibleIDs.contains(selected) {
                store.selectedSessionID = nil
            }
        }
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(UsageFormat.cost(results.value.total))
                    .font(.system(size: 36, weight: .semibold)).tracking(-1).lineLimit(1).minimumScaleFactor(0.6)
                Text(L10n.text("Сессии: \(sessions.count) · \(search.isEmpty && model.isEmpty ? L10n.text("За период") : L10n.text("Найдено"))"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                SessionSearchField(text: $search, focusRequest: searchFocusRequest)
                    .frame(minWidth: 100, maxWidth: .infinity).frame(height: 32)
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 12) {
                        Menu {
                            Picker(L10n.text("Модель"), selection: $model) {
                                Text(L10n.text("Все модели")).tag("")
                                ForEach(store.selectedModels, id: \.self) { Text($0).tag($0) }
                            }
                            Picker(L10n.text("Сортировка"), selection: $sort) {
                                ForEach(SessionSort.allCases) { Text($0.title).tag($0) }
                            }
                        } label: { Image(systemName: model.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }
                            .help(L10n.text("Фильтры и сортировка сессий")).accessibilityLabel(L10n.text("Фильтры сессий"))
                            .glassEffectID("filter", in: filterEffects)
                        if !model.isEmpty {
                            Button { withAnimation(reduceMotion ? nil : .smooth) { model = "" } } label: {
                                Image(systemName: "xmark")
                            }.help(L10n.text("Сбросить фильтр модели")).accessibilityLabel(L10n.text("Сбросить фильтр модели"))
                                .glassEffectID("reset", in: filterEffects)
                        }
                    }.buttonStyle(.glass).controlSize(.large)
                }
            }
            if !model.isEmpty {
                Text(model).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 18)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model)
    }

    private func activityLabel(_ session: UsageSession) -> String {
        guard let date = session.lastActivity else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = TimeZone(identifier: store.timezone)
        formatter.setLocalizedDateFormatFromTemplate(session.activityHasTime ? "j:mm" : "d MMM")
        return formatter.string(from: date)
    }
}

/// A native search field scoped to the table column, so it can never extend across the inspector.
struct SessionSearchField: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    var placeholder = L10n.text("Модель, проект или сессия")

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.controlSize = .large
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            field.window?.makeFirstResponder(field)
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var lastFocusRequest = 0
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

private struct SessionChatSelection: Identifiable {
    var id = UUID()
    var session: UsageSession
    var day: UsageDay
    var policy: ModelExclusionPolicy
    var customPath: String
    var pricingKey: String?
}

/// An inspector keeps the selected session's context visible in the dashboard/table.
struct SessionDetailView: View {
    @ObservedObject var store: UsageStore
    var sessionID: String
    @State private var copied = false
    @State private var showMetadata = false
    @State private var chatSession: SessionChatSelection?

    init(store: UsageStore, sessionID: String, initiallyExpandedMetadata: Bool = false) {
        self.store = store
        self.sessionID = sessionID
        _showMetadata = State(initialValue: initiallyExpandedMetadata)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text(L10n.text("Подробности сессии")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.selectedSessionID = nil } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)) }
                        .buttonStyle(.glass).buttonBorderShape(.circle).help(L10n.text("Закрыть подробности")).accessibilityLabel(L10n.text("Закрыть подробности"))
                }
                if let session = store.selectedSession {
                    VStack(alignment: .leading, spacing: 9) {
                        SourceBadge(source: session.sourceID)
                        Text(session.modelLabel).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
                    }
                    Button {
                        chatSession = .init(session: session, day: store.snapshot?.day ?? store.selectedDay,
                                            policy: store.modelExclusionPolicy, customPath: store.customPath, pricingKey: store.snapshot?.pricingKey)
                    } label: {
                        Label(L10n.text("Просмотреть чат"), systemImage: "text.bubble")
                            .font(.system(size: 12, weight: .medium))
                    }.buttonStyle(.bordered).controlSize(.regular).fixedSize()
                        .help(L10n.text("Сообщения, ответы и действия в этой сессии"))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(UsageFormat.cost(session.usage)).font(.system(size: 44, weight: .semibold)).tracking(-1.5)
                        Text(L10n.text("\(UsageFormat.tokens(session.usage.total)) токенов")).font(.callout).foregroundStyle(.secondary)
                    }
                    if session.usage.costIsIncomplete == true {
                        Label(L10n.text("Стоимость неполная: часть данных недоступна."), systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    TokenUsageDetails(usage: session.usage)
                    Divider()
                    DisclosureGroup(L10n.text("Дополнительная информация"), isExpanded: $showMetadata) {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text("ID").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if copied { Text(L10n.text("Скопировано")).font(.caption).foregroundStyle(.secondary) }
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(session.rawID, forType: .string)
                                        copied = true
                                    } label: {
                                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                            .font(.system(size: 11)).frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.borderless)
                                    .help(L10n.text("Скопировать полный ID"))
                                    .accessibilityLabel(L10n.text("Скопировать полный ID"))
                                    .accessibilityValue(copied ? L10n.text("Скопировано") : "")
                                }
                                Text(session.rawID).font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            metadata(L10n.text("Последняя активность"), value: UsageFormat.activity(session, timezone: store.timezone) + " · " + store.timezone)
                            if let path = session.projectPath, !path.isEmpty { metadata(L10n.text("Проект"), value: path) }
                            if let reasoning = session.reasoningOutputTokens, reasoning > 0, session.usage.reportedAmounts == nil {
                                metadata("Reasoning", value: L10n.text("\(UsageFormat.exact(reasoning)) токенов — уже включены в Output."))
                            }
                            if (session.usage.additional ?? 0) > 0 {
                                Text(L10n.text("Other tokens входят в общую сумму и не относятся к четырём основным категориям."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.top, 12)
                    }.font(.system(size: 12)).disclosureGroupStyle(WholeRowDisclosureStyle())
                } else if store.isRefreshing {
                    ProgressView(L10n.text("Загружаем сессию…")).frame(maxWidth: .infinity).padding(.vertical, 30)
                } else {
                    Text(L10n.text("Сессия недоступна за выбранный день. Выберите другую дату."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(22)
        }
        .onChange(of: sessionID) { _, _ in copied = false; showMetadata = false }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = false } catch { }
        }
        .sheet(item: $chatSession) { selection in
            SessionChatView(session: selection.session, timezone: selection.day.timezone, isDemo: store.isDemo,
                            day: selection.day, policy: selection.policy,
                            customPath: selection.customPath, pricingKey: selection.pricingKey)
        }
    }

    private func metadata(_ title: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
