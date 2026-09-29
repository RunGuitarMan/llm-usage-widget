import XCTest
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#else
@testable import LLMUsage
#endif

final class UsageCoreTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-28T18:00:00Z")!
    private func fixture(_ name: String) throws -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testRealEmptyResponse() throws {
        let snapshot = try CCUsageDecoder.decode(fixture("ccusage-20.0.26-empty"), day: UsageDay(date: now))
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertEqual(snapshot.totals, .zero)
    }
    func testJSONNormalizationAndTotals() throws {
        let snapshot = try CCUsageDecoder.decode(fixture("sample-sessions"), day: UsageDay(date: now), now: now)
        XCTAssertEqual(snapshot.sessions.count, 2)
        XCTAssertEqual(snapshot.totals.input, 114)
        XCTAssertEqual(snapshot.totals.output, 45_588)
        XCTAssertEqual(snapshot.totals.cacheCreate, 620_586)
        XCTAssertEqual(snapshot.totals.cacheRead, 7_277_320)
        XCTAssertEqual(snapshot.totals.total, 7_943_608)
        XCTAssertEqual(snapshot.totals.cost, 5.47, accuracy: 0.000001)
        XCTAssertEqual(snapshot.sessions[0].lastActivity, ISO8601DateFormatter().date(from: "2026-09-28T17:02:00Z"))
        XCTAssertEqual(snapshot.modelSummaries.first?.sessionCount, 2)
        XCTAssertEqual(snapshot.modelSummaries.first?.usage, snapshot.totals)
    }
    func testOptionalFieldsAndDateOnly() throws {
        let data = Data(#"{"sessions":[{"sessionId":"abc","lastActivity":"2026-09-28","inputTokens":3}],"newField":true}"#.utf8)
        let snapshot = try CCUsageDecoder.decode(data, day: UsageDay(date: now))
        XCTAssertEqual(snapshot.totals.total, 3)
        XCTAssertFalse(snapshot.sessions[0].activityHasTime)
        XCTAssertNotNil(snapshot.sessions[0].lastActivity)
        XCTAssertEqual(snapshot.sessions[0].modelLabel, L10n.text("Модель неизвестна"))
    }
    func testMalformedOrNegativeDataRejected() {
        for json in ["not json", "{}", #"{"sessions":[{"sessionId":""}]}"#,
                     #"{"sessions":[{"sessionId":"a","inputTokens":-3}]}"#,
                     #"{"sessions":[{"sessionId":"a","totalCost":-2}]}"#,
                     #"{"sessions":[{"sessionId":"a"},{"sessionId":"a"}]}"#] {
            XCTAssertThrowsError(try CCUsageDecoder.decode(Data(json.utf8), day: UsageDay(date: now)), json)
        }
    }
    func testMixedModelsAreNotDoubleCounted() {
        let session = UsageSession(id: "mixed", models: ["a", "b"], usage: .init(input: 100, cost: 2), lastActivity: nil)
        let snapshot = UsageSnapshot(generatedAt: now, day: UsageDay(date: now), sessions: [session])
        XCTAssertEqual(snapshot.modelSummaries.count, 1)
        XCTAssertEqual(snapshot.modelSummaries.reduce(0) { $0 + $1.usage.total }, 100)
    }
    func testModernModelBreakdownAliases() throws {
        let data = Data(#"{"sessions":[{"sessionId":"x","inputTokens":10,"totalCost":1,"modelBreakdowns":[{"model":"opus","inputTokens":10,"totalCost":1}]}]}"#.utf8)
        let snapshot = try CCUsageDecoder.decode(data, day: UsageDay(date: now))
        XCTAssertEqual(snapshot.modelSummaries.first?.id, "opus")
        XCTAssertEqual(snapshot.modelSummaries.first?.usage.cost, 1)
    }
    func testCompactTokenFormatting() {
        let language = L10n.preference; L10n.preference = .english
        defer { L10n.preference = language }
        let examples: [(Int64, String)] = [(0, "0"), (114, "114"), (19_149, "19.1K"), (620_586, "620.6K"),
                                          (7_943_608, "7.94M"), (999_999, "1M")]
        for (value, expected) in examples { XCTAssertEqual(UsageFormat.tokens(value), expected) }
        XCTAssertEqual(UsageFormat.exact(7_943_608), "7,943,608")
    }
    func testCostAndPercentFormatting() {
        let language = L10n.preference; L10n.preference = .english
        defer { L10n.preference = language }
        XCTAssertEqual(UsageFormat.cost(5.47), "$5.47")
        XCTAssertEqual(UsageFormat.cost(0), "$0.00")
        XCTAssertEqual(UsageFormat.cost(-0.0), "$0.00")
        XCTAssertEqual(UsageFormat.percent(0.9125), "91.25%")
        XCTAssertEqual(UsageFormat.percent(0.000001), "<0.01%")
        XCTAssertEqual(UsageFormat.percent(0), "0.00%")
    }
    func testShortID() {
        XCTAssertEqual(UsageFormat.shortID("11111111-1111-4111-8111-111111111111"), "11111111")
        XCTAssertEqual(UsageFormat.shortID("short"), "short")
    }
    func testUTCDayAcrossTimezoneBoundary() {
        let date = ISO8601DateFormatter().date(from: "2026-09-28T23:30:00Z")!
        XCTAssertEqual(UsageDay(date: date).key, "20260928")
        XCTAssertEqual(UsageDay(date: date, timezone: "Europe/Moscow").key, "20260929")
    }
    func testDayArithmeticAcrossDST() {
        let date = ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z")!
        let day = UsageDay(date: date, timezone: "America/New_York")
        XCTAssertEqual(day.end.timeIntervalSince(day.date), 23 * 3600)
        XCTAssertEqual(day.adding(days: -1).key, "20260307")
    }
    func testArgumentsUseJSONUTCAndOnlinePricingWithoutShell() {
        let args = CCUsageService.arguments(for: UsageDay(date: now))
        XCTAssertEqual(args, ["session", "--json", "--all", "--since", "20260928", "--until", "20260928", "--timezone", "UTC", "--mode", "calculate", "--order", "desc", "--no-offline"])
    }
    func testSnapshotEncodeDecode() throws {
        let original = SampleData.snapshot(now: now)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: data), original)
    }
    func testAtomicSharedFileRoundTripAndIndependentSlots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SnapshotRepository(directory: directory)
        let snapshot = SampleData.snapshot(now: now)
        try await repository.write(snapshot, to: .today)
        let stored = try await repository.read(.today)
        XCTAssertEqual(stored, snapshot)
        let previous = try await repository.read(.yesterday)
        XCTAssertNil(previous)
    }
    func testUnavailableContainerIsExplicit() async {
        let repository = SnapshotRepository(directory: nil)
        do { _ = try await repository.read(.today); XCTFail("Expected missing group failure") }
        catch { XCTAssertTrue(error is UsageError) }
    }
    func testDeepLinksRoundTripAndRejectUnexpectedURLs() {
        let routes: [UsageRoute] = [.overview, .sessions, .settings, .session("11111111-1111-4111-8111-111111111111")]
        for route in routes { XCTAssertEqual(UsageRoute(url: route.url), route) }
        for url in ["https://overview", "llmusage://unknown", "llmusage://session", "llmusage://session/a/b", "llmusage://overview?cmd=anything"] {
            XCTAssertNil(UsageRoute(url: URL(string: url)!))
        }
    }
    func testStaleSnapshotAndMidnight() {
        let snapshot = SampleData.snapshot(now: now)
        XCTAssertFalse(snapshot.isStale(now: now))
        XCTAssertTrue(snapshot.isStale(now: now.addingTimeInterval(1900)))
        XCTAssertTrue(snapshot.isStale(now: snapshot.day.end))
    }
    func testSortHasDeterministicTies() {
        let sessions = SampleData.snapshot(now: now).sessions
        XCTAssertEqual(SessionSort.tokens.sorted(sessions).first?.shortID, "11111111")
        XCTAssertEqual(SessionSort.output.sorted(sessions).first?.shortID, "22222222")
    }
    func testCustomPathIsValidatedRatherThanSilentlyIgnored() async {
        do { _ = try await CCUsageExecutableResolver().resolve(customPath: "/definitely/missing/ccusage"); XCTFail("Must reject path") }
        catch { XCTAssertEqual(error as? UsageError, .invalidPath("/definitely/missing/ccusage")) }
    }
    func testProcessArgumentsAreLiteral() async throws {
        let text = "$(touch /tmp/should-not-exist); 'quoted'"
        let result = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", text])
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), text)
    }
    func testNonzeroExitAndStderr() async {
        do {
            _ = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'fixture failure' >&2; exit 7"])
            XCTFail("Must reject nonzero exit")
        } catch { XCTAssertEqual(error as? UsageError, .processFailed(7, "fixture failure")) }
    }
    func testTimeoutTerminatesProcess() async {
        do {
            _ = try await ProcessRunner(timeout: 0.1).run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
            XCTFail("Must time out")
        } catch { XCTAssertEqual(error as? UsageError, .timedOut) }
    }
    func testCancellationTerminatesProcess() async {
        let task = Task { try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"]) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testLargeStderrDoesNotDeadlock() async throws {
        let result = try await ProcessRunner(timeout: 5).run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "dd if=/dev/zero bs=65536 count=4 >&2 2>/dev/null; printf ok"])
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "ok")
    }
    func testUnifiedReportIdentitiesMetadataAndTotals() throws {
        let snapshot = try CCUsageDecoder.decode(fixture("unified-sessions"), day: UsageDay(date: now), requireUnified: true)
        XCTAssertEqual(snapshot.sessions.count, 4)
        XCTAssertEqual(Set(snapshot.sessions.map(\.id)).count, 4)
        XCTAssertEqual(snapshot.sessions[0].rawID, snapshot.sessions[1].rawID)
        XCTAssertEqual(snapshot.sessions[0].projectPath, "/example/project")
        XCTAssertNotNil(snapshot.sessions[1].lastActivity)
        XCTAssertEqual(snapshot.totals.total, 860)
        XCTAssertEqual(snapshot.totals.additional, 50)
        XCTAssertEqual(snapshot.sessions[1].usage.total, 600)
        XCTAssertEqual(snapshot.sessions[1].reasoningOutputTokens, 150)
        XCTAssertEqual(snapshot.sourceSummaries.reduce(0) { $0 + $1.usage.total }, 860)
        XCTAssertEqual(snapshot.modelSummaries.reduce(0) { $0 + $1.usage.total }, 860)
        XCTAssertEqual(snapshot.modelSummaries.reduce(0) { $0 + $1.usage.cost }, 4.5, accuracy: 0.000001)
        XCTAssertEqual(snapshot.filtered(source: "codex").sessions.count, 1)
        XCTAssertTrue(snapshot.sourceSummaries.contains { $0.id == "future-agent" })
    }
    func testMissingPricesAreNotDisplayedAsFree() throws {
        let language = L10n.preference; L10n.preference = .english
        defer { L10n.preference = language }
        let snapshot = try CCUsageDecoder.decode(fixture("unified-sessions"), day: UsageDay(date: now))
        XCTAssertEqual(UsageFormat.cost(snapshot.totals), "≥ $4.50")
        XCTAssertEqual(UsageFormat.cost(snapshot.sessions[3].usage), "—")
        let data = Data(#"{"session":[{"agent":"codex","period":"a","inputTokens":10}]}"#.utf8)
        XCTAssertEqual(try CCUsageDecoder.decode(data, day: UsageDay(date: now)).totals.costIsIncomplete, true)
    }
    func testUnifiedSchemaRejectsPartialIdentityDuplicatesAndInconsistentTotals() throws {
        for json in [#"{"session":[{"period":"a"}]}"#, #"{"session":[{"agent":"codex"}]}"#,
                     #"{"session":[{"agent":"codex","period":"a"},{"agent":"codex","period":"a"}]}"#,
                     #"{"session":[{"agent":"codex","period":"a","inputTokens":10,"totalTokens":9}]}"#,
                     #"{"sessions":[]}"#] {
            XCTAssertThrowsError(try CCUsageDecoder.decode(Data(json.utf8), day: UsageDay(date: now), requireUnified: true))
        }
        XCTAssertTrue(try CCUsageDecoder.decode(Data(#"{"session":[]}"#.utf8), day: UsageDay(date: now), requireUnified: true).sessions.isEmpty)
    }
    func testNamespacedDeepLinksHandleOpaqueIDsAndLegacyScheme() {
        let id = UsageSource.sessionID(agent: "codex", rawID: "path/with spaces/тест#?%")
        let route = UsageRoute.session(id)
        XCTAssertEqual(UsageRoute(url: route.url), route)
        XCTAssertEqual(route.url.scheme, "llmusage")
        XCTAssertEqual(UsageRoute(url: URL(string: "claudeusage://overview")!), .overview)
    }
    func testNewSnapshotSlotDoesNotRestoreOldScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var legacy = SampleData.snapshot(now: now)
        legacy.schemaVersion = 1
        try SnapshotFiles.write(legacy, name: "latest-usage.json", directory: directory)
        XCTAssertNil(try SnapshotFiles.read(.today, directory: directory))
        let snapshot = SampleData.multiSourceSnapshot(now: now)
        try SnapshotFiles.write(snapshot, name: SnapshotSlot.today.rawValue, directory: directory)
        XCTAssertEqual(try SnapshotFiles.read(.today, directory: directory), snapshot)
    }

}
