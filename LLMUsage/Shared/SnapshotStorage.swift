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
        let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        return appGroupDirectory(root: root, bundleIdentifier: Bundle.main.bundleIdentifier,
            channel: Bundle.main.object(forInfoDictionaryKey: "UsageUpdateChannel") as? String)
    }

    static func appGroupDirectory(root: URL?, bundleIdentifier: String?, channel: String?) -> URL? {
        // Preserve the shipped release location. Signed development app/extension
        // pairs use a namespace within the group, just like local-file builds.
        guard channel == "development" else { return root }
        guard let bundleIdentifier, !bundleIdentifier.contains("/"), !bundleIdentifier.contains("..") else { return nil }
        let host = bundleIdentifier.hasSuffix(".Widget") ? String(bundleIdentifier.dropLast(7)) : bundleIdentifier
        return root?.appendingPathComponent(host, isDirectory: true)
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
    var presentation: UsagePresentation? = nil
    var isRecalculating: Bool? = nil
    var publishedAt: Date? = nil
    var hiddenProblems: [String: String]? = nil
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
    private let directoryOverride: URL?
    private let resolvesSharedDirectory: Bool
    private var directory: URL? { resolvesSharedDirectory ? SharedConfiguration.container : directoryOverride }
    init() { directoryOverride = nil; resolvesSharedDirectory = true }
    init(directory: URL?) { directoryOverride = directory; resolvesSharedDirectory = false }

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
        let directory = directory
        try SnapshotFiles.validate(status)
        let widget = status.presentation.map { _ in WidgetPresentation(status: status) }
        try widget?.validate()
        try SnapshotFiles.write(status, name: "refresh-status.json", directory: directory)
        if let widget { try SnapshotFiles.write(widget, name: WidgetPresentation.filename, directory: directory, dateEncoding: .deferredToDate) }
    }
}

enum SnapshotFiles {
    static func read(_ slot: SnapshotSlot, directory: URL?) throws -> UsageSnapshot? {
        let snapshot: UsageSnapshot? = try readValue(name: slot.rawValue, directory: directory)
        try validate(snapshot)
        return snapshot
    }
    private static func validate(_ snapshot: UsageSnapshot?) throws {
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
    }
    static func status(directory: URL?) throws -> RefreshStatus? {
        let status: RefreshStatus? = try readValue(name: "refresh-status.json", directory: directory)
        if let status { try validate(status) }
        return status
    }

    static func validate(_ status: RefreshStatus) throws {
        if let presentation = status.presentation {
            guard presentation.schemaVersion == 1,
                  presentation.failures.count <= 64, presentation.costIssues.count <= 64,
                  presentation.failures.allSatisfy({ validDay($0.day) }),
                  presentation.costIssues.allSatisfy({ validDay($0.day) }) else {
                throw UsageError.sharedContainer("Invalid saved presentation")
            }
            try validate(presentation.snapshot)
            try validate(presentation.previous)
            try validate(presentation.history)
        }
    }

    static func presentation(directory: URL?) throws -> SharedUsageData {
        let status = try status(directory: directory)
        let snapshot: UsageSnapshot?, previous: UsageSnapshot?, history: UsageHistory?
        var storageUnavailable = false
        if let presentation = status?.presentation {
            snapshot = presentation.snapshot
            previous = presentation.previous
            history = presentation.history
        } else {
            snapshot = try read(.today, directory: directory)
            do { previous = try read(.yesterday, directory: directory) }
            catch { previous = nil; storageUnavailable = true }
            do { history = try self.history(directory: directory) }
            catch { history = nil; storageUnavailable = true }
        }
        let policy = status?.modelExclusionPolicy ?? ModelExclusionPolicy()
        func visible(_ data: UsageSnapshot?) -> UsageSnapshot? {
            guard status?.dataContext == nil || status?.dataContext.map({ data?.dataContext?.canDisplay(alongside: $0) == true }) == true else { return nil }
            return data?.applyingExclusions(policy)
        }
        let historyMatches = status?.dataContext.map { history?.context.canDisplay(alongside: $0) == true } ?? true
        let visibleHistory = historyMatches ? history?.applyingExclusions(policy) : nil
        return .init(snapshot: visible(snapshot), previous: visible(previous), history: visibleHistory,
                     status: status, storageUnavailable: storageUnavailable)
    }
    static func history(directory: URL?) throws -> UsageHistory? {
        let history: UsageHistory? = try readValue(name: "daily-history-v1.json", directory: directory)
        try validate(history)
        return history
    }
    private static func validate(_ history: UsageHistory?) throws {
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
    static func readValue<T: Decodable>(name: String, directory: URL?, maximumBytes: Int? = nil, dateDecoding: JSONDecoder.DateDecodingStrategy = .iso8601) throws -> T? {
        guard let directory else { throw UsageError.sharedContainer(SharedConfiguration.appGroup) }
        let url = directory.appendingPathComponent(name)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = dateDecoding
            let data: Data
            if let maximumBytes {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
                guard data.count <= maximumBytes else { throw UsageError.outputTooLarge }
            } else { data = try Data(contentsOf: url) }
            return try decoder.decode(T.self, from: data)
        } catch let error as NSError where
            (error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code))
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
            return nil
        } catch { throw UsageError.sharedContainer(String(describing: error)) }
    }
    static func write<T: Encodable>(_ value: T, name: String, directory: URL?, dateEncoding: JSONEncoder.DateEncodingStrategy = .iso8601) throws {
        guard let directory else { throw UsageError.sharedContainer(SharedConfiguration.appGroup) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = dateEncoding
            encoder.outputFormatting = [.sortedKeys]
            let destination = directory.appendingPathComponent(name)
            let data = try encoder.encode(value)
            // Establish permissions before publishing. A chmod failure after
            // replacement must never turn a successful commit into a failure.
            let temporary = directory.appendingPathComponent(".snapshot-\(UUID().uuidString)")
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch { throw UsageError.sharedContainer(String(describing: error)) }
    }
}

struct SharedUsageData {
    var snapshot: UsageSnapshot?
    var previous: UsageSnapshot?
    var history: UsageHistory?
    var status: RefreshStatus?
    var storageUnavailable = false
}
