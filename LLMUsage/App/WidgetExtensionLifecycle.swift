import Foundation
import CoreServices
import Security
import WidgetKit
import OSLog
import Darwin

/// WidgetKit can keep a mapped executable alive across bundle replacement. A
/// timeline from that executable is rejected when its bundle stub has the old
/// version, even though the provider successfully read the new snapshot files.
enum WidgetExtensionLifecycle {
    struct Identity: Equatable, Sendable {
        var identifier: String
        var digest: Data
    }
    struct FileIdentity: Equatable, Sendable {
        var device: UInt64
        var inode: UInt64
    }
    private struct LoadedExecutable {
        var path: String
        var file: FileIdentity
    }
    struct ProcessIdentity: Equatable, Sendable {
        var pid: pid_t
        var path: String
        var code: Identity
        var staticCodeChanged = false
        var startSeconds: UInt64 = 0
        var startMicroseconds: UInt64 = 0
        var loadedFile: FileIdentity? = nil
    }
    struct HostIdentity: Equatable {
        var pid: pid_t
        var startSeconds: UInt64
        var startMicroseconds: UInt64
    }
    struct CachedJob: Equatable {
        var identifier: String
        var executable: String
    }
    static let hostExecutable = "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/chronod"
    private static let logger = Logger(subsystem: "local.ClaudeUsage", category: "WidgetLifecycle")

    static func shouldRetire(_ process: ProcessIdentity, current: Identity, executable: String) -> Bool {
        process.pid > 1 && process.pid != getpid() && process.code.identifier == current.identifier
            && (process.staticCodeChanged || canonicalPath(process.path) != canonicalPath(executable)
                || process.code.digest != current.digest)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Called on every launch, including the first launch after Sparkle or Finder
    /// replaces the app. Never resets the user's widgets or the global LS database.
    static func reconcile(bundleURL: URL = Bundle.main.bundleURL) async {
        await Task.detached(priority: .utility) {
            let extensionURL = bundleURL.appendingPathComponent("Contents/PlugIns/LLMUsageWidget.appex")
            guard let bundle = Bundle(url: extensionURL), let identifier = bundle.bundleIdentifier,
                  let executable = bundle.executableURL,
                  let current = staticIdentity(at: extensionURL), current.identifier == identifier else { return }
            let status = LSRegisterURL(bundleURL as CFURL, true)
            guard status == noErr else {
                logger.error("Widget host registration failed: \(status)")
                return
            }
            // Terminating an old extension is insufficient when launchd retained
            // its old path inside chronod's private domain. Only a confirmed stale
            // job belonging to this widget permits restarting the shared host.
            let recoveryKey = "widgetHostRecovery.\(identifier)"
            var recoveredHost = false
            if recoveryAllowed(lastRecovery: UserDefaults.standard.object(forKey: recoveryKey) as? Date, now: Date()) {
                for host in processIDs().compactMap(hostIdentity) {
                    if await recoverHost(host, identifier: identifier, executable: executable.path) {
                        UserDefaults.standard.set(Date(), forKey: recoveryKey)
                        recoveredHost = true
                        // Let normal termination finish; never escalate to SIGKILL.
                        for _ in 0..<40 {
                            guard hostIdentity(host.pid) == host, !Task.isCancelled else { break }
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        break
                    }
                }
            }
            var retiring: [ProcessIdentity] = []
            for process in processIDs().compactMap({ processIdentity($0, expectedExecutable: executable.path) }) where shouldRetire(process, current: current, executable: executable.path) {
                if retire(process, current: current, executable: executable.path) { retiring.append(process) }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !retiring.isEmpty && ContinuousClock.now < deadline {
                retiring.removeAll { processIdentity($0.pid, expectedExecutable: executable.path) != $0 }
                if !retiring.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            }
            logger.notice("Registered widget host; version=\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?", privacy: .public), stillRetiring=\(retiring.count), recoveredHost=\(recoveredHost)")
            WidgetCenter.shared.reloadAllTimelines()
        }.value
    }

    static func recoveryAllowed(lastRecovery: Date?, now: Date) -> Bool {
        guard let lastRecovery else { return true }
        // Prevent repeated host restarts across rapid app launches. A corrected
        // system clock must not disable recovery indefinitely.
        return now < lastRecovery || now.timeIntervalSince(lastRecovery) >= 300
    }

    /// launchctl's diagnostic format is not a stable API. Unknown, partial or
    /// ambiguous output must fail closed, without touching any system process.
    static func cachedJob(_ output: String, hostPID: pid_t, identifier: String) -> CachedJob? {
        let lines = output.components(separatedBy: .newlines)
        guard lines.first == "pid/\(hostPID)/\(identifier) = {",
              lines.last(where: { !$0.isEmpty }) == "}", lines.filter({ $0 == "}" }).count == 1 else { return nil }
        func field(_ name: String) -> String? {
            let prefix = "\t\(name) = "
            let values = lines.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            return values.count == 1 ? values[0] : nil
        }
        guard field("type") == "Extension", field("bundle id") == identifier,
              field("extension point") == "com.apple.widgetkit-extension",
              let bundlePath = field("path"), bundlePath.hasPrefix("/"), bundlePath.hasSuffix("/LLMUsageWidget.appex"),
              let program = field("program"), program == bundlePath + "/Contents/MacOS/LLMUsageWidget" else { return nil }
        return CachedJob(identifier: identifier, executable: program)
    }

    static func readCachedJob(_ host: HostIdentity, identifier: String) async -> CachedJob? {
        guard identifier.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil else { return nil }
        guard let output = try? await ProcessRunner(timeout: 3, maximumBytes: 65_536).run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "pid/\(host.pid)/\(identifier)"]) else { return nil }
        return cachedJob(String(decoding: output.stdout, as: UTF8.self), hostPID: host.pid, identifier: identifier)
    }

    static func hostIdentity(_ pid: pid_t) -> HostIdentity? {
        guard pid > 1, pid != getpid() else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
              info.pbi_uid == getuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              canonicalPath(String(cString: path)) == hostExecutable else { return nil }
        // The executable is Apple's SIP-protected system binary. Keep the start
        // timestamp as well as the PID so a recycled PID cannot pass revalidation.
        return HostIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    /// The injected observations make races testable without restarting WidgetKit
    /// during review. Production re-reads the own job and host before SIGTERM.
    static func recoverHost(_ host: HostIdentity, identifier: String, executable: String,
                            identify: (pid_t) -> HostIdentity? = hostIdentity,
                            inspect: (HostIdentity, String) async -> CachedJob? = readCachedJob,
                            terminate: (pid_t) -> Bool = { kill($0, SIGTERM) == 0 }) async -> Bool {
        guard identify(host.pid) == host,
              let job = await inspect(host, identifier), job.identifier == identifier,
              canonicalPath(job.executable) != canonicalPath(executable),
              identify(host.pid) == host,
              await inspect(host, identifier) == job,
              identify(host.pid) == host, !Task.isCancelled else { return false }
        return terminate(host.pid)
    }

    private static func identity(_ code: SecStaticCode) -> Identity? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let digest = values[kSecCodeInfoUnique as String] as? Data else { return nil }
        return Identity(identifier: identifier, digest: digest)
    }

    static func staticIdentity(at url: URL) -> Identity? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return identity(code)
    }

    static func processIdentity(_ pid: pid_t, expectedExecutable: String? = nil) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
              info.pbi_uid == getuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) == 0 {
            let name = withUnsafePointer(to: &info.pbi_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            guard name == "LLMUsageWidget", let expectedExecutable,
                  let loaded = loadedExecutable(pid),
                  belongsToUpdate(loaded.path, executable: expectedExecutable) else { return nil }
            return replacedProcess(pid, info: info, executable: expectedExecutable, loaded: loaded)
        }
        let executable = String(cString: path)
        guard executable.hasSuffix("/LLMUsageWidget.appex/Contents/MacOS/LLMUsageWidget") else { return nil }
        var guest: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid, kSecGuestAttributeDynamicCode: true] as CFDictionary, [], &guest)
        if guestStatus != errSecSuccess || guest == nil {
            // Sparkle can move/delete the old image, making Security unable to
            // resolve its origin. Restrict this fallback to our exact launch
            // path and UID, and require kernel evidence of a replaced file.
            guard executable == expectedExecutable, let loaded = loadedExecutable(pid) else { return nil }
            return replacedProcess(pid, info: info, executable: executable, loaded: loaded)
        }
        guard let guest else { return nil }
        // CopyStaticCode/CopySigningInformation can read the replacement from
        // disk. Dynamic validation is what detects the still-running old image.
        let validity = SecCodeCheckValidity(guest, [], nil)
        guard validity == errSecSuccess || validity == errSecCSStaticCodeChanged else { return nil }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code,
              let identity = identity(code) else { return nil }
        return ProcessIdentity(pid: pid, path: executable, code: identity,
            staticCodeChanged: validity == errSecCSStaticCodeChanged,
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    private static func replacedProcess(_ pid: pid_t, info: proc_bsdinfo, executable: String,
                                        loaded: LoadedExecutable) -> ProcessIdentity? {
        guard let disk = fileIdentity(executable), loaded.file != disk,
              let code = staticIdentity(at: URL(fileURLWithPath: executable)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) else { return nil }
        return .init(pid: pid, path: loaded.path, code: code, staticCodeChanged: true,
                     startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec, loadedFile: loaded.file)
    }

    static func belongsToUpdate(_ path: String, executable: String) -> Bool {
        if path == executable { return true }
        let extensionURL = URL(fileURLWithPath: executable).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let hostURL = extensionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let identifier = Bundle(url: hostURL)?.bundleIdentifier,
              let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return false }
        let installation = cache.appendingPathComponent(identifier)
            .appendingPathComponent("org.sparkle-project.Sparkle/Installation").standardizedFileURL.path + "/"
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(installation)
            && path.hasSuffix("/" + hostURL.lastPathComponent + "/Contents/PlugIns/LLMUsageWidget.appex/Contents/MacOS/LLMUsageWidget")
    }

    private static func fileIdentity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return .init(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino)
    }

    /// Reads mapping metadata only, never the process's memory or user content.
    private static func loadedExecutable(_ pid: pid_t) -> LoadedExecutable? {
        var address: UInt64 = 0
        for _ in 0..<32 {
            var region = proc_regionwithpathinfo()
            guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &region,
                               Int32(MemoryLayout.size(ofValue: region))) == MemoryLayout.size(ofValue: region) else { return nil }
            let path = withUnsafePointer(to: &region.prp_vip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let file = region.prp_vip.vip_vi.vi_stat
            if path.hasSuffix("/LLMUsageWidget.appex/Contents/MacOS/LLMUsageWidget"), file.vst_ino != 0 {
                return .init(path: path, file: .init(device: UInt64(file.vst_dev), inode: file.vst_ino))
            }
            let (next, overflow) = region.prp_prinfo.pri_address.addingReportingOverflow(region.prp_prinfo.pri_size)
            guard !overflow, next > address else { return nil }
            address = next
        }
        return nil
    }

    @discardableResult
    static func retire(_ process: ProcessIdentity, current: Identity, executable: String) -> Bool {
        guard shouldRetire(process, current: current, executable: executable),
              let verified = processIdentity(process.pid, expectedExecutable: executable), verified == process,
              shouldRetire(verified, current: current, executable: executable) else { return false }
        return kill(process.pid, SIGTERM) == 0
    }

    private static func processIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(0, min(Int(actual), pids.count))))
    }
}
