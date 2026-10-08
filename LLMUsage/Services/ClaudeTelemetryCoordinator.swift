import Foundation
import Combine

/// This language helper keeps telemetry's RU/EN copy together, including dynamic
/// states whose values must never be used as localization lookup keys.
enum TelemetryText {
    static func choose(_ russian: String, _ english: String) -> String { L10n.preference.resolved() == .russian ? russian : english }
    static let title = "Телеметрия Claude"
    static func failure(_ error: TelemetryFailure) -> String {
        switch error {
        case .invalidJSON: return choose("Нужен строгий JSON без повторяющихся ключей; корень и env должны быть объектами. Файл не изменён.", "Strict JSON without duplicate keys is required; root and env must be objects. File unchanged.")
        case .unsafePath: return choose("Небезопасный путь, владелец, тип или разрешения файла. Настройте env вручную.", "Unsafe path, ownership, file type or permissions. Configure env manually.")
        case .settingsChanged: return choose("Файл изменился после предпросмотра. Откройте новый предпросмотр и подтвердите его заново.", "The file changed after preview. Open a new preview and confirm it again.")
        case .settingsConflict: return choose("Существующая конфигурация конфликтует с подключением. Автоматическая запись отменена целиком.", "Existing configuration conflicts with this connection. The entire automatic write was cancelled.")
        case .backup: return choose("Не удалось создать и проверить резервную копию. Исходный файл не изменён.", "Could not create and verify the backup. Original file unchanged.")
        case .postcheck: return choose("Проверка результата не прошла. Автоматический откат не выполнялся; проверьте файл и резервную копию.", "Result verification failed. No automatic rollback was attempted; inspect the file and backup.")
        case .port: return choose("Порт занят или недоступен. Сохранённый endpoint не менялся; освободите порт и повторите включение.", "Port is busy or unavailable. Saved endpoint is unchanged; free the port and enable again.")
        case .quota: return choose("Не удалось освободить квоту хранения. Приём приостановлен.", "Could not free the storage quota. Collection is paused.")
        case .export: return choose("Архив не сохранён. Проверьте доступ и свободное место.", "Archive was not saved. Check permissions and free space.")
        default: return choose("Не удалось завершить операцию с локальным хранилищем. Проверьте доступ и свободное место; резервные копии сохраняются.", "Local storage operation failed. Check permissions and free space; backups are retained.")
        }
    }
}

@MainActor final class ClaudeTelemetryCoordinator: ObservableObject {
    enum Status: String { case off, ready, receiving, waiting, failure }
    let store: ClaudeTelemetryStore
    let editor = ClaudeSettingsEnvEditor()
    let isolated: Bool
    let isolationRoot: URL?
    private let defaults: UserDefaults
    @Published private(set) var enabled: Bool
    @Published private(set) var ready = false
    @Published private(set) var port: UInt16
    @Published var settingsURL: URL
    @Published var preview: ClaudeSettingsEnvEditor.Preview?
    @Published var presentsSetup = false
    @Published var presentsOnboarding = false
    @Published var presentsExport = false
    @Published var exportSessionIDs: Set<String>?
    @Published var failure: TelemetryFailure?
    @Published var setupFailure: TelemetryFailure?
    @Published var notice: String?
    @Published private(set) var snapshot = TelemetrySnapshot()
    @Published private(set) var sessionRevisions: [String: Int] = [:]
    @Published private(set) var retention: Int
    @Published private(set) var busy = false
    @Published private(set) var clock = Date()
    private var receiver: ClaudeTelemetryReceiver?
    private var startID = UUID()
    private var started = false
    private var timer: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var changedSessions = Set<String>()
    var configured: Bool { defaults.bool(forKey: "telemetry.configured") }
    var endpoint: String { "http://127.0.0.1:\(port)/v1/logs" }
    var status: Status {
        if !enabled { return .off }
        if failure != nil { return .failure }
        guard ready, let last = snapshot.coverage.lastAPIEvent else { return .ready }
        return clock.timeIntervalSince(last) < 60 ? .receiving : .waiting
    }
    var statusText: String {
        switch status {
        case .off: return TelemetryText.choose("Выключено", "Off")
        case .ready: return ready ? TelemetryText.choose("Приёмник готов, API-событий ещё нет", "Receiver ready, no API events yet") : TelemetryText.choose("Подключаем приёмник…", "Starting receiver…")
        case .receiving: return TelemetryText.choose("Получаем API-события", "Receiving API events")
        case .waiting: return TelemetryText.choose("Ожидаем новые события", "Waiting for new events")
        case .failure: return TelemetryText.choose("Ошибка подключения/хранения", "Connection / storage error")
        }
    }
    init(defaults: UserDefaults = .standard, isolated: Bool = false, root: URL? = nil) {
        self.defaults = defaults; self.isolated = isolated
        let testRoot = isolated ? root ?? URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("llmusage-telemetry-review-" + UUID().uuidString) : nil
        isolationRoot = testRoot
        let directory = testRoot?.appendingPathComponent("Telemetry") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LLMUsage/Telemetry")
        let days = defaults.integer(forKey: "telemetry.retention")
        let selectedRetention = [7, 30, 90].contains(days) ? days : 30
        retention = selectedRetention
        store = isolated ? ClaudeTelemetryStore(directory: directory, retentionDays: selectedRetention) : .shared
        enabled = !isolated && defaults.bool(forKey: "telemetry.enabled")
        port = isolated ? 0 : UInt16(exactly: defaults.integer(forKey: "telemetry.port")) .flatMap { $0 == 0 ? nil : $0 } ?? 4318
        settingsURL = testRoot?.appendingPathComponent(".claude/settings.json") ?? defaults.string(forKey: "telemetry.settingsPath").map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    func start() async {
        guard !started else { return }; started = true
        do { try await store.setRetention(retention) } catch { failure = .storage }
        await refresh()
        if enabled { await startReceiver(allowAlternative: !configured) }
        timer = Task { [weak self] in
            var nextCleanup = Date().addingTimeInterval(3600)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.clock = Date()
                if Date() >= nextCleanup, let self {
                    do { try await store.setRetention(retention); await refresh() }
                    catch { failure = .storage }
                    nextCleanup = Date().addingTimeInterval(3600)
                }
            }
        }
    }
    func offerOnboarding() {
        guard !isolated, !defaults.bool(forKey: "telemetry.onboardingSeen") else { return }
        presentsOnboarding = true
    }
    func dismissOnboarding() { defaults.set(true, forKey: "telemetry.onboardingSeen"); presentsOnboarding = false }
    func setEnabled(_ value: Bool) async {
        enabled = value; defaults.set(value, forKey: "telemetry.enabled")
        if !value {
            stopImmediately()
            do { try await store.setCollecting(false) } catch { failure = .storage }
            await refresh(); return
        }
        await startReceiver(allowAlternative: !configured)
        if !configured { await preparePreview() }
    }
    private func startReceiver(allowAlternative: Bool) async {
        guard receiver == nil else { return }
        let identity = UUID(); startID = identity; failure = nil
        do {
            func make(_ port: UInt16) throws -> ClaudeTelemetryReceiver {
                try ClaudeTelemetryReceiver(port: port, store: store) { [weak self] sessions, error in
                    Task { @MainActor [weak self] in self?.received(sessions: sessions, error: error) }
                }
            }
            var candidate = try make(port); receiver = candidate
            let selected: UInt16
            do { selected = try await candidate.start() }
            catch {
                candidate.stop()
                guard allowAlternative, identity == startID else { throw TelemetryFailure.port }
                candidate = try make(0); receiver = candidate
                selected = try await candidate.start()
            }
            guard startID == identity else { candidate.stop(); return }
            port = selected; defaults.set(Int(selected), forKey: "telemetry.port")
            ready = true
            if enabled { try await store.setCollecting(true); await refresh() }
        } catch {
            if startID == identity { receiver?.stop(); receiver = nil; ready = false; failure = (error as? TelemetryFailure) ?? .port }
        }
    }
    func stopImmediately() {
        startID = UUID(); store.gate.set(false); receiver?.stop(); receiver = nil; ready = false
    }
    func shutdown() async {
        stopImmediately(); timer?.cancel(); refreshTask?.cancel()
        try? await store.setCollecting(false)
    }
    func preparePreview() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        presentsSetup = true; setupFailure = nil; preview = nil; notice = nil
        await startReceiver(allowAlternative: !configured)
        guard ready else { setupFailure = failure ?? .port; return }
        do {
            preview = try await editor.inspect(url: settingsURL, port: port)
            if preview?.isNoOp == true { notice = TelemetryText.choose("Все переменные уже совпадают. Файл и резервные копии не изменятся.", "All variables already match. No file or backup will change.") }
        } catch { setupFailure = (error as? TelemetryFailure) ?? .invalidJSON }
    }
    func applyPreview() async {
        guard !busy, let preview, preview.canApply else { return }
        busy = true; defer { busy = false }
        do {
            if let receipt = try await editor.apply(preview) {
                // Local operation receipt contains hashes/keys/paths only. UserDefaults
                // is never a source for the diagnostic archive.
                defaults.set(try TelemetryJSON.encode(receipt), forKey: "telemetry.lastSettingsReceipt")
            }
            defaults.set(true, forKey: "telemetry.configured")
            defaults.set(settingsURL.path, forKey: "telemetry.settingsPath")
            enabled = true; defaults.set(true, forKey: "telemetry.enabled")
            if receiver == nil { await startReceiver(allowAlternative: false) }
            else { try await store.setCollecting(true) }
            self.preview = nil; presentsSetup = false
            notice = TelemetryText.choose("Откройте новую сессию Claude обычным корпоративным способом. Применение env подтвердится только поступлением API-событий.", "Open a new Claude session using your usual corporate launcher. API events will confirm whether env was applied.")
            await refresh()
        } catch {
            setupFailure = (error as? TelemetryFailure) ?? .write
            if configured { failure = setupFailure }
            self.preview = nil // Stale plans always need another preview and consent.
        }
    }
    func useListenerOnly() async {
        defaults.set(true, forKey: "telemetry.configured")
        enabled = true; defaults.set(true, forKey: "telemetry.enabled")
        presentsSetup = false; preview = nil
        if receiver == nil { await startReceiver(allowAlternative: false) }
        else { do { try await store.setCollecting(true) } catch { failure = .storage } }
        await refresh()
    }
    func cancelSetup() { preview = nil; presentsSetup = false; if !enabled { stopImmediately() } }
    private func received(sessions: Set<String>, error: TelemetryFailure?) {
        guard enabled else { return }
        failure = error
        changedSessions.formUnion(sessions)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self else { return }
            await refresh()
            for sid in changedSessions { sessionRevisions[sid, default: 0] += 1 }
            changedSessions.removeAll()
        }
    }
    func refresh() async {
        do {
            let next = try await store.snapshot()
            let before = Dictionary(uniqueKeysWithValues: snapshot.summaries.map { ($0.id, $0) })
            let after = Dictionary(uniqueKeysWithValues: next.summaries.map { ($0.id, $0) })
            for sid in Set(before.keys).union(after.keys) where before[sid]?.events != after[sid]?.events || before[sid]?.lastReceived != after[sid]?.lastReceived {
                sessionRevisions[sid, default: 0] += 1
            }
            snapshot = next; clock = Date()
        }
        catch { failure = (error as? TelemetryFailure) ?? .storage }
    }
    func setRetention(_ days: Int) async {
        do { try await store.setRetention(days); retention = days; defaults.set(days, forKey: "telemetry.retention"); await refresh() }
        catch { failure = .storage }
    }
    func delete(_ ids: Set<String>? = nil) async {
        do {
            let affected = ids ?? Set(snapshot.sessions.keys)
            try await store.delete(sessionIDs: ids); await refresh()
            for sid in affected { sessionRevisions[sid, default: 0] += 1 }
        } catch { failure = .storage }
    }
    func exportSessions(_ ids: Set<String>? = nil) { exportSessionIDs = ids; presentsExport = true }
    deinit { timer?.cancel(); refreshTask?.cancel(); receiver?.stop() }
}
