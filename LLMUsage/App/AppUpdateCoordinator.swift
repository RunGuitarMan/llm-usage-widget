import AppKit
import Combine
import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppUpdateCoordinator: NSObject, ObservableObject {
    static let shared = AppUpdateCoordinator()
    enum Phase: Equatable { case idle, checking, available, downloading, ready, installing, current, failed }
    @Published private(set) var enabled: Bool
    @Published var presentsSetup = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var version = ""
    @Published private(set) var releaseNotes = ""
    @Published private(set) var failure: String?
    @Published private(set) var installDate: Date?
    @Published var preferences: UpdatePreferences { didSet { preferences.save(defaults); applyPreferences() } }
    private let defaults: UserDefaults
    private weak var store: UsageStore?
    private var present: (() -> Void)?
    private var started = false
    private var consentTask: Task<Void, Never>?
    private let cache = UpdateDownloadCache()
    private var archive: UpdateArchive?
    private var cachedFile: URL?
    private var server: UpdateArchiveServer?
    private var localArchiveURL: URL?
    private var downloadTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var continueUpdate: (() -> Void)?
    private var dismissUpdate: (() -> Void)?
    private var cancelSparkle: (() -> Void)?
    #if canImport(Sparkle)
    private var updater: SPUUpdater?
    #endif

    var updatesSupported: Bool {
        Bundle.main.object(forInfoDictionaryKey: "UsageUpdateChannel") as? String == "release"
    }
    var busy: Bool { phase == .checking || phase == .downloading || phase == .installing }
    var status: String {
        switch phase {
        case .idle: return L10n.text("Обновления приложения")
        case .checking: return L10n.text("Проверка обновлений…")
        case .available: return L10n.text("Доступна версия \(version)")
        case .downloading: return L10n.text("Загрузка версии \(version)…")
        case .ready: return L10n.text("Версия \(version) готова к установке")
        case .installing: return L10n.text("Установка обновления…")
        case .current: return L10n.text("Установлена актуальная версия")
        case .failed: return L10n.text("Не удалось обновить приложение")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = RuntimeConsent.isGranted(defaults: defaults)
        preferences = .load(defaults)
        super.init()
    }

    func start(store: UsageStore, present: @escaping () -> Void) {
        guard !store.isDemo, !started else { return }
        started = true
        self.store = store
        self.present = present
        if enabled { store.start(); startUpdater() }
        else {
            Task { await store.restoreSavedData() }
            presentsSetup = true
            present()
        }
    }

    func activate() {
        defaults.set(true, forKey: RuntimeConsent.key)
        enabled = true
        presentsSetup = false
        let preceding = consentTask
        consentTask = Task {
            await preceding?.value
            guard enabled else { return }
            await CCUsageRuntime.shared.resume()
            store?.resumeAfterAppUpdate()
            store?.start()
            await store?.refresh(reason: .configuration)
        }
        startUpdater()
    }

    func deactivate() {
        guard phase != .installing else { return }
        defaults.set(false, forKey: RuntimeConsent.key)
        enabled = false
        postpone()
        applyPreferences()
        let preceding = consentTask
        consentTask = Task {
            await preceding?.value
            guard !enabled else { return }
            try? await store?.prepareForAppUpdate()
        }
    }

    func check() {
        guard enabled else { presentsSetup = true; present?(); return }
        present?()
        #if canImport(Sparkle)
        startUpdater()
        if phase == .available || phase == .ready { return }
        guard let updater, updater.canCheckForUpdates else { return }
        phase = .checking
        updater.checkForUpdates()
        #endif
    }

    private func startUpdater() {
        #if canImport(Sparkle)
        guard enabled, updatesSupported, updater == nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        self.updater = updater
        // All preference writes reflect the user's setup choice. Download-only is
        // owned by our verified cache, never Sparkle's install-on-quit mechanism.
        applyPreferences()
        do {
            try updater.start()
            if preferences.checksAutomatically { updater.checkForUpdatesInBackground() }
        } catch { self.updater = nil; fail(error) }
        #endif
    }

    private func applyPreferences() {
        #if canImport(Sparkle)
        updater?.automaticallyChecksForUpdates = enabled && preferences.checksAutomatically
        updater?.automaticallyDownloadsUpdates = false
        #endif
        if !preferences.mode.automaticallyInstalls || !enabled { cancelCountdown() }
        if enabled, phase == .ready, preferences.mode.automaticallyInstalls, installDate == nil { scheduleInstall() }
        if enabled, phase == .available, preferences.mode.automaticallyDownloads { download() }
    }

    func download() {
        guard enabled, let archive, phase == .available else { return }
        phase = .downloading
        progress = 0
        failure = nil
        downloadTask = Task { [weak self, cache] in
            guard let self else { return }
            do {
                let file = try await cache.download(archive) { value in
                    Task { @MainActor in if self.phase == .downloading { self.progress = value } }
                }
                try Task.checkCancellation()
                guard self.enabled else { return }
                self.cachedFile = file
                self.phase = .ready
                if self.preferences.mode.automaticallyInstalls { self.scheduleInstall() }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.fail(error) } }
        }
    }

    private func scheduleInstall() {
        cancelCountdown()
        installDate = Date().addingTimeInterval(15)
        present?()
        installTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.enabled, self.preferences.mode.automaticallyInstalls,
                  self.phase == .ready else { return }
            self.install()
        }
    }
    private func cancelCountdown() { installTask?.cancel(); installTask = nil; installDate = nil }

    func postpone() {
        guard phase != .installing else { return }
        cancelCountdown()
        downloadTask?.cancel()
        downloadTask = nil
        cancelSparkle?()
        cancelSparkle = nil
        let dismiss = dismissUpdate
        dismissUpdate = nil
        continueUpdate = nil
        dismiss?()
        phase = .idle
    }

    func install() {
        guard enabled, phase == .ready, let archive, let cachedFile, continueUpdate != nil else { return }
        cancelCountdown()
        phase = .installing
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.store?.prepareForAppUpdate()
                try await CCUsageRuntime.shared.suspendAndWait()
                // The cache is checked again immediately before it is handed off.
                let server = try UpdateArchiveServer(file: cachedFile, archive: archive)
                self.server = server
                self.localArchiveURL = try await server.start()
                try Task.checkCancellation()
                let proceed = self.continueUpdate
                self.continueUpdate = nil
                self.dismissUpdate = nil
                proceed?()
            } catch { self.fail(error) }
        }
    }

    private func fail(_ error: Error) {
        cancelCountdown()
        server?.stop(); server = nil; localArchiveURL = nil
        failure = error.localizedDescription
        phase = .failed
        let dismiss = dismissUpdate
        dismissUpdate = nil; continueUpdate = nil
        dismiss?()
        if enabled { store?.resumeAfterAppUpdate() }
        Task { await CCUsageRuntime.shared.resume() }
    }
}

#if canImport(Sparkle)
extension AppUpdateCoordinator: SPUUpdaterDelegate, SPUUserDriver {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard enabled, updatesSupported else { throw UsageError.runtimeConsentRequired }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard item.signingValidationStatus == .succeeded else { throw URLError(.secureConnectionFailed) }
    }
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        // Only this already validated archive can be served by the loopback endpoint.
        if item.fileURL == archive?.url, let localArchiveURL { request.url = localArchiveURL }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if (error as NSError).code != SUError.noUpdateError.rawValue { fail(error) }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if phase == .checking, error == nil { phase = .current }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: enabled && preferences.checksAutomatically,
                                        sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        phase = .checking; failure = nil; cancelSparkle = cancellation
    }
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancelSparkle = nil
        // Never resume an installation armed outside this user's consent policy.
        guard enabled, state.stage == .notDownloaded, !item.isInformationOnlyUpdate,
              item.signingValidationStatus == .succeeded,
              let url = item.fileURL, Self.permitsArchive(url),
              url.pathExtension == "zip", item.contentLength <= UInt64(UpdateArchive.maximumBytes),
              let enclosure = item.propertiesDictionary["enclosure"] as? [String: Any],
              let signatureText = enclosure["sparkle:edSignature"] as? String,
              let signature = Data(base64Encoded: signatureText), signature.count == 64,
              let keyText = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let key = Data(base64Encoded: keyText), key.count == 32 else {
            reply(.skip); fail(URLError(.badServerResponse)); return
        }
        archive = UpdateArchive(url: url, length: Int64(item.contentLength), signature: signature, publicKey: key)
        cachedFile = nil
        version = item.displayVersionString
        // Release CI supplies plain text. Do not render remote HTML or active links.
        releaseNotes = String((item.itemDescription ?? "").prefix(20_000))
        phase = .available
        failure = nil
        continueUpdate = { reply(.install) }
        dismissUpdate = { reply(.dismiss) }
        if preferences.mode.automaticallyDownloads { download() }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        phase = .current; cancelSparkle = nil; acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { fail(error); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { cancelSparkle = cancellation }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { cancelSparkle = nil; server?.stop(); server = nil }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Reaching Sparkle's installer always follows an explicit install click or
        // the visible automatic-install countdown; download-only never reaches here.
        guard enabled, phase == .installing else { reply(.skip); return }
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        cancelSparkle = nil
        server?.stop(); server = nil
    }
    func showUpdateInFocus() { present?() }
}
#endif

extension AppUpdateCoordinator {
    static func permitsArchive(_ url: URL) -> Bool {
        #if UPDATE_TESTING
        if url.scheme == "http", url.host == "127.0.0.1" { return true }
        #endif
        return url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/RunGuitarMan/llm-usage-widget/releases/download/")
    }
}
