// This executable is compiled only by check-updates.sh, never into the app.
import AppKit
import CryptoKit
import Foundation

private struct NoUsageService: CCUsageServing {
    func fetch(day: UsageDay, customPath: String, mode: UsageUpdateMode) async throws -> UsageSnapshot {
        throw UsageError.runtimeConsentRequired
    }
    func diagnose(customPath: String, forceDetect: Bool) async throws -> CLIDiagnostics { throw UsageError.runtimeConsentRequired }
}

@MainActor
final class UpdateIntegration: NSObject, NSApplicationDelegate {
    var coordinator: AppUpdateCoordinator?
    var store: UsageStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary!
        let output = URL(fileURLWithPath: info["IntegrationOutput"] as! String)
        let mode = info["IntegrationMode"] as! String
        func record(_ message: String) {
            let line = Data((message + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: output) {
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line); try? handle.close()
            } else { try? line.write(to: output) }
        }
        if info["CFBundleVersion"] as? String == "2" {
            record("RELAUNCHED 2")
            NSApp.terminate(nil)
            return
        }
        UserDefaults.standard.set(true, forKey: RuntimeConsent.key)
        UpdatePreferences(checksAutomatically: false,
            mode: mode == "automatic" ? .automatic : mode == "manual" ? .manual : .downloadAndAsk)
            .save(.standard)
        let store = UsageStore(service: NoUsageService(), repository: SnapshotRepository(directory: output.deletingLastPathComponent().appendingPathComponent("data")), reloadWidget: {})
        self.store = store
        let coordinator = AppUpdateCoordinator()
        self.coordinator = coordinator
        coordinator.start(store: store, present: {})
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            coordinator.check()
            var prior: AppUpdateCoordinator.Phase?
            for _ in 0..<1200 {
                if prior != coordinator.phase {
                    record("PHASE \(coordinator.phase)")
                    prior = coordinator.phase
                }
                if coordinator.phase == .failed {
                    record("ERROR \(coordinator.failure ?? "unknown")")
                    NSApp.terminate(nil); return
                }
                if coordinator.phase == .available && mode == "manual" {
                    record("MANUAL AVAILABLE"); NSApp.terminate(nil); return
                }
                if coordinator.phase == .ready {
                    if mode == "ask" { record("QUIT WITHOUT INSTALL"); NSApp.terminate(nil); return }
                    if mode == "install" { coordinator.install() }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            record("TIMEOUT"); NSApp.terminate(nil)
        }
    }
}

@main
struct IntegrationMain {
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--keypair") {
            let key = Curve25519.Signing.PrivateKey()
            let pair = ["private": key.rawRepresentation.base64EncodedString(), "public": key.publicKey.rawRepresentation.base64EncodedString()]
            print(String(decoding: try JSONEncoder().encode(pair), as: UTF8.self))
            return
        }
        let app = NSApplication.shared
        let delegate = UpdateIntegration()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
