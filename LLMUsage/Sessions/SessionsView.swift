import SwiftUI

/// Both list sizes use the original overview rows and share search and the inspector.
struct DashboardSessionsSection: View {
    static let expansionAnimation = Animation.easeInOut(duration: 0.22)

    @ObservedObject var store: UsageStore
    private let scrollToSession: (String) -> Void
    private let revealSearch: () -> Void
    @StateObject private var results: SearchResults<SessionSearchRequest, SessionSearchResult>
    @State private var searchFocusRequest = 0
    @State private var pendingSessionID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct ScrollSelection: Equatable {
        var id: String?
        var navigationID: UUID
    }

    init(store: UsageStore, scrollToSession: @escaping (String) -> Void = { _ in },
         revealSearch: @escaping () -> Void = {}) {
        self.store = store
        self.scrollToSession = scrollToSession
        self.revealSearch = revealSearch
        let state = store.sessionList
        let request = SessionSearchRequest(sessions: store.snapshot?.sessions ?? [], source: store.sourceFilter,
                                           query: state.query, model: state.model, sort: state.sort)
        _results = StateObject(wrappedValue: SearchResults(
            initial: (try? SessionSearchResult.evaluate(request)) ?? .init(), input: request,
            evaluate: { try SessionSearchResult.evaluate($0) }))
    }

    private var searchRequest: SessionSearchRequest {
        .init(sessions: store.snapshot?.sessions ?? [], source: store.sourceFilter,
              query: store.sessionList.query, model: store.sessionList.model, sort: store.sessionList.sort)
    }
    private var sessions: [UsageSession] { results.value.sessions }
    private var isCurrent: Bool { results.completedInput == searchRequest }
    private var isExpanded: Bool { store.sessionList.isExpanded }
    private var sort: SessionSort { store.sessionList.sort }
    private var visibleSessions: [UsageSession] { isExpanded ? sessions : Array(sessions.prefix(SessionSort.compactLimit)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader.padding(.bottom, 12)
            searchControls
                .frame(height: isExpanded ? 32 : 0, alignment: .top)
                .opacity(isExpanded ? 1 : 0).clipped()
                .allowsHitTesting(isExpanded).accessibilityHidden(!isExpanded)
                .padding(.bottom, isExpanded ? 12 : 0)
            DashboardSection {
                Group {
                    if sessions.isEmpty {
                        EmptyUsageView(title: store.sessionList.query.isEmpty && store.sessionList.model.isEmpty
                                       ? L10n.text("Пока нет сессий") : L10n.text("Ничего не найдено"),
                                       message: L10n.text("Выберите другой день или измените фильтры."))
                            .frame(height: 190)
                    } else {
                        sessionRows
                    }
                }
                .disabled(!isCurrent).opacity(isCurrent ? 1 : 0.5)
                Divider().padding(.horizontal, 18)
                sectionFooter
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .task(id: searchRequest) {
            await results.update(searchRequest, delay: store.sessionList.query.isEmpty ? .zero : .milliseconds(120))
        }
        .background {
            Button(L10n.text("Найти сессию")) {
                withAnimation(reduceMotion ? nil : Self.expansionAnimation, completionCriteria: .removed) {
                    store.sessionList.setExpanded(true)
                } completion: {
                    guard store.sessionList.isExpanded else { return }
                    revealSearch()
                    searchFocusRequest += 1
                }
            }.keyboardShortcut("f").hidden().accessibilityHidden(true)
        }
        .onChange(of: store.sourceFilter) { _, _ in store.sessionList.model = "" }
        .onChange(of: store.selectedModels) { _, models in
            if !store.sessionList.model.isEmpty && !models.contains(store.sessionList.model) {
                store.sessionList.model = ""
            }
        }
        .onChange(of: results.completedInput) { _, completed in
            guard completed == searchRequest, let selected = store.selectedSession else { return }
            if !sessions.contains(where: { $0.id == selected.id }) { store.selectedSessionID = nil }
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(isExpanded ? L10n.text("Все сессии") : sort.heading)
                .font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            Menu {
                Picker(L10n.text("Сортировка"), selection: $store.sessionList.sort) {
                    ForEach(isExpanded ? SessionSort.allCases : SessionSort.compactCases) { order in
                        Text(order.metricTitle + " · " + order.orderDescription).tag(order)
                    }
                }
            } label: {
                Label(sort.metricTitle, systemImage: "arrow.down").font(.system(size: 12)).fixedSize()
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L10n.text("Сортировка: \(sort.metricTitle) · \(sort.orderDescription)"))
            .accessibilityLabel(L10n.text("Сортировка"))
            .accessibilityValue(sort.metricTitle + ", " + sort.orderDescription)
        }.padding(.horizontal, 18)
    }

    private var searchControls: some View {
        HStack(spacing: 10) {
            SessionSearchField(text: $store.sessionList.query, focusRequest: searchFocusRequest, isActive: isExpanded)
                .frame(minWidth: 100, maxWidth: .infinity).frame(height: 32)
            Menu {
                Picker(L10n.text("Модель"), selection: $store.sessionList.model) {
                    Text(L10n.text("Все модели")).tag("")
                    ForEach(store.selectedModels, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                Label(store.sessionList.model.isEmpty ? L10n.text("Все модели") : store.sessionList.model,
                      systemImage: "line.3.horizontal.decrease")
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: 180)
            .help(store.sessionList.model.isEmpty ? L10n.text("Все модели") : store.sessionList.model)
            .accessibilityLabel(L10n.text("Фильтры сессий"))
            .accessibilityValue(store.sessionList.model.isEmpty ? L10n.text("Все модели") : store.sessionList.model)
            if !store.sessionList.model.isEmpty {
                Button { store.sessionList.model = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L10n.text("Сбросить фильтр модели"))
                    .accessibilityLabel(L10n.text("Сбросить фильтр модели"))
            }
        }
    }

    /// Rows grow with their content; the dashboard owns the only scrolling viewport.
    private var sessionRows: some View {
        LazyVStack(spacing: 0) {
            ForEach(visibleSessions) { session in
                VStack(spacing: 0) {
                    if session.id != sessions.first?.id { rowDivider }
                    sessionRow(session)
                }.id(session.id)
            }
        }
        .onChange(of: ScrollSelection(id: store.selectedSessionID, navigationID: store.sessionNavigationID), initial: true) { _, selection in
            pendingSessionID = selection.id
            _ = revealPendingSession()
        }
        .onChange(of: results.completedInput) { old, new in
            guard isExpanded, isCurrent, !revealPendingSession() else { return }
            if old?.query != new?.query || old?.model != new?.model || old?.sort != new?.sort || old?.source != new?.source {
                revealSearch()
            }
        }
    }

    private func revealPendingSession() -> Bool {
        guard isExpanded, isCurrent, let pendingSessionID,
              let session = sessions.first(where: {
                  $0.id == pendingSessionID || ($0.sourceID == "claude" && $0.rawID == pendingSessionID)
              }) else { return false }
        scrollToSession(session.id)
        self.pendingSessionID = nil
        return true
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 60).padding(.trailing, 18)
    }

    private func sessionRow(_ session: UsageSession) -> some View {
        SessionSummaryRow(session: session, timezone: store.timezone,
                          selected: store.selectedSessionID == session.id) {
            store.selectedSessionID = session.id
        }
        .contextMenu {
            Button(L10n.text("Скопировать ID"), systemImage: "doc.on.doc") { copyID(session.rawID) }
        }
    }

    private var sectionFooter: some View {
        HStack(spacing: 12) {
            if isCurrent {
                if isExpanded {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Сессии: \(sessions.count)"))
                        Text(L10n.text("Итого: \(UsageFormat.cost(results.value.total))"))
                    }
                } else {
                    Text(L10n.text("Показано \(visibleSessions.count) из \(sessions.count)"))
                }
            } else {
                ProgressView().controlSize(.mini)
                Text(L10n.text("Поиск…"))
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(reduceMotion ? nil : Self.expansionAnimation) {
                    store.sessionList.setExpanded(!isExpanded)
                }
            } label: {
                Label(isExpanded ? L10n.text("Свернуть список") : L10n.text("Все сессии"),
                      systemImage: isExpanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless).font(.system(size: 12))
            .accessibilityValue(isExpanded ? L10n.text("Развёрнуто") : L10n.text("Свёрнуто"))
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .frame(height: 29)
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func copyID(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

}

/// A native search field scoped to the session section, so it can never extend across the inspector.
struct SessionSearchField: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    var isActive = true
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
        field.isEnabled = isActive
        if !isActive, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        if field.stringValue != text { field.stringValue = text }
        if isActive, context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
            }
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

/// Identity and the chat action share a row; the two headline metrics share a baseline.
struct SessionInspectorSummary: View {
    var session: UsageSession
    var openChat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                ProviderLogos(models: session.models + session.modelBreakdowns.map(\.id))
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.modelLabel).font(.system(size: 15, weight: .semibold))
                        .lineLimit(2).textSelection(.enabled).help(session.modelLabel)
                    SourceBadge(source: session.sourceID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: openChat) {
                    Label(L10n.text("Чат"), systemImage: "text.bubble")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
                .help(L10n.text("Сообщения, ответы и действия в этой сессии"))
                .accessibilityLabel(L10n.text("Просмотреть чат"))
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(UsageFormat.cost(session.usage))
                        .font(.system(size: 32, weight: .semibold)).tracking(-0.8)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                        .help(UsageFormat.cost(session.usage))
                    Text(L10n.text("Стоимость")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("Стоимость"))
                .accessibilityValue(UsageFormat.cost(session.usage))
                VStack(alignment: .trailing, spacing: 5) {
                    Text(UsageFormat.tokens(session.usage.total))
                        .font(.system(size: 24, weight: .medium)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.65)
                        .help(UsageFormat.exact(session.usage.total))
                    Text(L10n.text("Токены")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("Токены"))
                .accessibilityValue(UsageFormat.exact(session.usage.total))
            }
        }
    }
}

/// An inspector keeps the selected session's context visible in the dashboard.
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
                    SessionInspectorSummary(session: session) {
                        openChat(session)
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
        #if MANUAL_REVIEW
        .task(id: store.reviewChatRevision) {
            if store.reviewChatPresented, let session = store.selectedSession { openChat(session) }
            else { chatSession = nil }
        }
        #endif
        .sheet(item: $chatSession) { selection in
            SessionChatView(session: selection.session, timezone: selection.day.timezone, isDemo: store.isDemo,
                            day: selection.day, policy: selection.policy,
                            customPath: selection.customPath, pricingKey: selection.pricingKey)
        }
    }

    private func openChat(_ session: UsageSession) {
        chatSession = .init(session: session, day: store.snapshot?.day ?? store.selectedDay,
                            policy: store.modelExclusionPolicy, customPath: store.customPath, pricingKey: store.snapshot?.pricingKey)
    }

    private func metadata(_ title: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
