import SwiftUI
import AppKit
import UniformTypeIdentifiers

private func t(_ ru: String, _ en: String) -> String { TelemetryText.choose(ru, en) }

struct ClaudeTelemetryPresentation: ViewModifier {
    @ObservedObject var store: UsageStore
    var maintenancePresented: Bool
    func body(content: Content) -> some View {
        content.modifier(TelemetrySheets(coordinator: store.telemetry, timezone: store.timezone, pricingKey: store.snapshot?.pricingKey,
                                         maintenancePresented: maintenancePresented))
    }
}
private struct TelemetrySheets: ViewModifier {
    @ObservedObject var coordinator: ClaudeTelemetryCoordinator
    var timezone: String
    var pricingKey: String?
    var maintenancePresented: Bool
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $coordinator.presentsOnboarding, onDismiss: coordinator.dismissOnboarding) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(t("Телеметрия Claude", "Claude telemetry")).font(.title2.bold())
                    Text(t("Дополните аналитику чата длительностью API-запросов, ошибками и сверкой цены. Сбор локальный и по умолчанию выключен.", "Add API durations, errors and price comparisons to chat analytics. Collection is local and off by default."))
                    Text(t("Сохраняются только идентификаторы, время, модели, числовые счётчики и безопасные категории. Тексты чата, инструменты и заголовки отбрасываются до записи.", "Only IDs, times, models, counters and safe categories are stored. Chat content, tools and headers are discarded before writing."))
                    Text(coordinator.settingsURL.path).font(.caption.monospaced()).textSelection(.enabled)
                    Text(t("Изменение настроек Claude потребует отдельного предпросмотра и согласия.", "Changing Claude settings requires a separate preview and consent.")).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(t("Не сейчас", "Not now")) { coordinator.dismissOnboarding() }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button(t("Настроить", "Set up")) {
                            coordinator.dismissOnboarding()
                            Task { try? await Task.sleep(for: .milliseconds(300)); await coordinator.preparePreview() }
                        }.keyboardShortcut(.defaultAction)
                    }
                }.padding(26).frame(width: 540).accessibilityIdentifier("telemetry-onboarding")
                    .background { if ManualReviewController.active != nil { TelemetryReviewProbe(kind: "onboarding") } }
            }
            .sheet(isPresented: $coordinator.presentsSetup, onDismiss: coordinator.cancelSetup) { ClaudeTelemetrySetup(coordinator: coordinator) }
            .sheet(isPresented: $coordinator.presentsExport) {
                ClaudeTelemetryExportView(coordinator: coordinator, timezone: timezone, pricingKey: pricingKey, initialIDs: coordinator.exportSessionIDs)
            }
            .task {
                try? await Task.sleep(for: .milliseconds(700))
                offer()
            }
            .onChange(of: maintenancePresented) { _, _ in offer() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in offer() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in offer() }
    }
    private func offer() {
        guard !maintenancePresented, NSApp.isActive,
              NSApp.windows.contains(where: { $0.identifier?.rawValue == "dashboard" && $0.isVisible && $0.isKeyWindow && $0.attachedSheet == nil }) else { return }
        coordinator.offerOnboarding()
    }
}

struct ClaudeTelemetrySettings: View {
    @ObservedObject var coordinator: ClaudeTelemetryCoordinator
    var timezone: String
    @State private var deleteAll = false
    @State private var selected: Set<String> = []
    @State private var deleteSelected = false
    var body: some View {
        Section(t("Телеметрия Claude", "Claude telemetry")) {
            Toggle(t("Принимать телеметрию Claude", "Receive Claude telemetry"), isOn: Binding(get: { coordinator.enabled }, set: { value in Task { await coordinator.setEnabled(value) } }))
                .accessibilityIdentifier("telemetry-toggle")
            HStack {
                Image(systemName: coordinator.status == .receiving ? "dot.radiowaves.left.and.right" : coordinator.status == .failure ? "exclamationmark.triangle" : "circle")
                    .foregroundStyle(coordinator.status == .receiving ? Color.green : coordinator.status == .failure ? .orange : .secondary)
                Text(coordinator.statusText).accessibilityIdentifier("telemetry-status")
                    .background { if ManualReviewController.active != nil { TelemetryReviewProbe(kind: "status", text: coordinator.statusText) } }
                Spacer()
            }
            if let failure = coordinator.failure { Text(TelemetryText.failure(failure)).font(.caption).foregroundStyle(.orange) }
            LabeledContent(t("Последнее API-событие", "Last API event"), value: date(coordinator.snapshot.coverage.lastAPIEvent))
            DisclosureGroup(t("Состояние приёма и хранения", "Receiver and storage details")) {
                LabeledContent(t("Приёмник", "Receiver"), value: coordinator.ready ? t("Готов", "Ready") : t("Остановлен", "Stopped"))
                LabeledContent(t("Последний валидный OTLP-пакет", "Last valid OTLP packet"), value: date(coordinator.snapshot.coverage.lastPacket))
                LabeledContent(t("Последняя запись", "Last disk write"), value: date(coordinator.snapshot.coverage.lastWrite))
                LabeledContent(t("API-запросы / ошибки", "API requests / errors"), value: "\(coordinator.snapshot.summaries.reduce(0) { $0 + $1.requests }) / \(coordinator.snapshot.summaries.reduce(0) { $0 + $1.errors })")
                LabeledContent(t("Без сессии / отвергнуто / пропущено", "Unattributed / rejected / ignored"), value: "\(coordinator.snapshot.coverage.unmatched) / \(coordinator.snapshot.coverage.rejected) / \(coordinator.snapshot.coverage.ignored)")
                LabeledContent(t("Хранилище", "Storage"), value: ByteCountFormatter.string(fromByteCount: Int64(coordinator.snapshot.bytes), countStyle: .file) + " / 100 MiB")
                Text(coordinator.endpoint).font(.caption.monospaced()).textSelection(.enabled)
            }
            Button(t("Настроить подключение…", "Set up connection…")) { Task { await coordinator.preparePreview() } }
                .disabled(coordinator.busy).accessibilityIdentifier("telemetry-setup")
            if let notice = coordinator.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            Text(t("После настройки откройте новую сессию обычным корпоративным способом. При тишине проверьте env, новую сессию, порт и managed settings. Запись env сама по себе не подтверждает отправку событий.", "After setup, open a new session using your usual corporate launcher. If events do not arrive, check env, the new session, the port and managed settings. Writing env alone does not confirm delivery."))
                .font(.caption).foregroundStyle(.secondary)
            Text(t("При выключении или выходе события могут теряться. История остаётся доступной. Для отключения экспорта в Claude вручную установите OTEL_LOGS_EXPORTER=none; приложение не удаляет env.", "Events may be lost while collection is off or the app has quit. History remains available. To disable export in Claude, manually set OTEL_LOGS_EXPORTER=none; the app does not remove env."))
                .font(.caption).foregroundStyle(.secondary)
            Picker(t("Хранить события", "Keep events"), selection: Binding(get: { coordinator.retention }, set: { days in Task { await coordinator.setRetention(days) } })) {
                ForEach([7, 30, 90], id: \.self) { days in Text(t("\(days) дней", "\(days) days")).tag(days) }
            }
            HStack {
                Button(t("Экспорт диагностики…", "Export diagnostics…")) { coordinator.exportSessions() }.accessibilityIdentifier("telemetry-export")
                Spacer()
                Button(t("Удалить все данные…", "Delete all data…"), role: .destructive) { deleteAll = true }
                    .disabled(coordinator.snapshot.sessions.isEmpty)
            }
            DisclosureGroup(t("Сохранённые сессии", "Stored sessions")) {
                ForEach(coordinator.snapshot.summaries) { session in
                    HStack {
                        Toggle(isOn: Binding(get: { selected.contains(session.id) }, set: { if $0 { selected.insert(session.id) } else { selected.remove(session.id) } })) {
                            Text("\(UsageFormat.date(session.last, timezone: timezone, includeTime: true)) · \(session.id.prefix(8)) · \(session.events)")
                        }
                    }
                }
                Button(t("Удалить выбранные сессии…", "Delete selected sessions…"), role: .destructive) { deleteSelected = true }.disabled(selected.isEmpty)
            }
        }
        .alert(t("Удалить телеметрию?", "Delete telemetry?"), isPresented: $deleteAll) {
            Button(t("Удалить", "Delete"), role: .destructive) { Task { await coordinator.delete() } }
            Button(t("Отмена", "Cancel"), role: .cancel) {}
        } message: { Text(t("События будут удалены. Настройки Claude и основная аналитика останутся прежними.", "Events will be deleted. Claude settings and primary analytics stay unchanged.")) }
        .alert(t("Удалить выбранные сессии?", "Delete selected sessions?"), isPresented: $deleteSelected) {
            Button(t("Удалить", "Delete"), role: .destructive) { let ids = selected; selected = []; Task { await coordinator.delete(ids) } }
            Button(t("Отмена", "Cancel"), role: .cancel) {}
        }
    }
    private func date(_ value: Date?) -> String { value.map { UsageFormat.date($0, timezone: timezone, includeTime: true) } ?? "—" }
}

struct ClaudeTelemetrySetup: View {
    @ObservedObject var coordinator: ClaudeTelemetryCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Подключение телеметрии Claude", "Connect Claude telemetry")).font(.title2.bold())
            HStack {
                Text(coordinator.settingsURL.path).font(.caption.monospaced()).textSelection(.enabled)
                Spacer()
                Button(t("Другой файл…", "Choose file…")) { choose() }.disabled(coordinator.isolated || coordinator.busy)
            }
            Text(t("Будут добавлены только отсутствующие пары env. Существующие значения и остальные байты сохранятся. Перед записью будет создана отдельная резервная копия с доступом только владельцу.", "Only missing env pairs will be added. Existing values and all other bytes are preserved. An owner-only backup is created before writing."))
                .font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = coordinator.setupFailure { Text(TelemetryText.failure(error)).foregroundStyle(.orange) }
                    if let preview = coordinator.preview {
                        if !preview.conflicts.isEmpty {
                            Label(t("Конфликт — автоматическая запись отменена целиком", "Conflict — the entire automatic write is blocked"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            // Only known profile keys or bounded variable names are displayed. Never values.
                            Text(preview.conflicts.map(safeKey).joined(separator: "\n")).font(.caption.monospaced())
                        }
                        if !preview.matches.isEmpty {
                            Text(t("Уже совпадают:", "Already match:")).font(.headline)
                            Text(preview.matches.joined(separator: ", ")).font(.caption.monospaced())
                        }
                        if !preview.additions.isEmpty {
                            Text(t("Добавляемые пары:", "Pairs to add:")).font(.headline)
                            ForEach(preview.additions, id: \.key) { pair in Text("\(pair.key) = \(pair.value)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                        }
                        if preview.isNoOp { Text(t("Изменения не требуются; новая резервная копия не создаётся.", "No changes needed; no new backup will be created.")) }
                    } else if coordinator.busy { ProgressView() }
                    DisclosureGroup(t("Ручная настройка", "Manual setup")) {
                        Text(t("Добавьте отсутствующие пары в корневой env самостоятельно, согласовав конфликты с администратором. Не заменяйте весь файл. Затем откройте новую сессию Claude обычным способом.", "Add missing pairs to the root env yourself and resolve conflicts with your administrator. Do not replace the entire file. Then open a new Claude session using your usual launcher."))
                        ForEach(ClaudeSettingsEnvEditor.profile(port: coordinator.port), id: \.key) { pair in Text("\(pair.key) = \(pair.value)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(t("Managed settings или корпоративный launcher могут переопределить env. Приложение не запускает и не перезапускает Claude.", "Managed settings or a corporate launcher may override env. This app does not launch or restart Claude.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(t("Отмена", "Cancel")) { coordinator.cancelSetup() }.keyboardShortcut(.cancelAction)
                Button(t("Обновить preview", "Refresh preview")) { Task { await coordinator.preparePreview() } }.disabled(coordinator.busy)
                Spacer()
                Button(t("Только приёмник", "Listener only")) { Task { await coordinator.useListenerOnly() } }.disabled(!coordinator.ready || coordinator.busy)
                Button(t("Добавить переменные", "Add variables")) { Task { await coordinator.applyPreview() } }
                    .disabled(coordinator.preview?.canApply != true || coordinator.busy).accessibilityIdentifier("telemetry-consent")
            }
        }.padding(24).frame(width: 710, height: 620).accessibilityIdentifier("telemetry-setup-preview")
            .background { if ManualReviewController.active != nil { TelemetryReviewProbe(kind: "setup", value: coordinator.preview?.canApply == true ? 1 : 0) } }
    }
    private func safeKey(_ key: String) -> String { key.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,100}$"#, options: .regularExpression) != nil ? key : t("Неизвестный ключ маршрутизации", "Unknown routing key") }
    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { coordinator.settingsURL = url; Task { await coordinator.preparePreview() } }
    }
}

struct ClaudeTelemetryExportView: View {
    @ObservedObject var coordinator: ClaudeTelemetryCoordinator
    var timezone: String
    var pricingKey: String?
    var initialIDs: Set<String>?
    var initialTranscripts: [String: SessionTranscript] = [:]
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot = TelemetrySnapshot()
    @State private var sessionsMode = false
    @State private var selected = Set<String>()
    @State private var query = ""
    @State private var preset = 0
    @State private var first = Date()
    @State private var last = Date()
    @State private var exporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var error: String?
    private var selection: TelemetryExportSelection {
        let today = UsageDay(date: Date(), timezone: timezone)
        let start = preset == 0 ? today.date : preset == 1 ? today.adding(days: -6).date : UsageDay(date: first, timezone: timezone).date
        let end = preset == 2 ? UsageDay(date: last, timezone: timezone).end : today.end
        return .init(sessionIDs: sessionsMode ? selected : nil, start: sessionsMode ? nil : start, end: sessionsMode ? nil : end, timezone: timezone)
    }
    private var chosen: [String: [ClaudeTelemetryEvent]] { snapshot.sessions.mapValues { $0.filter(selection.includes) }.filter { !$0.value.isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Экспорт диагностики", "Export diagnostics")).font(.title2.bold())
            Picker(t("Выбор данных", "Select data"), selection: $sessionsMode) {
                Text(t("Период", "Period")).tag(false); Text(t("Сессии", "Sessions")).tag(true)
            }.pickerStyle(.segmented)
            if sessionsMode {
                TextField(t("Поиск по дате, модели или ID", "Search date, model or ID"), text: $query)
                sessionList
            } else {
                Picker(t("Период", "Period"), selection: $preset) {
                    Text(t("Сегодня", "Today")).tag(0); Text(t("Последние 7 дней", "Last 7 days")).tag(1); Text(t("Свои даты", "Custom dates")).tag(2)
                }
                if preset == 2 {
                    DatePicker(t("С", "From"), selection: $first, displayedComponents: .date)
                    DatePicker(t("По", "Through"), selection: $last, displayedComponents: .date)
                }
                Text("\(selection.start.map { UsageFormat.date($0, timezone: timezone, includeTime: true) } ?? "—") → \(selection.end.map { UsageFormat.date($0, timezone: timezone, includeTime: true) } ?? "—")").font(.callout)
                Spacer()
            }
            Text(t("Часовой пояс: ", "Timezone: ") + timezone)
            Text(t("Сессий: \(chosen.count) · API-событий: \(chosen.values.reduce(0) { $0 + $1.count })", "Sessions: \(chosen.count) · API events: \(chosen.values.reduce(0) { $0 + $1.count })")).font(.headline)
            Text(t("ZIP: manifest.json, события, числовой accounting.json, summary.json и README. Тексты и настройки исключены. ID и модели заменяются новыми псевдонимами для каждого архива.", "ZIP: manifest.json, events, numeric accounting.json, summary.json and README. Content and settings are excluded. IDs and models get fresh aliases in each archive.")).font(.callout)
            Text(t("Точные метки времени UTC и выбранный часовой пояс сохраняются; косвенное сопоставление по времени и числам возможно. Накопительные итоги — контекст всей сессии, а не расход дня. Архив никуда не отправляется.", "Exact UTC timestamps and the selected timezone are retained; indirect matching by times and numbers remains possible. Cumulative totals are whole-session context, not daily spending. Nothing is uploaded.")).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            HStack {
                Button(t("Отмена", "Cancel")) { exportTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if exporting { ProgressView().controlSize(.small) }
                Button(t("Сохранить ZIP…", "Save ZIP…")) { save() }.disabled(exporting || chosen.isEmpty || (!sessionsMode && selection.start! >= selection.end!))
                    .accessibilityIdentifier("telemetry-save-zip")
            }
        }.padding(24).frame(width: 640, height: 610)
        .environment(\.timeZone, TimeZone(identifier: timezone) ?? .gmt)
        .accessibilityIdentifier("telemetry-export-preview")
        .background { if ManualReviewController.active != nil { TelemetryReviewProbe(kind: "export", value: chosen.values.reduce(0) { $0 + $1.count }) } }
        .task { do { snapshot = try await coordinator.store.snapshot(); selected = initialIDs ?? []; sessionsMode = initialIDs != nil } catch { self.error = TelemetryText.failure(.storage) } }
        .onDisappear { exportTask?.cancel() }
    }
    private var filteredSummaries: [TelemetrySessionSummary] {
        snapshot.summaries.filter { session in
            query.isEmpty || session.id.localizedCaseInsensitiveContains(query)
                || session.models.joined().localizedCaseInsensitiveContains(query)
                || UsageFormat.date(session.last, timezone: timezone, includeTime: true).localizedCaseInsensitiveContains(query)
        }
    }
    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(filteredSummaries) { session in sessionRow(session) }
            }
        }.frame(maxHeight: .infinity)
    }
    private func sessionRow(_ session: TelemetrySessionSummary) -> some View {
        let title = UsageFormat.date(session.last, timezone: timezone, includeTime: true) + " · " + String(session.events) + " " + t("событий", "events")
        let subtitle = session.models.joined(separator: ", ") + " · " + String(session.id.prefix(8))
        let binding = Binding<Bool>(get: { selected.contains(session.id) }, set: { value in
            if value { selected.insert(session.id) } else { selected.remove(session.id) }
        })
        return Toggle(isOn: binding) {
            VStack(alignment: .leading) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func save() {
        exporting = true; error = nil
        let snapshot = snapshot, selection = selection, ids = Array(chosen.keys), isolated = coordinator.isolated
        let initial = initialTranscripts, key = pricingKey
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        exportTask = Task {
            defer { exporting = false }
            do {
                let build = Task.detached(priority: .userInitiated) { () throws -> ClaudeTelemetryExporter.Archive in
                    var transcripts = initial
                    for sid in ids where transcripts[sid] == nil && !isolated {
                        try Task.checkCancellation()
                        let session = UsageSession(id: sid, models: [], usage: .zero)
                        if let transcript = try? await TranscriptService().load(session: session) {
                            transcripts[sid] = (try? await TranscriptCostService().price(transcript, source: "claude", customPath: "", pricingKey: key)) ?? transcript
                        }
                    }
                    return try ClaudeTelemetryExporter.make(snapshot: snapshot, selection: selection, transcripts: transcripts, appVersion: version,
                                                            helperVersion: CCUsageManifest.bundled?.version, contract: CCUsageManifest.bundled?.contractVersion)
                }
                let archive = try await withTaskCancellationHandler(operation: { try await build.value }, onCancel: { build.cancel() })
                try Task.checkCancellation()
                let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = "claude-diagnostics.zip"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let write = Task.detached(priority: .userInitiated) { try ClaudeTelemetryExporter.save(archive, to: url) }
                try await write.value
                dismiss()
            } catch is CancellationError { }
            catch { self.error = TelemetryText.failure(.export) }
        }
    }
}
