import Foundation
import Darwin

@MainActor enum WidgetProcessFixture {
    /// Non-UI process fixture: a signed copy of the system sleep utility, never
    /// another application/scene. Reproduces the mapped-old-code update failure.
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetProcessCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("LLMUsageWidget.appex/Contents/MacOS/LLMUsageWidget")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        func signedCopy(_ source: String, to destination: URL) async throws {
            try FileManager.default.copyItem(atPath: source, toPath: destination.path)
            let signer = Process()
            signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signer.arguments = ["--force", "--sign", "-", "--identifier", "local.LLMUsage.LifecycleFixture.Widget", destination.path]
            signer.standardOutput = FileHandle.nullDevice
            signer.standardError = FileHandle.nullDevice
            try signer.run()
            while signer.isRunning { try await Task.sleep(for: .milliseconds(10)) }
            try require(signer.terminationStatus == 0, "Could not sign non-UI process fixture")
        }
        try await signedCopy("/bin/sleep", to: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["60"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try await Task.sleep(for: .milliseconds(100))
        guard let original = WidgetExtensionLifecycle.staticIdentity(at: executable),
              let running = WidgetExtensionLifecycle.processIdentity(process.processIdentifier) else {
            throw NSError(domain: "WidgetChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot identify running signed extension fixture"])
        }
        try require(!WidgetExtensionLifecycle.retire(running, current: original, executable: executable.path),
                                "Lifecycle stopped the current executable")
        // Replace the inode, like Sparkle/Finder; the old process keeps its map.
        let replacement = root.appendingPathComponent("replacement")
        try await signedCopy("/bin/cat", to: replacement)
        try require(rename(replacement.path, executable.path) == 0, "Could not replace fixture executable")
        guard let updated = WidgetExtensionLifecycle.staticIdentity(at: executable),
              let stale = WidgetExtensionLifecycle.processIdentity(process.processIdentifier) else {
            throw NSError(domain: "WidgetChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Lost identity after replacing the mapped executable"])
        }
        try require(updated != original, "Update fixture did not change signing identity")
        try require(stale.code == original && stale.startSeconds == running.startSeconds
                    && stale.startMicroseconds == running.startMicroseconds,
                    "Replacement lost the mapped process's original signing identity or start time")
        var recycled = stale
        recycled.startSeconds += 1
        try require(!WidgetExtensionLifecycle.retire(recycled, current: updated, executable: executable.path),
                    "Lifecycle accepted a different process start time")
        try require(WidgetExtensionLifecycle.retire(stale, current: updated, executable: executable.path),
                                "Mapped old executable survived replacement at the same path")
        try await wait("Retired widget process did not exit") { !process.isRunning }
        print("PASS Widget process integration: current executable survives; mapped old executable retires after atomic replacement")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "WidgetChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private static func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try require(ContinuousClock.now < deadline, message)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
