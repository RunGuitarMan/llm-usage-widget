import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class TranscriptReaderModel: ObservableObject {
    @Published var transcript: SessionTranscript?
    @Published var isLoading = false
    @Published var error: String?
    @Published var pricingError: String?
    private var request = UUID()

    init(transcript: SessionTranscript? = nil) { self.transcript = transcript }

    func load(_ session: UsageSession, file: URL? = nil, customPath: String = "", pricingKey: String? = nil, services: TranscriptServices = .live) async {
        let token = UUID()
        request = token
        isLoading = true
        error = nil
        pricingError = nil
        defer { if request == token { isLoading = false } }
        do {
            let result = try await services.load(session, file)
            guard request == token, !Task.isCancelled else { return }
            transcript = result
            do {
                let priced = try await services.price(result, session.sourceID, customPath, pricingKey)
                guard request == token, !Task.isCancelled else { return }
                transcript = priced
            } catch is CancellationError { }
            catch { if request == token { pricingError = error.localizedDescription } }
        } catch is CancellationError { }
        catch { if request == token { self.error = error.localizedDescription } }
    }
}

private struct TranscriptReading: Identifiable {
    var id = UUID()
    var title: String
    var text: String
    var monospaced = false
}

struct SessionChatView: View {
    var session: UsageSession
    var timezone: String
    var isDemo = false
    var day: UsageDay?
    var policy: ModelExclusionPolicy
    var customPath: String
    var pricingKey: String?
    var telemetry: ClaudeTelemetryCoordinator?
    @StateObject private var reader: TranscriptReaderModel
    @StateObject private var results: SearchResults<TranscriptSearchRequest, TranscriptSearchResult>
    @Environment(\.transcriptServices) private var transcriptServices
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var searchFocusRequest = 0
    @State private var showContext = false
    @State private var reading: TranscriptReading?
    @State private var reload = 0
    @State private var selectedFile: URL?
    @State private var showInfo = false
    @State private var expandedTools: Set<String> = []
    @State private var scope: TranscriptScope = .session
    @State private var view: TranscriptAnalysisTab = .chat
    @State private var jumpID: String?
    @State private var filter = TranscriptEventFilter.all
    @State private var scrollTarget: String?
    @State private var timelinePosition: String?

    init(session: UsageSession, timezone: String, isDemo: Bool = false, preview: SessionTranscript? = nil,
         day: UsageDay? = nil, policy: ModelExclusionPolicy = .init(), customPath: String = "", pricingKey: String? = nil,
         initialTab: TranscriptAnalysisTab = .chat, initialFilter: TranscriptEventFilter = .all,
         initiallyExpandedTools: Set<String> = [], telemetry: ClaudeTelemetryCoordinator? = nil) {
        self.telemetry = telemetry
        self.session = session
        self.timezone = timezone
        self.isDemo = isDemo
        self.day = day; self.policy = policy; self.customPath = customPath; self.pricingKey = pricingKey
        _scope = State(initialValue: day == nil ? .session : .day)
        _view = State(initialValue: initialTab)
        _filter = State(initialValue: initialFilter)
        _expandedTools = State(initialValue: initiallyExpandedTools)
        let initial = preview ?? (isDemo ? TranscriptPreview.sample : nil)
        _reader = StateObject(wrappedValue: TranscriptReaderModel(transcript: initial))
        _results = StateObject(wrappedValue: SearchResults(
            initial: (try? TranscriptSearchResult.evaluate(.init(transcript: initial, day: day, policy: policy, filter: initialFilter))) ?? .init(),
            evaluate: { try TranscriptSearchResult.evaluate($0) }))
    }

    private var searchRequest: TranscriptSearchRequest {
        .init(transcript: reader.transcript, query: search, showContext: showContext, day: scope == .day ? day : nil,
              policy: policy, filter: view == .chat ? filter : .all)
    }
    private var rows: [TranscriptRow] { results.value.rows }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if let telemetry, session.sourceID == "claude" {
                ClaudeSessionTelemetryView(coordinator: telemetry, session: session, transcript: reader.transcript,
                    day: scope == .day ? day : nil, timezone: timezone, pricingKey: pricingKey, navigate: navigate)
            }
            searchToolbar
            Divider().opacity(0.4)
            if let transcript = reader.transcript {
                if view == .chat { timeline }
                else if let analysis = results.value.analysis {
                    TranscriptAnalysisView(tab: view, transcript: transcript, summary: analysis, query: search, policy: policy) { id in
                        navigate(to: id)
                    }
                }
            }
            else if reader.isLoading {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Открываем историю…")).font(.system(size: 13)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { unavailable }
            Divider().opacity(0.6)
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 680, idealWidth: 900, maxWidth: .infinity, minHeight: 520, idealHeight: 740, maxHeight: .infinity)
        .onAppear {
            guard let kind = ManualReviewController.active?.chatKind else { return }
            view = kind == "expensive" ? .expensive : kind == "analytics" ? .tools : .chat
            filter = ["errors", "service-errors"].contains(kind) ? .errors : kind == "tools" ? .tools : .all
            expandedTools = kind == "tools" ? ["3", "4", "7"] : []
            search = kind == "search" ? "поиск" : ""
            showInfo = kind == "info"
            scope = .session
        }
        .task(id: reload) {
            if !isDemo && (reader.transcript == nil || reload > 0) {
                await reader.load(session, file: selectedFile, customPath: customPath, pricingKey: pricingKey, services: transcriptServices)
            }
        }
        .task(id: searchRequest) {
            await results.update(searchRequest, delay: search.isEmpty ? .zero : .milliseconds(120))
        }
        .sheet(item: $reading) { detail in
            TranscriptTextSheet(title: detail.title, text: detail.text, monospaced: detail.monospaced)
        }
        .background {
            if reading == nil {
                Button(L10n.text("Поиск в чате")) { searchFocusRequest += 1 }.keyboardShortcut("f").hidden().accessibilityHidden(true)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Text(L10n.text("История чата")).font(.system(size: 17, weight: .semibold))
                        SourceBadge(source: session.sourceID)
                    }
                    HStack(spacing: 6) {
                        Text(session.projectPath.map { ($0 as NSString).lastPathComponent } ?? session.modelLabel).lineLimit(1)
                        Text("·")
                        Text(session.shortID).font(.system(size: 11, design: .monospaced))
                        if isDemo { Text(L10n.text("· Демо")) }
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { reload += 1 } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).disabled(reader.isLoading || isDemo).keyboardShortcut("r")
                    .help(L10n.text("Обновить")).accessibilityLabel(L10n.text("Обновить"))
                Menu {
                    Toggle(L10n.text("Служебные события"), isOn: $showContext)
                    Button(L10n.text("Информация о сессии"), systemImage: "info.circle") { showInfo.toggle() }
                    Divider()
                    Button(L10n.text("Скопировать историю"), systemImage: "doc.on.doc") { copyTranscript() }
                        .disabled(reader.transcript == nil)
                    Button(L10n.text("Сохранить историю…"), systemImage: "square.and.arrow.up") { export() }
                        .disabled(reader.transcript == nil)
                    Divider()
                    Button(L10n.text("Открыть файл чата…"), systemImage: "folder") { chooseFile() }
                    if selectedFile != nil {
                        Button(L10n.text("Открыть основной журнал")) { selectedFile = nil; reload += 1 }
                    }
                    if let files = reader.transcript?.relatedFiles, !files.isEmpty {
                        Menu(L10n.text("Другие журналы")) {
                            ForEach(files, id: \.path) { file in
                                Button(file.deletingLastPathComponent().lastPathComponent + " / " + file.lastPathComponent) {
                                    selectedFile = file; reload += 1
                                }
                            }
                        }
                    }
                    if let file = reader.transcript?.files.first {
                        Button(L10n.text("Показать журнал в Finder"), systemImage: "doc.text.magnifyingglass") {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 20) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.text("Действия с историей")).accessibilityLabel(L10n.text("Действия с историей"))
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 20, height: 20) }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                    .help(L10n.text("Закрыть чат · Esc")).accessibilityLabel(L10n.text("Закрыть чат"))
            }
            if let transcript = reader.transcript {
                HStack(spacing: 12) {
                    Picker(L10n.text("Раздел чата"), selection: $view) {
                        ForEach(TranscriptAnalysisTab.allCases) { tab in Text(tab.title).tag(tab) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340)
                    Spacer(minLength: 8)
                    if day != nil {
                        Picker(L10n.text("Период"), selection: $scope) {
                            ForEach(TranscriptScope.allCases) { scope in Text(scope.title).tag(scope) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 235)
                    }
                }
                if let summary = results.value.analysis {
                    TranscriptMetricsView(summary: summary, transcript: transcript, expected: scope == .day ? session.usage.reported : nil,
                                          isLoading: reader.isLoading, error: reader.pricingError)
                }
            }
            if showInfo {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.rawID).font(.system(size: 11, design: .monospaced))
                    Text(session.modelLabel)
                    if let path = session.projectPath { Text(path) }
                    Text(L10n.text("Часовой пояс: \(timezone)"))
                    if let file = reader.transcript?.files.first { Text(file.path) }
                }.font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 14)
    }

    private var searchToolbar: some View {
        HStack(spacing: 12) {
            SessionSearchField(text: $search, focusRequest: searchFocusRequest, placeholder: L10n.text("Найти в сообщениях и действиях"))
                .frame(maxWidth: .infinity).frame(height: 28)
            if view == .chat {
                if filter != .all { Text(filter.title).font(.system(size: 11)).foregroundStyle(.secondary) }
                Menu {
                    Picker(L10n.text("События"), selection: $filter) {
                        ForEach(TranscriptEventFilter.allCases) { value in Text(value.title).tag(value) }
                    }
                    Divider()
                    Toggle(L10n.text("Служебные события"), isOn: $showContext)
                } label: {
                    Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(filter == .all ? Color.secondary : Color.accentColor).frame(width: 24, height: 24)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L10n.text("Фильтр событий")).accessibilityLabel(L10n.text("Фильтр событий"))
                let tools = Set(rows.flatMap(\.events).filter { $0.kind == .tool }.map(\.id))
                let expanded = !tools.isEmpty && tools.isSubset(of: expandedTools)
                Button {
                    if expanded { expandedTools.subtract(tools) } else { expandedTools.formUnion(tools) }
                } label: { Image(systemName: expanded ? "chevron.up.chevron.down" : "chevron.down.2").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).disabled(tools.isEmpty)
                    .help(expanded ? L10n.text("Свернуть инструменты") : L10n.text("Развернуть инструменты"))
                    .accessibilityLabel(expanded ? L10n.text("Свернуть инструменты") : L10n.text("Развернуть инструменты"))
            }
        }.padding(.horizontal, 24).padding(.vertical, 8)
    }

    private func navigate(to id: String) {
        search = ""; filter = .all; view = .chat; jumpID = id
        if reader.transcript?.events.first(where: { $0.id == id })?.kind == .tool { expandedTools.insert(id) }
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        Color.clear.frame(height: 1).id("chat-start")
                        if let error = reader.error { notice(error) }
                        if let notices = reader.transcript?.notices, !notices.isEmpty {
                            DisclosureGroup {
                                ForEach(notices, id: \.self) { Text($0).padding(.top, 4) }
                            } label: { Label(L10n.text("О доступности истории"), systemImage: "info.circle") }
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if rows.isEmpty {
                            EmptyUsageView(title: !search.isEmpty ? L10n.text("Совпадений нет")
                                : filter == .errors ? L10n.text("Ошибок не найдено")
                                : filter == .tools ? L10n.text("Вызовов не найдено") : L10n.text("Нет сообщений для показа"),
                                message: !search.isEmpty ? L10n.text("Попробуйте другое слово или часть команды.")
                                : filter == .all ? L10n.text("Откройте служебные события в меню, чтобы изучить доступные записи.") : "",
                                symbol: filter == .errors && search.isEmpty ? "checkmark.circle" : "magnifyingglass")
                        }
                        ForEach(rows) { row in
                            if row.isContext {
                                contextGroup(row.events)
                            } else if let event = row.events.first {
                                Group {
                                    if let service = event.service {
                                        TranscriptServiceRow(event: event, service: service, timestamp: event.timestamp.map(time),
                                                             query: search, copy: copy) { title, text, monospaced in
                                            reading = .init(title: title, text: text, monospaced: monospaced)
                                        }
                                    } else if event.kind == .tool { toolRow(event) }
                                    else { messageRow(event) }
                                }.id(event.id)
                            }
                        }
                        if search.isEmpty, filter == .all, let transcript = reader.transcript, !showContext {
                            let count = transcript.events.filter(\.isHiddenContext).count
                            if count > 0 {
                                Button { showContext = true } label: {
                                    Label(L10n.text("Показать служебные события (\(count))"), systemImage: "text.alignleft")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }.buttonStyle(.plain).padding(.top, 6)
                            }
                        }
                        Color.clear.frame(height: 22).id("chat-end")
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                }
                .scrollPosition(id: $timelinePosition, anchor: .top)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: target == "chat-start" ? .top : .bottom)
                scrollTarget = nil
            }
            .onChange(of: search) { _, _ in proxy.scrollTo("chat-start", anchor: .top) }
            .onChange(of: filter) { _, _ in proxy.scrollTo("chat-start", anchor: .top) }
            .onChange(of: jumpID) { _, id in
                guard let id, results.completedInput == searchRequest,
                      rows.contains(where: { $0.id == id }) else { return }
                timelinePosition = id
                jumpID = nil
            }
            .task(id: results.completedInput) {
                if !search.isEmpty || filter == .errors {
                    expandedTools.formUnion(rows.flatMap(\.events).filter { $0.kind == .tool }.map(\.id))
                }
                if let jumpID, rows.contains(where: { $0.id == jumpID }) {
                    timelinePosition = jumpID
                    self.jumpID = nil
                }
            }
            .onAppear {
                if let jumpID, rows.contains(where: { $0.id == jumpID }) {
                    timelinePosition = jumpID; self.jumpID = nil
                }
            }
        }
    }

    private func messageRow(_ event: TranscriptEvent) -> some View {
        let isUser = event.kind == .user
        let preview = TranscriptTextPreview(event.text)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isUser ? "person.fill" : "sparkle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isUser ? Color.secondary : UsageSource.color(session.sourceID))
                    .frame(width: 16, height: 16)
                Text(event.isUsageOnly ? L10n.text("Обращение к модели") : isUser ? L10n.text("Вы") : session.sourceLabel).font(.system(size: 12, weight: .semibold))
                if !isUser, let model = event.model ?? event.requestIDs.compactMap({ results.value.requestsByID[$0]?.model }).first {
                    Text(model).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(model)
                }
                if let origin = event.origin { Text(origin).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(origin) }
                Spacer()
                if let date = event.timestamp { Text(time(date)).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize() }
                Menu {
                    Button(L10n.text("Скопировать сообщение"), systemImage: "doc.on.doc") { copy(event.text) }
                    Button(L10n.text("Прочитать полностью"), systemImage: "arrow.up.left.and.arrow.down.right") {
                        reading = .init(title: event.title, text: event.text)
                    }
                    Button(L10n.text("Исходная запись"), systemImage: "curlybraces") {
                        reading = .init(title: L10n.text("Исходная запись"), text: event.raw, monospaced: true)
                    }
                } label: { Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(.tertiary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.text("Действия с сообщением")).accessibilityLabel(L10n.text("Действия с сообщением"))
            }
            TranscriptMessageText(text: preview.text)
            if preview.isTruncated {
                Button(L10n.text("Читать полностью · \(UsageFormat.exact(Int64(event.text.count))) знаков")) {
                    reading = .init(title: event.title, text: event.text)
                }.buttonStyle(.link).font(.system(size: 11))
            }
            if !search.isEmpty && !preview.text.localizedCaseInsensitiveContains(search) {
                Button(L10n.text("Совпадение в полном содержимом")) {
                    reading = .init(title: event.title, text: event.searchableText, monospaced: true)
                }.buttonStyle(.link).font(.system(size: 11))
            }
            usageLine(event)
            TranscriptTimingBadge(timing: event.timing, kind: isUser ? .processing : .message, timezone: timezone)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isUser ? Color.primary.opacity(0.025) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if isUser { RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.16)).frame(width: 2).padding(.vertical, 12) }
        }
    }

    @ViewBuilder private func usageLine(_ event: TranscriptEvent) -> some View {
        if let transcript = reader.transcript {
            if event.kind == .user {
                TranscriptUserUsageBadge(requests: results.value.requestsByUserID[event.id] ?? [],
                                         supported: transcript.usageSupported, policy: policy, jump: navigate)
            } else {
                TranscriptUsageBadge(event: event, requests: event.requestIDs.compactMap { results.value.requestsByID[$0] },
                                     supported: transcript.usageSupported, policy: policy, jump: navigate)
            }
        }
    }

    private func toolRow(_ event: TranscriptEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
        DisclosureGroup(isExpanded: Binding(get: { expandedTools.contains(event.id) }, set: {
            if $0 { expandedTools.insert(event.id) } else { expandedTools.remove(event.id) }
        })) {
            TranscriptToolInspector(event: event, query: search, copy: copy) { title, text in
                reading = .init(title: title, text: text, monospaced: true)
            }.id(search).padding(.top, 12)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: event.isError ? "exclamationmark.circle" : "terminal")
                    .foregroundStyle(event.isError ? Color.orange : Color.secondary)
                Text(event.title).fontWeight(.medium).lineLimit(1)
                if let summary = event.toolSummary {
                    Text(summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if event.isError { Text(L10n.text("Ошибка")).foregroundStyle(.orange) }
                else if event.hasResult { Image(systemName: "checkmark.circle").foregroundStyle(.green).help(L10n.text("Результат получен")) }
                else { Image(systemName: "circle.dotted").foregroundStyle(.secondary).help(L10n.text("Результат не записан в журнале.")) }
                Spacer(minLength: 4)
                if let date = event.timestamp { Text(time(date)).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize() }
            }.font(.system(size: 12))
        }
        .disclosureGroupStyle(WholeRowDisclosureStyle())
        if let origin = event.origin { Text(origin).font(.system(size: 10)).foregroundStyle(.secondary) }
        usageLine(event)
        TranscriptTimingBadge(timing: event.timing, kind: .tool, timezone: timezone)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(event.isError ? Color.orange.opacity(0.5) : UsageStyle.stroke))
    }

    private func contextGroup(_ events: [TranscriptEvent]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(events) { event in
                    Button {
                        reading = .init(title: event.title, text: event.raw, monospaced: true)
                    } label: {
                        HStack {
                            Text(event.title)
                            if let date = event.timestamp { Text(time(date)).foregroundStyle(.tertiary) }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }.font(.system(size: 11)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if let timing = event.timing {
                        TranscriptTimingBadge(timing: timing, kind: .service, timezone: timezone)
                    }
                }
            }.padding(.top, 12)
        } label: {
            Label(L10n.text("Служебные события · \(events.count)"), systemImage: "text.alignleft")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.disclosureGroupStyle(WholeRowDisclosureStyle()).padding(.vertical, 3)
    }

    private var unavailable: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(.tertiary)
            VStack(spacing: 10) {
                Text(L10n.text("История пока недоступна")).font(.system(size: 19, weight: .semibold))
                Text(reader.error ?? L10n.text("Выберите сохранённый файл чата."))
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 420)
            }
            Button(L10n.text("Открыть файл чата…"), systemImage: "folder") { chooseFile() }
                .buttonStyle(.bordered).controlSize(.large)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            let visible = rows.flatMap(\.events)
            let messages = visible.filter { $0.isMessage && !$0.isUsageOnly }.count
            let actions = visible.filter { $0.kind == .tool && !$0.isToolResultOnly }.count
            let services = visible.filter { $0.service != nil }.count
            Text(search.isEmpty
                 ? (messages == 0 && actions == 0 && services > 0 ? L10n.text("Событий: \(services)")
                    : "\(L10n.count(messages, .messages)) · \(L10n.count(actions, .actions))")
                 : L10n.text("Найдено: \(results.value.eventCount)"))
                .font(.system(size: 10))
            Spacer()
            if reader.isLoading || results.isSearching { ProgressView().controlSize(.mini) }
            if let file = reader.transcript?.files.first {
                Text(file.lastPathComponent).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(file.path)
            }
            HStack(spacing: 4) {
                Button { scrollTarget = "chat-start" } label: { Image(systemName: "arrow.up").frame(width: 24, height: 18) }
                    .help(L10n.text("В начало чата")).accessibilityLabel(L10n.text("В начало чата"))
                Button { scrollTarget = "chat-end" } label: { Image(systemName: "arrow.down").frame(width: 24, height: 18) }
                    .help(L10n.text("К последнему сообщению")).accessibilityLabel(L10n.text("К последнему сообщению"))
            }.buttonStyle(.borderless).disabled(view != .chat || rows.isEmpty)
        }.foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 8)
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
    }
    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = TimeZone(identifier: timezone)
        formatter.setLocalizedDateFormatFromTemplate(scope == .day ? "j:mm:ss" : "d MMM j:mm:ss")
        return formatter.string(from: date)
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func copyTranscript() {
        guard let transcript = reader.transcript else { return }
        Task {
            let text = await Task.detached(priority: .userInitiated) { transcript.exportText }.value
            copy(text)
        }
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Открыть сохранённую историю чата")
        panel.allowedContentTypes = [.json, .plainText, UTType(filenameExtension: "jsonl") ?? .data]
        panel.prompt = L10n.key("Open")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { selectedFile = url; reload += 1 }
    }
    private func export() {
        guard let transcript = reader.transcript else { return }
        let panel = NSSavePanel()
        panel.prompt = L10n.key("Save")
        panel.nameFieldStringValue = "chat-\(session.shortID).txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try transcript.exportText.write(to: url, atomically: true, encoding: .utf8)
                    }.value
                } catch { reader.error = L10n.text("Не удалось сохранить историю: \(error.localizedDescription)") }
            }
        }
    }
}

private struct TranscriptToolInspector: View {
    enum Section: String, CaseIterable, Identifiable {
        case input, output, raw
        var id: String { rawValue }
        var title: String {
            switch self {
            case .input: return L10n.text("Аргументы")
            case .output: return L10n.text("Результат")
            case .raw: return "JSON"
            }
        }
    }
    var event: TranscriptEvent
    var copy: (String) -> Void
    var open: (String, String) -> Void
    @State private var section: Section

    init(event: TranscriptEvent, query: String, copy: @escaping (String) -> Void, open: @escaping (String, String) -> Void) {
        self.event = event; self.copy = copy; self.open = open
        let matched: Section? = query.isEmpty ? nil : event.input.localizedCaseInsensitiveContains(query) ? .input
            : event.output.localizedCaseInsensitiveContains(query) ? .output : .raw
        _section = State(initialValue: matched ?? (event.isError || event.input.isEmpty ? .output : .input))
    }
    private var content: String {
        switch section {
        case .input: return event.input
        case .output: return event.output
        case .raw: return event.raw
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 10) {
                Picker(L10n.text("Данные вызова"), selection: $section) {
                    ForEach(Section.allCases) { value in Text(value.title).tag(value) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 245)
                Spacer(minLength: 8)
                Button { copy(content) } label: { Image(systemName: "doc.on.doc").frame(width: 20, height: 20) }
                    .help(L10n.text("Скопировать: \(section.title)")).accessibilityLabel(L10n.text("Скопировать: \(section.title)"))
                Button { open(event.title + " · " + section.title, content) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 20, height: 20)
                }.help(L10n.text("Открыть полностью: \(section.title)")).accessibilityLabel(L10n.text("Открыть полностью: \(section.title)"))
            }.buttonStyle(.borderless)
            if content.isEmpty {
                Text(section == .output ? (event.hasResult ? L10n.text("Получен пустой результат.") : L10n.text("Результат не записан в журнале.")) : L10n.text("Нет данных для показа"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(String(content.prefix(2400))).font(.system(size: 11, design: .monospaced)).lineSpacing(3)
                    .textSelection(.enabled).lineLimit(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let callID = event.callID {
                HStack(spacing: 6) {
                    Text("Call ID").foregroundStyle(.secondary)
                    Text(callID).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(callID)
                    Button { copy(callID) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help(L10n.text("Скопировать Call ID")).accessibilityLabel(L10n.text("Скопировать Call ID"))
                }.font(.system(size: 10, design: .monospaced))
            }
            Divider()
        }
    }
}

/// Readable inline markdown, with code fenced into quiet, selectable panels.
/// Images and HTML are never fetched or executed from a transcript.
private struct TranscriptMessageText: View {
    var text: String
    var body: some View {
        let sections = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index % 2 == 1 {
                    Text(section.trimmingCharacters(in: .newlines)).font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                } else if !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text((try? AttributedString(markdown: section, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(section))
                        .font(.system(size: 13)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.textSelection(.enabled)
    }
}

private struct TranscriptTextSheet: View {
    var title: String
    var text: String
    var monospaced: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Spacer()
                Button(L10n.text("Скопировать"), systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                }.buttonStyle(.borderless)
                Button(L10n.text("Готово")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            TranscriptNativeText(text: text, monospaced: monospaced)
        }.frame(minWidth: 580, idealWidth: 800, minHeight: 420, idealHeight: 620)
    }
}

/// AppKit's text view virtualizes long logs and provides selection, find (⌘F),
/// and copy without constructing thousands of SwiftUI text nodes.
private struct TranscriptNativeText: NSViewRepresentable {
    var text: String
    var monospaced: Bool
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 22, height: 20)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel(L10n.text("Полное содержимое записи"))
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 14)
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
    }
}

enum TranscriptPreview {
    static var sample: SessionTranscript {
        let time = UsageDay().date.addingTimeInterval(12 * 3600 + 40 * 60)
        var transcript = SessionTranscript(events: [
            .init(id: "1", kind: .user, title: L10n.text("Вы"), text: "Добавь поиск по сессиям. Хочу быстро находить нужный разговор по проекту или названию модели.", timestamp: time, raw: "{\"role\":\"user\",\"content\":\"Добавь поиск по сессиям\"}"),
            .init(id: "2", kind: .assistant, title: L10n.text("Ответ"), text: "Посмотрю, как устроен список сессий, и добавлю поиск рядом с фильтрами. Он будет учитывать **проект, модель и ID сессии**.", timestamp: time.addingTimeInterval(8), raw: "{\"role\":\"assistant\"}"),
            .init(id: "3", kind: .tool, title: "Read", input: "{\n  \"file_path\": \"LLMUsage/Sessions/SessionsView.swift\"\n}", output: "struct SessionsView: View {\n    @ObservedObject var store: UsageStore\n    @State private var search = \"\"\n}", timestamp: time.addingTimeInterval(12), callID: "toolu_01_read_sessions", hasResult: true, raw: "{\"type\":\"tool_use\",\"name\":\"Read\"}"),
            .init(id: "4", kind: .tool, title: "Edit", input: "{\n  \"file_path\": \"LLMUsage/Sessions/SessionsView.swift\",\n  \"old_string\": \"@State private var search = \\\"\\\"\",\n  \"new_string\": \"@State private var query = \\\"\\\"\"\n}", output: "Файл обновлён.", timestamp: time.addingTimeInterval(19), callID: "toolu_02_edit_sessions", hasResult: true, raw: "{\"type\":\"tool_result\"}"),
            .init(id: "7", kind: .tool, title: "Bash", input: "{\n  \"command\": \"swift test --filter SessionSearchTests\"\n}", output: "error: no tests found; create a target in the 'Tests' directory\nExit code: 1", timestamp: time.addingTimeInterval(24), callID: "toolu_03_test_sessions", isError: true, hasResult: true, raw: "{\"type\":\"tool_result\",\"is_error\":true,\"exit_code\":1}"),
            .init(id: "5", kind: .assistant, title: L10n.text("Ответ"), text: "Готово. Поиск появился над списком сессий.\n\nМожно ввести часть названия проекта, модели или ID. Результаты обновляются сразу, а выбранная сортировка сохраняется.\n\nНажмите **⌘F**, чтобы перейти к поиску.", timestamp: time.addingTimeInterval(35), raw: "{\"role\":\"assistant\"}"),
            .init(id: "6", kind: .context, title: L10n.text("Контекст запроса"), raw: "{\"model\":\"example\",\"cwd\":\"/example/project\"}")
        ])
        transcript.usageSupported = true
        transcript.requests = [
            .init(id: "demo-request-1", model: "claude-opus-4-6", timestamp: time.addingTimeInterval(8), eventIDs: ["2", "3"],
                  billing: .init(tokens: [:]), usage: .init(input: 8400, output: 620, cacheCreate: 2300, cacheRead: 18400, cost: 0.083155), priced: true),
            .init(id: "demo-request-2", model: "claude-sonnet-4-6", timestamp: time.addingTimeInterval(19), eventIDs: ["4", "7"],
                  billing: .init(tokens: [:]), usage: .init(input: 5300, output: 920, cacheRead: 26800, cost: 0.03774), priced: true),
            .init(id: "demo-request-3", model: "claude-sonnet-4-6", timestamp: time.addingTimeInterval(35), eventIDs: ["5"],
                  billing: .init(tokens: [:]), usage: .init(input: 920, output: 430, cacheRead: 31000, cost: 0.01851), priced: true)
        ]
        for index in transcript.events.indices {
            transcript.events[index].requestIDs = transcript.requests.filter { $0.eventIDs.contains(transcript.events[index].id) }.map(\.id)
        }
        for index in transcript.requests.indices { transcript.requests[index].userEventID = "1" }
        for index in transcript.events.indices {
            switch transcript.events[index].id {
            case "1": transcript.events[index].timing = .init(kind: .processing, start: time,
                end: time.addingTimeInterval(35), duration: 35, timeToFirstToken: 2.4, outputTokens: 1970, evidence: .recorded)
            case "2": transcript.events[index].timing = .init(kind: .message, start: time.addingTimeInterval(2.4), end: time.addingTimeInterval(8))
            case "3", "4", "7": transcript.events[index].timing = .init(kind: .tool, duration: 1.35, evidence: .recorded)
            case "5": transcript.events[index].timing = .init(kind: .message, start: time.addingTimeInterval(28), end: time.addingTimeInterval(35))
            default: break
            }
        }
        return transcript
    }
}

/// Inject I/O at the boundary; TranscriptReaderModel owns the same loading and error lifecycle.
struct TranscriptServices {
    var load: @MainActor (UsageSession, URL?) async throws -> SessionTranscript
    var price: @MainActor (SessionTranscript, String, String, String?) async throws -> SessionTranscript

    static let live = Self(
        load: { try await TranscriptService().load(session: $0, file: $1) },
        price: { try await TranscriptCostService().price($0, source: $1, customPath: $2, pricingKey: $3) })
}

private struct TranscriptServicesKey: EnvironmentKey {
    static let defaultValue = TranscriptServices.live
}
extension EnvironmentValues {
    var transcriptServices: TranscriptServices {
        get { self[TranscriptServicesKey.self] }
        set { self[TranscriptServicesKey.self] = newValue }
    }
}
