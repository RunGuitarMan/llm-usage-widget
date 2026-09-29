import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class TranscriptReaderModel: ObservableObject {
    @Published var transcript: SessionTranscript?
    @Published var isLoading = false
    @Published var error: String?
    private var request = UUID()

    init(transcript: SessionTranscript? = nil) { self.transcript = transcript }

    func load(_ session: UsageSession, file: URL? = nil) async {
        let token = UUID()
        request = token
        isLoading = true
        error = nil
        defer { if request == token { isLoading = false } }
        do {
            let result = try await TranscriptService().load(session: session, file: file)
            guard request == token, !Task.isCancelled else { return }
            transcript = result
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
    @StateObject private var reader: TranscriptReaderModel
    @StateObject private var results: SearchResults<TranscriptSearchRequest, TranscriptSearchResult>
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var searchFocusRequest = 0
    @State private var showContext = false
    @State private var reading: TranscriptReading?
    @State private var reload = 0
    @State private var selectedFile: URL?
    @State private var showInfo = false
    @State private var expandedTools: Set<String> = []

    init(session: UsageSession, timezone: String, isDemo: Bool = false, preview: SessionTranscript? = nil) {
        self.session = session
        self.timezone = timezone
        self.isDemo = isDemo
        let initial = preview ?? (isDemo ? TranscriptPreview.sample : nil)
        _reader = StateObject(wrappedValue: TranscriptReaderModel(transcript: initial))
        _results = StateObject(wrappedValue: SearchResults(
            initial: (try? TranscriptSearchResult.evaluate(.init(transcript: initial))) ?? .init(),
            evaluate: { try TranscriptSearchResult.evaluate($0) }))
    }

    private var searchRequest: TranscriptSearchRequest {
        .init(transcript: reader.transcript, query: search, showContext: showContext)
    }
    private var rows: [TranscriptRow] { results.value.rows }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if reader.transcript != nil { timeline }
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
        .task(id: reload) {
            if !isDemo && (reader.transcript == nil || reload > 0) { await reader.load(session, file: selectedFile) }
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Text(L10n.text("История чата")).font(.system(size: 22, weight: .semibold)).tracking(-0.5)
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
                    .buttonStyle(.glass).buttonBorderShape(.circle).keyboardShortcut(.cancelAction)
                    .help(L10n.text("Закрыть чат · Esc")).accessibilityLabel(L10n.text("Закрыть чат"))
            }
            HStack(spacing: 14) {
                SessionSearchField(text: $search, focusRequest: searchFocusRequest, placeholder: L10n.text("Найти в сообщениях и действиях"))
                    .frame(maxWidth: 390).frame(height: 30)
                Spacer(minLength: 0)
                if !search.isEmpty {
                    Text(L10n.text("Найдено: \(results.value.eventCount)"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if let transcript = reader.transcript {
                    Text("\(L10n.count(transcript.messageCount, .messages)) · \(L10n.count(transcript.toolCount, .actions))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if showInfo {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.rawID).font(.system(size: 11, design: .monospaced))
                    Text(session.modelLabel)
                    if let path = session.projectPath { Text(path) }
                    Text(L10n.text("Время событий: \(timezone). История за всю сессию."))
                    if let file = reader.transcript?.files.first { Text(file.path) }
                }.font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        Color.clear.frame(height: 1).id("chat-start")
                        if let error = reader.error { notice(error) }
                        if let notices = reader.transcript?.notices, !notices.isEmpty {
                            DisclosureGroup {
                                ForEach(notices, id: \.self) { Text($0).padding(.top, 4) }
                            } label: { Label(L10n.text("О доступности истории"), systemImage: "info.circle") }
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if rows.isEmpty {
                            EmptyUsageView(title: search.isEmpty ? L10n.text("Нет сообщений для показа") : L10n.text("Совпадений нет"),
                                message: search.isEmpty ? L10n.text("Откройте служебные события в меню, чтобы изучить доступные записи.") : L10n.text("Попробуйте другое слово или часть команды."),
                                symbol: search.isEmpty ? "text.bubble" : "magnifyingglass")
                        }
                        ForEach(rows) { row in
                            if row.isContext {
                                contextGroup(row.events)
                            } else if let event = row.events.first {
                                if event.kind == .tool { toolRow(event) }
                                else { messageRow(event) }
                            }
                        }
                        if search.isEmpty, let transcript = reader.transcript, !showContext {
                            let count = transcript.events.filter { $0.kind == .context }.count
                            if count > 0 {
                                Button { showContext = true } label: {
                                    Label(L10n.text("Показать служебные события (\(count))"), systemImage: "text.alignleft")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }.buttonStyle(.plain).padding(.top, 6)
                            }
                        }
                        Color.clear.frame(height: 22).id("chat-end")
                    }
                    .frame(maxWidth: 740, alignment: .leading)
                    .padding(.horizontal, 36).padding(.top, 4).padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                }
                HStack(spacing: 0) {
                    Button { proxy.scrollTo("chat-start", anchor: .top) } label: { Image(systemName: "arrow.up").frame(width: 30, height: 28) }
                        .help(L10n.text("В начало чата")).accessibilityLabel(L10n.text("В начало чата"))
                    Button { proxy.scrollTo("chat-end", anchor: .bottom) } label: { Image(systemName: "arrow.down").frame(width: 30, height: 28) }
                        .help(L10n.text("К последнему сообщению")).accessibilityLabel(L10n.text("К последнему сообщению"))
                }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.06)))
                    .padding(16)
            }
            .onChange(of: search) { _, _ in proxy.scrollTo("chat-start", anchor: .top) }
        }
    }

    private func messageRow(_ event: TranscriptEvent) -> some View {
        let isUser = event.kind == .user
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: isUser ? "person.fill" : "sparkle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isUser ? Color.secondary : UsageSource.color(session.sourceID))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                Text(isUser ? L10n.text("Вы") : session.sourceLabel).font(.system(size: 12, weight: .semibold))
                if let date = event.timestamp { Text(time(date)).font(.system(size: 10)).foregroundStyle(.tertiary) }
                Spacer()
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
            TranscriptMessageText(text: String(event.text.prefix(3200)))
            if event.text.count > 3200 {
                Button(L10n.text("Читать полностью · \(UsageFormat.exact(Int64(event.text.count))) знаков")) {
                    reading = .init(title: event.title, text: event.text)
                }.buttonStyle(.link).font(.system(size: 11))
            }
            if !search.isEmpty && !String(event.text.prefix(3200)).localizedCaseInsensitiveContains(search) {
                Button(L10n.text("Совпадение в полном содержимом")) {
                    reading = .init(title: event.title, text: event.searchableText, monospaced: true)
                }.buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(isUser ? 18 : 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isUser ? Color.accentColor.opacity(0.055) : Color.clear, in: RoundedRectangle(cornerRadius: 16))
        .padding(.leading, isUser ? 20 : 0)
    }

    private func toolRow(_ event: TranscriptEvent) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { !search.isEmpty || expandedTools.contains(event.id) }, set: {
            if $0 { expandedTools.insert(event.id) } else { expandedTools.remove(event.id) }
        })) {
            VStack(alignment: .leading, spacing: 16) {
                if !event.input.isEmpty { toolContent(L10n.text("Передано"), text: event.input) }
                if !event.output.isEmpty { toolContent(L10n.text("Получено"), text: event.output) }
                if event.output.isEmpty { Text(event.hasResult ? L10n.text("Получен пустой результат.") : L10n.text("Результат не записан в журнале.")).font(.system(size: 11)).foregroundStyle(.secondary) }
                Button(L10n.text("Исходная запись")) { reading = .init(title: event.title, text: event.raw, monospaced: true) }
                    .buttonStyle(.link).font(.system(size: 11))
            }.padding(.top, 14).padding(.bottom, 4)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: event.isError ? "exclamationmark.circle" : "terminal")
                    .foregroundStyle(event.isError ? Color.orange : Color.secondary)
                Text(event.title).fontWeight(.medium).lineLimit(1)
                if let summary = event.toolSummary {
                    Text(summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if event.isError { Text(L10n.text("Ошибка")).foregroundStyle(.orange) }
                Spacer(minLength: 4)
                if let date = event.timestamp { Text(time(date)).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }.font(.system(size: 12))
        }
        .disclosureGroupStyle(WholeRowDisclosureStyle())
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }

    private func toolContent(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { copy(text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help(L10n.text("Скопировать: \(title)")).accessibilityLabel(L10n.text("Скопировать: \(title)"))
                Button(L10n.text("Открыть полностью")) { reading = .init(title: title, text: text, monospaced: true) }
                    .buttonStyle(.link).font(.system(size: 10)).accessibilityLabel(L10n.text("Открыть полностью: \(title)"))
            }
            Text(String(text.prefix(1600))).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).lineLimit(12).frame(maxWidth: .infinity, alignment: .leading)
        }
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
            Image(systemName: "text.bubble").font(.system(size: 11))
            Text(L10n.text("История сессии")).font(.system(size: 11))
            Spacer()
            if reader.isLoading || results.isSearching { ProgressView().controlSize(.mini) }
            Button { reload += 1 } label: { Label(L10n.text("Обновить"), systemImage: "arrow.clockwise") }
                .buttonStyle(.borderless).font(.system(size: 11)).disabled(reader.isLoading || isDemo)
                .keyboardShortcut("r")
        }.foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 13)
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
    }
    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = TimeZone(identifier: timezone)
        formatter.setLocalizedDateFormatFromTemplate("d MMM j:mm")
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
        }.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
        let time = ISO8601DateFormatter().date(from: "2026-09-28T12:40:00Z")!
        return .init(events: [
            .init(id: "1", kind: .user, title: L10n.text("Вы"), text: "Добавь поиск по сессиям. Хочу быстро находить нужный разговор по проекту или названию модели.", timestamp: time, raw: "{\"role\":\"user\",\"content\":\"Добавь поиск по сессиям\"}"),
            .init(id: "2", kind: .assistant, title: L10n.text("Ответ"), text: "Посмотрю, как устроен список сессий, и добавлю поиск рядом с фильтрами. Он будет учитывать **проект, модель и ID сессии**.", timestamp: time.addingTimeInterval(8), raw: "{\"role\":\"assistant\"}"),
            .init(id: "3", kind: .tool, title: "Read · SessionsView.swift", input: "{\n  \"file_path\": \"LLMUsage/Sessions/SessionsView.swift\"\n}", output: "struct SessionsView: View {\n    @ObservedObject var store: UsageStore\n    @State private var search = \"\"\n}", timestamp: time.addingTimeInterval(12), raw: "{\"type\":\"tool_use\",\"name\":\"Read\"}"),
            .init(id: "4", kind: .tool, title: "Edit · Поиск по сессиям", input: "Добавлено поле поиска и фильтрация по проекту, модели и ID.", output: "Файл обновлён.", timestamp: time.addingTimeInterval(19), raw: "{\"type\":\"tool_result\"}"),
            .init(id: "5", kind: .assistant, title: L10n.text("Ответ"), text: "Готово. Поиск появился над списком сессий.\n\nМожно ввести часть названия проекта, модели или ID. Результаты обновляются сразу, а выбранная сортировка сохраняется.\n\nНажмите **⌘F**, чтобы перейти к поиску.", timestamp: time.addingTimeInterval(35), raw: "{\"role\":\"assistant\"}"),
            .init(id: "6", kind: .context, title: L10n.text("Контекст запроса"), raw: "{\"model\":\"example\",\"cwd\":\"/example/project\"}")
        ])
    }
}
