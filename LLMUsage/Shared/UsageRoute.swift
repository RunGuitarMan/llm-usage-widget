import Foundation

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "Обзор", sessions = "Сессии", models = "Модели", settings = "Настройки"
    var id: String { rawValue }
    var title: String { L10n.key(rawValue) }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .sessions: return "list.bullet"
        case .models: return "cube"
        case .settings: return "gearshape"
        }
    }
}

enum UsageRoute: Equatable {
    case overview, sessions, session(String), settings
    case datedSessions(UsageDay), datedSession(String, UsageDay)
    init?(url: URL) {
        guard ["llmusage", "claudeusage"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.port == nil,
              url.password == nil, url.fragment == nil else { return nil }
        let day: UsageDay?
        if url.query != nil {
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.count == 2, Set(items.map(\.name)) == ["day", "timezone"],
                  let key = items.first(where: { $0.name == "day" })?.value,
                  key.count == 8, key.utf8.allSatisfy({ (48...57).contains($0) }),
                  let timezone = items.first(where: { $0.name == "timezone" })?.value,
                  let zone = TimeZone(identifier: timezone) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = zone
            formatter.dateFormat = "yyyyMMdd"
            formatter.isLenient = false
            guard let date = formatter.date(from: key) else { return nil }
            let parsed = UsageDay(date: date, timezone: timezone)
            guard parsed.key == key else { return nil }
            day = parsed
        } else { day = nil }
        switch url.host {
        case "overview" where day == nil && (url.path.isEmpty || url.path == "/"): self = .overview
        case "sessions" where url.path.isEmpty || url.path == "/": self = day.map(Self.datedSessions) ?? .sessions
        case "settings" where day == nil && (url.path.isEmpty || url.path == "/"): self = .settings
        case "session":
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 1, !parts[0].isEmpty else { return nil }
            self = day.map { .datedSession(parts[0], $0) } ?? .session(parts[0])
        default: return nil
        }
    }
    var url: URL {
        switch self {
        case .overview: return URL(string: "llmusage://overview")!
        case .sessions: return URL(string: "llmusage://sessions")!
        case .settings: return URL(string: "llmusage://settings")!
        case .session(let id): return URL(string: "llmusage://session")!.appendingPathComponent(id)
        case .datedSessions(let day): return Self.withDay(day, url: Self.sessions.url)
        case .datedSession(let id, let day): return Self.withDay(day, url: Self.session(id).url)
        }
    }
    private static func withDay(_ day: UsageDay, url: URL) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "day", value: day.key), .init(name: "timezone", value: day.timezone)]
        return parts.url!
    }
}
