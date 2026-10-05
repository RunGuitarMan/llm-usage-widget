import Foundation
import CryptoKit
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#endif

private struct RuntimeCheckFailure: Error { let message: String }
private func requireRuntime(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw RuntimeCheckFailure(message: message) }
}

private actor RuntimeGate {
    var entered = false
    var release: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { release = $0 } }
    func finish() { release?.resume(); release = nil }
}

struct RuntimeScenarios {
    private static func fixture(_ directory: URL, version: String = "20.0.26") throws -> (URL, CCUsageManifest) {
        let executable = directory.appendingPathComponent("ccusage")
        try Data("#!/bin/sh\nprintf 'ccusage \(version)\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, .init(schemaVersion: 1, version: "20.0.26", contractVersion: 1, architecture: "arm64",
            binarySHA256: SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()))
    }

    @MainActor static func run(check: (String, () async throws -> Void) async -> Void) async {
        await check("Runtime: consent gates validation and execution; update defaults do not grant consent") {
            let suite = "LLMUsage.RuntimeCheck.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            try requireRuntime(!RuntimeConsent.isGranted(defaults: defaults), "Consent was inferred")
            let preferences = UpdatePreferences.load(defaults)
            try requireRuntime(preferences.mode == .automatic && preferences.checksAutomatically, "Default policy changed")
            UpdatePreferences(checksAutomatically: false, mode: .downloadAndAsk).save(defaults)
            try requireRuntime(UpdatePreferences.load(defaults).mode == .downloadAndAsk
                               && !UpdatePreferences.load(defaults).checksAutomatically, "Preferences lost")
            let runtime = CCUsageRuntime(executable: URL(fileURLWithPath: "/missing"), manifest: nil, authorized: { false })
            do {
                _ = try await runtime.withExecutable { _ in true }
                throw RuntimeCheckFailure(message: "Unauthorized execution")
            } catch UsageError.runtimeConsentRequired { }
        }
        await check("Runtime: setup prompts once across launches without granting consent, including existing users") {
            let suite = "LLMUsage.SetupCheck.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            try requireRuntime(RuntimeConsent.takeFirstLaunchPrompt(defaults: defaults), "First launch did not introduce the component")
            let restarted = UserDefaults(suiteName: suite)!
            try requireRuntime(!RuntimeConsent.takeFirstLaunchPrompt(defaults: restarted), "Later prompted again on relaunch")
            try requireRuntime(!RuntimeConsent.isGranted(defaults: restarted), "Showing the introduction granted permission")
            defaults.removePersistentDomain(forName: suite)
            defaults.set(true, forKey: RuntimeConsent.key)
            try requireRuntime(!RuntimeConsent.takeFirstLaunchPrompt(defaults: defaults), "An existing consent prompted again")
            defaults.set(false, forKey: RuntimeConsent.key)
            try requireRuntime(!RuntimeConsent.takeFirstLaunchPrompt(defaults: UserDefaults(suiteName: suite)!), "Revoking consent restarted onboarding")
        }
        await check("Runtime: modified binary and wrong exact version fail closed") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let (executable, manifest) = try fixture(root)
            let runtime = CCUsageRuntime(executable: executable, manifest: manifest, authorized: { true })
            let path = try await runtime.withExecutable { $0.path }
            try requireRuntime(path == executable.path, "Runtime switched executables")
            try Data("changed".utf8).write(to: executable)
            do {
                _ = try await runtime.withExecutable { _ in true }
                throw RuntimeCheckFailure(message: "Modified helper accepted")
            } catch UsageError.runtimeUnavailable { }
            let (wrong, wrongManifest) = try fixture(root, version: "20.0.27")
            let mismatch = CCUsageRuntime(executable: wrong, manifest: wrongManifest, authorized: { true })
            do {
                _ = try await mismatch.withExecutable { _ in true }
                throw RuntimeCheckFailure(message: "Different version accepted")
            } catch UsageError.runtimeUnavailable { }
        }
        await check("Runtime: update waits for an entire calculation and blocks new work") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let (executable, manifest) = try fixture(root)
            let runtime = CCUsageRuntime(executable: executable, manifest: manifest, authorized: { true })
            let gate = RuntimeGate()
            let calculation = Task { try await runtime.withExecutable { _ in await gate.wait() } }
            for _ in 0..<100 {
                if await gate.entered { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard await gate.entered else { calculation.cancel(); throw RuntimeCheckFailure(message: "Runtime did not start") }
            do { try await runtime.suspendAndWait(timeout: 0.02); throw RuntimeCheckFailure(message: "Lost active lease") }
            catch UsageError.timedOut { }
            await gate.finish()
            try await calculation.value
            try await runtime.suspendAndWait()
            do {
                _ = try await runtime.withExecutable { _ in true }
                throw RuntimeCheckFailure(message: "Calculation started during installation")
            } catch UsageError.maintenanceInProgress { }
            await runtime.resume()
            let resumed = try await runtime.withExecutable { _ in true }
            try requireRuntime(resumed, "Runtime did not resume after an aborted update")
        }
        await check("Updates: signed archive survives loopback handoff; corruption and other routes are rejected") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bytes = Data(repeating: 0x42, count: 400_000)
            let key = Curve25519.Signing.PrivateKey()
            let archive = UpdateArchive(url: URL(string: "https://example.invalid/update.zip")!, length: Int64(bytes.count),
                signature: try key.signature(for: bytes), publicKey: key.publicKey.rawRepresentation)
            let file = root.appendingPathComponent("update.zip")
            try bytes.write(to: file)
            try archive.verify(file)
            let server = try UpdateArchiveServer(file: file, archive: archive)
            defer { server.stop() }
            let url = try await server.start()
            let (received, response) = try await URLSession.shared.data(from: url)
            try requireRuntime((response as? HTTPURLResponse)?.statusCode == 200 && received == bytes, "Archive handoff changed bytes")
            let (_, rejected) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("other.zip"))
            try requireRuntime((rejected as? HTTPURLResponse)?.statusCode == 404, "Server exposes other paths")
            var corrupted = bytes; corrupted[0] = 0
            try corrupted.write(to: file)
            do { try archive.verify(file); throw RuntimeCheckFailure(message: "Corrupted archive accepted") }
            catch is URLError { }
        }
        await check("Runtime: engine provenance prevents tariff parity across versions without losing displayable history") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = TranscriptPricingArchive(directory: root)
            let key = try archive.save(configuration: Data("{}".utf8), engineID: "ccusage/old")
            _ = try archive.configuration(key: key, source: "claude", expectedEngineID: "ccusage/old")
            do {
                _ = try archive.configuration(key: key, source: "claude", expectedEngineID: "ccusage/new")
                throw RuntimeCheckFailure(message: "Different engine accepted for reconciliation")
            } catch UsageError.runtimeUnavailable { }
            let old = UsageDataContext(timezone: "UTC", customPath: "", updateMode: .claudeOnly, engineID: "old")
            let new = UsageDataContext(timezone: "UTC", customPath: "", updateMode: .claudeOnly, engineID: "new")
            try requireRuntime(old != new && old.canDisplay(alongside: new), "Old engine data hidden or treated as current")
            let legacy = try JSONDecoder().decode(UsageDataContext.self,
                from: Data(#"{"timezone":"UTC","customPath":"","updateMode":"claudeOnly"}"#.utf8))
            try requireRuntime(legacy.engineID == nil && legacy != new, "Legacy engine was fabricated")
            let now = Date()
            let today = UsageDay(date: now, timezone: "UTC")
            let yesterday = today.adding(days: -1)
            var snapshot = UsageSnapshot(generatedAt: now, day: yesterday, sessions: [])
            snapshot.dataContext = old
            var history = UsageHistory(context: old)
            history.record(snapshot, today: today, now: now)
            history.context = new
            try requireRuntime(history.days.count == 1 && history.missingCompletedDays(ending: today, now: now).contains(yesterday),
                               "Engine migration lost historical totals or skipped their recalculation")
        }
    }
}
