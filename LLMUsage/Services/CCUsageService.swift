import Foundation
import Darwin

struct ProcessOutput: Sendable {
    var stdout: Data
    var stderr: String
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct ProcessRunner: Sendable {
    var timeout: TimeInterval = 60
    var maximumBytes = 32 * 1_024 * 1_024

    func run(executable: URL, arguments: [String], environment: [String: String]? = nil) async throws -> ProcessOutput {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                try runBlocking(executable: executable, arguments: arguments, environment: environment, flag: flag)
            }.value
        }, onCancel: { flag.cancel() })
    }

    private func runBlocking(executable: URL, arguments: [String], environment: [String: String]?, flag: CancellationFlag) throws -> ProcessOutput {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("llmusage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? Self.environment(for: executable)
        process.standardInput = FileHandle.nullDevice
        // Files, rather than undrained pipes, avoid deadlocks with verbose CLI output.
        process.standardOutput = output
        process.standardError = error
        do { try process.run() }
        catch { throw UsageError.processFailed(-1, error.localizedDescription) }
        // Foundation normally gives the command its own process group. Retain
        // that identity while it is alive; never signal the app's process group.
        let processGroup = getpgid(process.processIdentifier) == process.processIdentifier ? process.processIdentifier : nil
        let start = ProcessInfo.processInfo.systemUptime
        var failure: Error?
        while process.isRunning {
            if flag.isCancelled { failure = CancellationError(); break }
            if ProcessInfo.processInfo.systemUptime - start > timeout { failure = UsageError.timedOut; break }
            let outputSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let errorSize = (try? errorURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if outputSize + errorSize > maximumBytes { failure = UsageError.outputTooLarge; break }
            Thread.sleep(forTimeInterval: 0.025)
        }
        if let failure {
            if process.isRunning { process.terminate() }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            // terminate() signals the group, but a wrapper or child can ignore
            // SIGTERM. Escalate the same isolated group, including descendants
            // left behind by a wrapper that has already exited.
            if let processGroup { kill(-processGroup, SIGKILL) }
            else if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw failure
        }
        process.waitUntilExit()
        if flag.isCancelled { throw CancellationError() }
        let errorReader = try FileHandle(forReadingFrom: errorURL)
        defer { try? errorReader.close() }
        let stderr = String(decoding: try errorReader.read(upToCount: 16_384) ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw UsageError.processFailed(process.terminationStatus, stderr) }
        let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw UsageError.outputTooLarge }
        let data = try Data(contentsOf: outputURL)
        guard data.count <= maximumBytes else { throw UsageError.outputTooLarge }
        return .init(stdout: data, stderr: stderr)
    }

    static func environment(for executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // GUI apps have a minimal PATH. In particular, npm's #!/usr/bin/env node must resolve.
        let paths = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                     "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (paths + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["NO_COLOR"] = "1"
        return environment
    }
}

actor CCUsageExecutableResolver {
    private var cached: URL?
    private var attemptedShell = false

    func resolve(customPath: String, force: Bool = false) async throws -> URL {
        if !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let path = (customPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), isExecutable(path) else { throw UsageError.invalidPath(path) }
            return URL(fileURLWithPath: path)
        }
        if force { cached = nil; attemptedShell = false }
        if let cached, isExecutable(cached.path) { return cached }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["/opt/homebrew/bin/ccusage", "/usr/local/bin/ccusage", "\(home)/.local/bin/ccusage",
                          "\(home)/.bun/bin/ccusage", "\(home)/.npm-global/bin/ccusage", "\(home)/.volta/bin/ccusage",
                          "\(home)/Library/pnpm/ccusage"]
        let nvm = URL(fileURLWithPath: "\(home)/.nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil)) ?? []
        candidates += versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/ccusage").path }
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { String($0) + "/ccusage" }
        if let path = candidates.first(where: isExecutable) {
            let result = URL(fileURLWithPath: path)
            cached = result
            return result
        }
        if !attemptedShell {
            attemptedShell = true
            // Fixed script only. User input never enters a shell command string.
            let output = try? await ProcessRunner(timeout: 5).run(executable: URL(fileURLWithPath: "/bin/zsh"),
                                                                 arguments: ["-lc", "command -v ccusage"])
            let lines = output.map { String(decoding: $0.stdout, as: UTF8.self).split(separator: "\n") } ?? []
            if let path = lines.map(String.init).last(where: { $0.hasPrefix("/") && isExecutable($0) }) {
                let result = URL(fileURLWithPath: path)
                cached = result
                return result
            }
        }
        throw UsageError.missingExecutable
    }

    private func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}

struct CLIDiagnostics: Sendable {
    var path: String
    var version: String
}

protocol CCUsageServing: Sendable {
    var engineID: String? { get }
    func fetch(day: UsageDay, customPath: String, mode: UsageUpdateMode) async throws -> UsageSnapshot
    func diagnose(customPath: String, forceDetect: Bool) async throws -> CLIDiagnostics
}

extension CCUsageServing { var engineID: String? { nil } }

struct CCUsageService: CCUsageServing {
    var runtime: CCUsageRuntime? = .shared
    var engineID: String? { runtime == nil ? nil : CCUsageManifest.bundled?.engineID }
    let resolver = CCUsageExecutableResolver()
    let runner = ProcessRunner()
    var pricing: any ClaudePricingProviding = ClaudePricingCache(includeTranscriptModels: true)
    var pricingArchive = TranscriptPricingArchive()
    // Test seam for isolated real-helper checks; production inherits its runtime environment.
    var environment: [String: String]?

    private func executionEnvironment(for executable: URL) -> [String: String] {
        environment ?? (runtime == nil ? ProcessRunner.environment(for: executable) : CCUsageRuntime.environment())
    }

    static func arguments(for day: UsageDay, report: CCUsageDecoder.Report) -> [String] {
        // Explicitly override offline defaults in the user's ccusage config.
        // Cached transcript-model overrides survive network failures; the CLI
        // still owns calculation rules and fallback model pricing.
        let command = report == .claude ? ["claude", "session", "--json"] : ["session", "--json", "--all"]
        return command + ["--since", day.key, "--until", day.key,
                          "--timezone", day.timezone, "--mode", "calculate", "--order", "desc", "--no-offline"]
    }
    func fetch(day: UsageDay, customPath: String, mode: UsageUpdateMode = .claudeOnly) async throws -> UsageSnapshot {
        if let runtime {
            return try await runtime.withExecutable { executable in
                try await fetch(day: day, mode: mode, executable: executable)
            }
        }
        return try await fetch(day: day, mode: mode, executable: try await resolver.resolve(customPath: customPath))
    }
    private func fetch(day: UsageDay, mode: UsageUpdateMode, executable: URL) async throws -> UsageSnapshot {
        let prices = try await pricing.refresh()
        try Task.checkCancellation()
        let configurationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("llmusage-pricing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: configurationDirectory) }
        var pricingArguments: [String] = []
        let contents = try CCUsagePricingConfiguration.contents(prices: prices, environment: executionEnvironment(for: executable))
        let pricingKey = try? pricingArchive.save(configuration: contents, environment: executionEnvironment(for: executable), engineID: engineID)
        if !prices.isEmpty {
            try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let configuration = configurationDirectory.appendingPathComponent("ccusage.json")
            try contents.write(to: configuration, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
            pricingArguments = ["--config", configuration.path]
        }
        let extraArguments = pricingArguments
        async let claude = fetchReport(.claude, day: day, executable: executable, extraArguments: extraArguments)
        guard mode == .allAgents else {
            let focused = try await claude
            var result = try await ClaudeAccountingService(environment: executionEnvironment(for: executable))
                .reconcile(focused, executable: executable, configuration: contents)
            result.pricingKey = pricingKey
            return result
        }

        async let unified = fetchReport(.unified, day: day, executable: executable, extraArguments: extraArguments)
        let (rawFocused, combined) = try await (claude, unified)
        let focused = try await ClaudeAccountingService(environment: executionEnvironment(for: executable))
            .reconcile(rawFocused, executable: executable, configuration: contents)
        // ccusage 20.0.24/26 filters whole Claude sessions by lastActivity in the
        // unified report. The focused command filters entries before summing.
        // Always replace Claude, including when its focused report is empty.
        let sessions = combined.sessions.filter { $0.sourceID != "claude" } + focused.sessions
        guard sessions.count <= 100_000 else { throw UsageError.outputTooLarge }
        return .init(generatedAt: Date(), day: day, sessions: sessions, pricingKey: pricingKey)
    }
    private func fetchReport(_ report: CCUsageDecoder.Report, day: UsageDay, executable: URL, extraArguments: [String]) async throws -> UsageSnapshot {
        let result = try await runner.run(executable: executable, arguments: Self.arguments(for: day, report: report) + extraArguments, environment: executionEnvironment(for: executable))
        return try CCUsageDecoder.decode(result.stdout, day: day, report: report)
    }
    func diagnose(customPath: String, forceDetect: Bool = false) async throws -> CLIDiagnostics {
        if let runtime {
            return try await runtime.withExecutable { executable in
                .init(path: executable.path, version: "ccusage " + (CCUsageManifest.bundled?.version ?? ""))
            }
        }
        let executable = try await resolver.resolve(customPath: customPath, force: forceDetect)
        let result = try await ProcessRunner(timeout: 10).run(executable: executable, arguments: ["--version"])
        return .init(path: executable.path, version: String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
