import Foundation
import CryptoKit

struct CCUsageManifest: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var version: String
    var contractVersion: Int
    var architecture: String
    var binarySHA256: String

    // The Swift accounting stage changes totals independently of the helper.
    var engineID: String { "ccusage/\(version)/contract-\(contractVersion)/telemetry-accounting-1" }
    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "CCUsageRuntime", withExtension: "json") else {
            throw UsageError.runtimeUnavailable
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1, value.contractVersion == 3,
              value.architecture == "arm64", value.binarySHA256.count == 64,
              value.binarySHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw UsageError.runtimeUnavailable
        }
        return value
    }
    static let bundled = try? load()
}

enum RuntimeConsent {
    static let key = "bundledCCUsageConsent.v1"
    private static let setupPresentedKey = "bundledCCUsageSetupPresented.v1"
    static func isGranted(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }

    /// Remember the introduction separately from permission to execute the helper.
    /// Dismissing it never grants consent and never prompts again on a later launch.
    static func takeFirstLaunchPrompt(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: setupPresentedKey) else { return false }
        defaults.set(true, forKey: setupPresentedKey)
        // Existing users who already consented have also completed the introduction.
        return !isGranted(defaults: defaults)
    }
}

/// One immutable executable per app bundle, shared by reports and transcript pricing.
/// Leases cover the whole calculation, including the two concurrent CLI reports.
actor CCUsageRuntime {
    static let shared = CCUsageRuntime()
    private let executable: URL?
    private let manifest: CCUsageManifest?
    private let authorized: @Sendable () -> Bool
    private var suspended = false
    private var active = 0

    init(executable: URL? = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ccusage"),
         manifest: CCUsageManifest? = .bundled,
         authorized: @escaping @Sendable () -> Bool = { RuntimeConsent.isGranted() }) {
        self.executable = executable
        self.manifest = manifest
        self.authorized = authorized
    }

    func withExecutable<T: Sendable>(_ operation: @Sendable (URL) async throws -> T) async throws -> T {
        guard authorized() else { throw UsageError.runtimeConsentRequired }
        guard !suspended else { throw UsageError.maintenanceInProgress }
        active += 1
        defer { active -= 1 }
        guard let executable, let manifest else { throw UsageError.runtimeUnavailable }
        try Self.verify(executable, manifest: manifest)
        let output = try await ProcessRunner(timeout: 10, maximumBytes: 16_384)
            .run(executable: executable, arguments: ["--version"], environment: Self.environment())
        guard String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            == "ccusage \(manifest.version)" else { throw UsageError.runtimeUnavailable }
        try Task.checkCancellation()
        guard authorized(), !suspended else { throw UsageError.maintenanceInProgress }
        return try await operation(executable)
    }

    static func verify(_ executable: URL, manifest: CCUsageManifest) throws {
        let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0, (values.fileSize ?? 0) < 64 * 1_024 * 1_024,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw UsageError.runtimeUnavailable }
        let digest = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.binarySHA256 else { throw UsageError.runtimeUnavailable }
    }

    /// Keep user data/configuration locations, but do not resolve executable wrappers.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("DYLD_") || key.hasPrefix("LD_") || key == "NODE_OPTIONS" {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["NO_COLOR"] = "1"
        return environment
    }

    func suspendAndWait(timeout: TimeInterval = 120) async throws {
        suspended = true
        let start = ProcessInfo.processInfo.systemUptime
        do {
            while active > 0 {
                guard ProcessInfo.processInfo.systemUptime - start < timeout else { throw UsageError.timedOut }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch { suspended = false; throw error }
    }
    func resume() { suspended = false }
}
