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
    struct Identity: Equatable {
        var identifier: String
        var digest: Data
    }
    struct ProcessIdentity {
        var pid: pid_t
        var path: String
        var code: Identity
    }
    private static let logger = Logger(subsystem: "local.ClaudeUsage", category: "WidgetLifecycle")

    static func shouldRetire(_ process: ProcessIdentity, current: Identity, executable: String) -> Bool {
        process.pid > 1 && process.pid != getpid() && process.code.identifier == current.identifier
            && (canonicalPath(process.path) != canonicalPath(executable)
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
            var stopped = 0
            for process in processes() where shouldRetire(process, current: current, executable: executable.path) {
                // Recheck the signing identity and executable immediately before
                // signalling. A recycled PID must never target a different app.
                if retire(process, current: current, executable: executable.path) { stopped += 1 }
            }
            logger.notice("Registered widget host; version=\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?", privacy: .public), retired=\(stopped)")
            WidgetCenter.shared.reloadAllTimelines()
        }.value
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

    static func processIdentity(_ pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
              info.pbi_uid == getuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(cString: path)
        guard executable.hasSuffix("/LLMUsageWidget.appex/Contents/MacOS/LLMUsageWidget") else { return nil }
        var guest: SecCode?
        // Read the code directory retained by the kernel. The default disk-based
        // lookup can fail (or describe the replacement) after an atomic update.
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid, kSecGuestAttributeDynamicCode: true] as CFDictionary, [], &guest) == errSecSuccess,
              let guest else { return nil }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code,
              let identity = identity(code) else { return nil }
        return ProcessIdentity(pid: pid, path: executable, code: identity)
    }

    @discardableResult
    static func retire(_ process: ProcessIdentity, current: Identity, executable: String) -> Bool {
        guard shouldRetire(process, current: current, executable: executable),
              let verified = processIdentity(process.pid), verified.code == process.code,
              verified.path == process.path,
              shouldRetire(verified, current: current, executable: executable) else { return false }
        return kill(process.pid, SIGTERM) == 0
    }

    private static func processes() -> [ProcessIdentity] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(max(0, min(Int(actual), pids.count))).compactMap(processIdentity)
    }
}
