import Foundation
import Darwin

enum SharedConfiguration {
    // Stable OS identities preserve existing widgets, app-group access and user preferences.
    static let widgetKind = "ClaudeUsageWidget"
    static let sessionsWidgetKind = "LLMUsageSessionsWidget"
    static let trendWidgetKind = "LLMUsageTrendWidget"
    static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "UsageAppGroup") as? String ?? "group.local.ClaudeUsage"
    }
    static var usesLocalWidgetStorage: Bool {
        Bundle.main.object(forInfoDictionaryKey: "UsageWidgetStorageMode") as? String == "local-files"
    }
    static var container: URL? {
        if usesLocalWidgetStorage {
            guard let path = Bundle.main.object(forInfoDictionaryKey: "UsageLocalWidgetDataPath") as? String,
                  path.hasPrefix("Library/Application Support/"),
                  !path.split(separator: "/").contains("..") else { return nil }
            return userHomeDirectory?.appendingPathComponent(path, isDirectory: true)
        }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    // Foundation redirects the home directory into the extension's sandbox. The
    // local build's exact-file read entitlements refer to the user's actual home.
    private static let userHomeDirectory: URL? = {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        return buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(getuid(), &entry, bytes.baseAddress, bytes.count, &result) == 0,
                  result != nil, let path = entry.pw_dir else { return nil }
            return URL(fileURLWithFileSystemRepresentation: path, isDirectory: true, relativeTo: nil)
        }
    }()
}

struct RefreshStatus: Codable, Equatable, Sendable {
    var attemptedAt: Date
    var message: String?
    var refreshMinutes: Int
    var dailyBudget: Double? = nil
    var dataContext: UsageDataContext? = nil
    var interfaceLanguage: InterfaceLanguage? = nil
    var refreshIntervalSeconds: TimeInterval? = nil
    var modelExclusionPolicy: ModelExclusionPolicy? = nil
    // Optional presentation preferences can be added here without changing the snapshot schema.

    var refreshInterval: TimeInterval {
        if let seconds = refreshIntervalSeconds, seconds.isFinite, seconds > 0 { return seconds }
        return refreshMinutes > 0 ? Double(refreshMinutes) * 60 : 180
    }
}

protocol SnapshotPersisting: Sendable {
    func read(_ slot: SnapshotSlot) async throws -> UsageSnapshot?
    func write(_ snapshot: UsageSnapshot, to slot: SnapshotSlot) async throws
    func writeStatus(_ status: RefreshStatus) async throws
    func readStatus() async throws -> RefreshStatus?
    func readHistory() async throws -> UsageHistory?
    func writeHistory(_ history: UsageHistory) async throws
}

enum SnapshotSlot: String, Sendable {
    // Rebuild the cache after expanding scope; a Claude-only snapshot is not an all-source total.
    case today = "latest-usage-v2.json"
    case yesterday = "previous-day-usage-v2.json"
}

// Atomic file replacement means the extension never observes a half-written JSON document.
// The actor keeps all filesystem work off the main actor.
actor SnapshotRepository: SnapshotPersisting {
    private let directory: URL?
    init(directory: URL? = SharedConfiguration.container) { self.directory = directory }

    func read(_ slot: SnapshotSlot) throws -> UsageSnapshot? {
        try SnapshotFiles.read(slot, directory: directory)
    }
    func write(_ snapshot: UsageSnapshot, to slot: SnapshotSlot) throws {
        try SnapshotFiles.write(snapshot, name: slot.rawValue, directory: directory)
    }
    func readStatus() throws -> RefreshStatus? { try SnapshotFiles.status(directory: directory) }
    func readHistory() throws -> UsageHistory? { try SnapshotFiles.history(directory: directory) }
    func writeHistory(_ history: UsageHistory) throws {
        try SnapshotFiles.write(history, name: "daily-history-v1.json", directory: directory)
    }
    func writeStatus(_ status: RefreshStatus) throws {
        try SnapshotFiles.write(status, name: "refresh-status.json", directory: directory)
    }
}

enum SnapshotFiles {
    static func read(_ slot: SnapshotSlot, directory: URL?) throws -> UsageSnapshot? {
        let snapshot: UsageSnapshot? = try readValue(name: slot.rawValue, directory: directory)
        guard snapshot == nil || snapshot?.schemaVersion == 2 else {
            throw UsageError.sharedContainer("Unsupported snapshot schema version")
        }
        if let snapshot {
            guard validDay(snapshot.day),
                  snapshot.dataContext == nil || snapshot.dataContext?.timezone == snapshot.day.timezone,
                  Set(snapshot.sessions.map(\.id)).count == snapshot.sessions.count,
                  snapshot.sessions.count <= 100_000,
                  snapshot.sessions.allSatisfy({ session in
                      !session.id.isEmpty && validUsage(session.usage, limit: 5_000_000_000_000, costLimit: 1e12)
                          && session.modelBreakdowns.count <= 100_000
                          && session.modelBreakdowns.allSatisfy { validUsage($0.usage, limit: 5_000_000_000_000, costLimit: 1e12) }
                          && (0...1_000_000_000_000).contains(session.reasoningOutputTokens ?? 0)
                  }) else { throw UsageError.sharedContainer("Invalid values in saved snapshot") }
        }
        return snapshot
    }
    static func status(directory: URL?) throws -> RefreshStatus? {
        try readValue(name: "refresh-status.json", directory: directory)
    }
    static func history(directory: URL?) throws -> UsageHistory? {
        let history: UsageHistory? = try readValue(name: "daily-history-v1.json", directory: directory)
        if let history {
            guard history.schemaVersion == 1, TimeZone(identifier: history.context.timezone) != nil,
                  history.days.count <= 7, Set(history.days.map(\.id)).count == history.days.count,
                  history.days.allSatisfy({ item in
                      validDay(item.day) && item.day.timezone == history.context.timezone
                          && (0...100_000).contains(item.sessionCount)
                          && validUsage(item.usage, limit: dailyTokenLimit, costLimit: 1e17)
                          && item.reportedUsage.map { validUsage($0, limit: dailyTokenLimit, costLimit: 1e17) } != false
                          && validComponents(item.usageComponents)
                  }) else { throw UsageError.sharedContainer("Invalid saved daily history") }
        }
        return history
    }

    // CLI limits permit at most 100,000 sessions of 5e12 tokens per day.
    // Bound the sum as well as each bucket, keeping a seven-day sum within Int64.
    private static let dailyTokenLimit: Int64 = 500_000_000_000_000_000

    private static func validDay(_ day: UsageDay) -> Bool {
        TimeZone(identifier: day.timezone) != nil && day == UsageDay(date: day.date, timezone: day.timezone)
    }

    private static func validUsage(_ usage: TokenUsage, limit: Int64, costLimit: Double) -> Bool {
        func amounts(_ value: TokenUsage) -> Bool {
            guard value.cost.isFinite, (0...costLimit).contains(value.cost) else { return false }
            var remaining = limit
            for count in [value.input, value.output, value.cacheCreate, value.cacheRead, value.additional ?? 0] {
                guard count >= 0, count <= remaining else { return false }
                remaining -= count
            }
            return true
        }
        // Exclusions restore reportedAmounts before computing any totals.
        return amounts(usage) && amounts(usage.reported)
    }

    private static func validComponents(_ components: [ModelUsageComponent]?) -> Bool {
        guard let components else { return true } // Legacy history is rebuilt by the store.
        var remaining = dailyTokenLimit
        for component in components {
            guard validUsage(component.reportedUsage, limit: remaining, costLimit: 1e17) else { return false }
            remaining -= max(component.reportedUsage.total, component.reportedUsage.reported.total)
        }
        return true
    }
    private static func readValue<T: Decodable>(name: String, directory: URL?) throws -> T? {
        guard let directory else { throw UsageError.sharedContainer(SharedConfiguration.appGroup) }
        let url = directory.appendingPathComponent(name)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch { throw UsageError.sharedContainer(String(describing: error)) }
    }
    static func write<T: Encodable>(_ value: T, name: String, directory: URL?) throws {
        guard let directory else { throw UsageError.sharedContainer(SharedConfiguration.appGroup) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let destination = directory.appendingPathComponent(name)
            try encoder.encode(value).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch { throw UsageError.sharedContainer(String(describing: error)) }
    }
}
