import AppKit
import CryptoKit

/// Optional launch evidence from the same dashboard in normal and review modes.
/// Does not create windows, change layout, or initialize fixtures in normal use.
@MainActor enum AppLaunchReceipt {
    static var requested: Bool { CommandLine.arguments.contains("--review-launch-token") }
    static let executableSHA256: String = {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url) else { return "unavailable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }()
    static var buildID: String {
        let commit = Bundle.main.object(forInfoDictionaryKey: "UsageSourceCommit") as? String ?? "unknown"
        return "\(commit.prefix(7))-\(executableSHA256.prefix(12))"
    }
    private static var recorded = false
    private static var scheduled = false

    static func record(_ window: NSWindow) {
        guard requested, !recorded, !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak window] in
            defer { scheduled = false }
            for _ in 0..<250 {
                guard let window else { return }
                if window.identifier?.rawValue == "dashboard", window.toolbar != nil, window.alphaValue == 1 {
                    write(window)
                    return
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            fputs("App launch receipt: dashboard has not finished its native toolbar layout.\n", stderr)
        }
    }

    private static func write(_ window: NSWindow) {
        let args = CommandLine.arguments
        func value(_ option: String) -> String? {
            guard let index = args.firstIndex(of: option), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        guard let token = value("--review-launch-token"), let directory = value("--review-report-dir") else { return }
        let receipt: [String: Any] = [
            "token": token, "pid": ProcessInfo.processInfo.processIdentifier,
            "executable": Bundle.main.executableURL!.resolvingSymlinksInPath().path,
            "executableSHA256": executableSHA256, "build": buildID,
            "bundleID": Bundle.main.bundleIdentifier ?? "", "appRoot": true,
            "review": ManualReviewController.active != nil,
            "toolbarControls": window.toolbar!.items.compactMap(\.view).count,
            "titlebarHeight": window.frame.height - window.contentLayoutRect.height,
            "alpha": window.alphaValue
        ]
        do {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("launch.json")
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: url, options: .atomic)
            recorded = true
            print("APP Ready: \(buildID); review=\(ManualReviewController.active != nil)")
        } catch {
            fputs("Cannot record app launch: \(error)\n", stderr)
            exit(1)
        }
    }
}
