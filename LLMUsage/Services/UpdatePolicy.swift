import Foundation

enum AppUpdateMode: String, CaseIterable, Identifiable, Sendable {
    case automatic, downloadAndAsk, manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return L10n.text("Скачивать и устанавливать")
        case .downloadAndAsk: return L10n.text("Скачивать и спрашивать")
        case .manual: return L10n.text("Только вручную")
        }
    }
    var automaticallyDownloads: Bool { self != .manual }
    var automaticallyInstalls: Bool { self == .automatic }
}

struct UpdatePreferences: Equatable, Sendable {
    var checksAutomatically = true
    var mode: AppUpdateMode = .automatic
    static func load(_ defaults: UserDefaults) -> Self {
        .init(checksAutomatically: defaults.object(forKey: "appUpdateChecks") as? Bool ?? true,
              mode: AppUpdateMode(rawValue: defaults.string(forKey: "appUpdateMode") ?? "") ?? .automatic)
    }
    func save(_ defaults: UserDefaults) {
        defaults.set(checksAutomatically, forKey: "appUpdateChecks")
        defaults.set(mode.rawValue, forKey: "appUpdateMode")
    }
}
