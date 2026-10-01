import Foundation

// Executes actual product code when the host has Command Line Tools but no XCTest.
// This is an additional integration harness, not a replacement for the XCTest target.
private struct CheckFailure: Error, CustomStringConvertible { var description: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

// Await an observable condition rather than assuming a shared CI runner's speed.
@MainActor func waitForCheck(_ message: String, until condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CheckFailure(description: message) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private actor FixtureService: CCUsageServing {
    var failure: UsageError?
    var delay: TimeInterval = 0
    func fail(_ error: UsageError?) { failure = error }
    func setDelay(_ seconds: TimeInterval) { delay = seconds }
    func fetch(day: UsageDay, customPath: String, mode: UsageUpdateMode) async throws -> UsageSnapshot {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if let failure { throw failure }
        var data = SampleData.snapshot()
        data.day = day
        return data
    }
    func diagnose(customPath: String, forceDetect: Bool) -> CLIDiagnostics { .init(path: "/fixture/ccusage", version: "fixture") }
}

private actor MemoryRepository: SnapshotPersisting {
    var data: [String: UsageSnapshot] = [:]
    var status: RefreshStatus?
    var history: UsageHistory?
    func read(_ slot: SnapshotSlot) -> UsageSnapshot? { data[slot.rawValue] }
    func write(_ snapshot: UsageSnapshot, to slot: SnapshotSlot) { data[slot.rawValue] = snapshot }
    func readStatus() -> RefreshStatus? { status }
    func readHistory() -> UsageHistory? { history }
    func writeHistory(_ history: UsageHistory) { self.history = history }
    func writeStatus(_ status: RefreshStatus) { self.status = status }
}

@main
struct PortableChecks {
    @MainActor static func main() async {
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ action: () async throws -> Void) async {
            do { try await action(); passed += 1; print("PASS \(name)") }
            catch { failures.append(name); print("FAIL \(name): \(error)") }
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("LLMUsage/Tests/Fixtures")
        let now = ISO8601DateFormatter().date(from: "2026-09-28T18:00:00Z")!
        await check("Real CLI empty JSON") {
            let data = try Data(contentsOf: fixtures.appendingPathComponent("ccusage-20.0.26-empty.json"))
            let snapshot = try CCUsageDecoder.decode(data, day: UsageDay(date: now))
            try expect(snapshot.sessions.isEmpty && snapshot.totals == .zero, "Empty response must be valid zero usage")
        }
        await check("Sample JSON normalization and all totals") {
            let data = try Data(contentsOf: fixtures.appendingPathComponent("sample-sessions.json"))
            let snapshot = try CCUsageDecoder.decode(data, day: UsageDay(date: now))
            try expect(snapshot.totals == SampleData.snapshot(now: now).totals, "Totals differ from brief")
            try expect(snapshot.sessions[0].lastActivity != nil, "ISO date must decode")
        }
        await check("Optional fields, unknown keys and date-only activity") {
            let snapshot = try CCUsageDecoder.decode(Data(#"{"sessions":[{"sessionId":"abc","lastActivity":"2026-09-28","inputTokens":3}],"future":true}"#.utf8), day: UsageDay(date: now))
            try expect(snapshot.totals.total == 3 && !snapshot.sessions[0].activityHasTime, "Optional defaults/date precision")
        }
        await check("Malformed, duplicate and negative JSON rejected") {
            for text in ["{}", "not json", #"{"sessions":[{"sessionId":"a","totalCost":-1}]}"#, #"{"sessions":[{"sessionId":"a","inputTokens":-1}]}"#,
                         #"{"sessions":[{"sessionId":"a"},{"sessionId":"a"}]}"#] {
                do { _ = try CCUsageDecoder.decode(Data(text.utf8), day: UsageDay(date: now)); throw CheckFailure(description: "Accepted invalid JSON") }
                catch is UsageError { }
            }
        }
        await check("Mixed model aggregation does not duplicate tokens") {
            var data = SampleData.snapshot(now: now)
            data.sessions[0].models = ["a", "b"]
            try expect(data.modelSummaries.reduce(0) { $0 + $1.usage.total } == data.totals.total, "Double counted tokens")
        }
        await check("Model breakdown aliases") {
            let text = #"{"sessions":[{"sessionId":"a","inputTokens":10,"totalCost":1,"modelBreakdowns":[{"model":"opus","inputTokens":10,"totalCost":1}]}]}"#
            let data = try CCUsageDecoder.decode(Data(text.utf8), day: UsageDay(date: now))
            try expect(data.modelSummaries.first?.id == "opus" && data.modelSummaries.first?.usage.cost == 1, "Model aliases")
        }
        await check("Compact/exact token formatting including boundary") {
            let language = L10n.preference; L10n.preference = .english
            defer { L10n.preference = language }
            for (n, expected): (Int64, String) in [(114,"114"),(19_149,"19.1K"),(620_586,"620.6K"),(7_943_608,"7.94M"),(999_999,"1M")] {
                try expect(UsageFormat.tokens(n) == expected, "Bad token format for \(n)")
            }
            try expect(UsageFormat.exact(7_943_608) == "7,943,608", "Exact formatting")
        }
        await check("Cost and percent formatting") {
            let language = L10n.preference; L10n.preference = .english
            defer { L10n.preference = language }
            try expect(UsageFormat.cost(5.47) == "$5.47" && UsageFormat.cost(-0.0) == "$0.00", "Currency")
            try expect(UsageFormat.percent(0.9125) == "91.25%" && UsageFormat.percent(0.000001) == "<0.01%", "Percent")
        }
        await check("Short session ID") { try expect(SampleData.snapshot().sessions[0].shortID == "11111111", "Short ID") }
        await check("UTC date and timezone midnight") {
            let date = ISO8601DateFormatter().date(from: "2026-09-28T23:30:00Z")!
            try expect(UsageDay(date: date).key == "20260928", "UTC date")
            try expect(UsageDay(date: date, timezone: "Europe/Moscow").key == "20260929", "Local date")
        }
        await check("DST day boundaries") {
            let date = ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z")!
            let day = UsageDay(date: date, timezone: "America/New_York")
            try expect(day.end.timeIntervalSince(day.date) == 23 * 3600 && day.adding(days: -1).key == "20260307", "DST")
        }
        await check("CLI arguments explicitly enable online pricing") {
            try expect(CCUsageService.arguments(for: UsageDay(date: now), report: .unified) == ["session", "--json", "--all", "--since", "20260928", "--until", "20260928", "--timezone", "UTC", "--mode", "calculate", "--order", "desc", "--no-offline"], "Arguments")
        }
        await check("Atomic snapshot files and separate day slots") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = SnapshotRepository(directory: directory)
            let snapshot = SampleData.snapshot(now: now)
            try await repository.write(snapshot, to: .today)
            let result = try await repository.read(.today)
            let previous = try await repository.read(.yesterday)
            try expect(result == snapshot && previous == nil, "Round trip")
            try await repository.writeStatus(.init(attemptedAt: now, message: "fixture", refreshMinutes: 15))
            let status = try SnapshotFiles.status(directory: directory)
            try expect(status?.message == "fixture", "Status round trip")
        }
        await check("Missing container is reported") {
            do { _ = try await SnapshotRepository(directory: nil).read(.today); throw CheckFailure(description: "No container accepted") }
            catch is UsageError { }
        }
        await check("Denied snapshot access is not mistaken for a missing file") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                try? FileManager.default.removeItem(at: directory)
            }
            let repository = SnapshotRepository(directory: directory)
            let missing = try await repository.read(.today)
            try expect(missing == nil, "A genuinely absent snapshot should be empty")
            try await repository.write(SampleData.snapshot(now: now), to: .today)
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(SnapshotSlot.today.rawValue).path)
            try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Snapshot must be private to the current user")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
            do {
                _ = try await repository.read(.today)
                throw CheckFailure(description: "Denied directory was silently treated as an empty snapshot")
            } catch is UsageError { }
        }
        await check("Deep-link route parsing and validation") {
            for route: UsageRoute in [.overview,.sessions,.settings,.session("11111111-1111-4111-8111-111111111111")] {
                try expect(UsageRoute(url: route.url) == route, "Route round trip")
            }
            for text in ["https://overview","llmusage://session","llmusage://session/a/b","llmusage://overview?x=1"] {
                try expect(UsageRoute(url: URL(string: text)!) == nil, "Unexpected URL accepted")
            }
        }
        await check("Staleness and day rollover") {
            let snapshot = SampleData.snapshot(now: now)
            try expect(!snapshot.isStale(now: now) && snapshot.isStale(now: now.addingTimeInterval(1900)) && snapshot.isStale(now: snapshot.day.end), "Stale logic")
        }
        await check("Session sorting") {
            let sessions = SampleData.snapshot().sessions
            try expect(SessionSort.tokens.sorted(sessions)[0].shortID == "11111111", "Tokens sort")
            try expect(SessionSort.output.sorted(sessions)[0].shortID == "22222222", "Output sort")
        }
        await check("Invalid executable path") {
            do { _ = try await CCUsageExecutableResolver().resolve(customPath: "/missing/ccusage"); throw CheckFailure(description: "Accepted path") }
            catch is UsageError { }
        }
        await check("Process passes literal arguments, not shell strings") {
            let literal = "$(anything); 'quoted'"
            let result = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s",literal])
            try expect(String(decoding: result.stdout, as: UTF8.self) == literal, "Shell interpolation")
        }
        await check("Process failure includes exit code and stderr") {
            do { _ = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c","printf fixture >&2; exit 7"]); throw CheckFailure(description: "Expected failure") }
            catch let error as UsageError { try expect(error == .processFailed(7,"fixture"), "Lost stderr") }
        }
        await check("Process timeout") {
            do { _ = try await ProcessRunner(timeout: 0.1).run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"]); throw CheckFailure(description: "Expected timeout") }
            catch let error as UsageError { try expect(error == .timedOut, "Wrong error") }
        }
        await check("Cancellation while running") {
            let task = Task { try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"]) }
            try await Task.sleep(for: .milliseconds(80))
            task.cancel()
            do { _ = try await task.value; throw CheckFailure(description: "Expected cancellation") }
            catch is CancellationError { }
        }
        await check("Large stderr cannot deadlock") {
            let result = try await ProcessRunner(timeout: 5).run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c","dd if=/dev/zero bs=65536 count=4 >&2 2>/dev/null; printf ok"])
            try expect(String(decoding: result.stdout, as: UTF8.self) == "ok", "Pipe deadlock")
        }
        await check("Oversized process output rejected") {
            do { _ = try await ProcessRunner(timeout: 5, maximumBytes: 1000).run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c","dd if=/dev/zero bs=65536 count=4 2>/dev/null"]); throw CheckFailure(description: "Size limit ignored") }
            catch let error as UsageError { try expect(error == .outputTooLarge, "Size error") }
        }
        await check("Store retains successful data after failure") {
            let service = FixtureService()
            let repository = MemoryRepository()
            let defaults = UserDefaults(suiteName: "LLMUsage.PortableTests")!
            defer { defaults.removePersistentDomain(forName: "LLMUsage.PortableTests") }
            let store = UsageStore(service: service, repository: repository, defaults: defaults, reloadWidget: {})
            await store.refresh()
            let good = store.snapshot
            try expect(store.state == .loaded, "Initial load")
            await service.fail(.timedOut)
            await store.refresh()
            let persisted = await repository.read(.today)
            try expect(store.state == .stale && store.snapshot == good && persisted == good, "Failed refresh erased data")
        }
        await check("Historical dashboard cannot overwrite widget today") {
            let repository = MemoryRepository()
            let defaults = UserDefaults(suiteName: "LLMUsage.PortableTests")!
            defer { defaults.removePersistentDomain(forName: "LLMUsage.PortableTests") }
            let store = UsageStore(service: FixtureService(), repository: repository, defaults: defaults, reloadWidget: {})
            store.period = .custom
            store.customDate = Date().addingTimeInterval(-4 * 86400)
            await store.refresh()
            let widget = await repository.read(.today)
            try expect(widget?.day.isToday() == true && store.snapshot?.day == store.selectedDay && widget?.day != store.selectedDay, "Historical snapshot leaked to widget")
            store.navigate(.overview)
            try expect(store.period == .today && store.snapshot?.day == widget?.day, "Widget overview link must select today")
        }
        await check("Missing CLI state does not display fake zero data") {
            let service = FixtureService()
            await service.fail(.missingExecutable)
            let store = UsageStore(service: service, repository: MemoryRepository(), reloadWidget: {})
            await store.refresh()
            try expect(store.state == .error && store.snapshot == nil && !store.isRefreshing, "Missing CLI state")
        }
        await check("Date change during in-flight refresh selects latest request") {
            let service = FixtureService()
            await service.setDelay(0.04)
            let store = UsageStore(service: service, repository: MemoryRepository(), reloadWidget: {})
            let refresh = Task { await store.refresh() }
            try await Task.sleep(for: .milliseconds(20))
            store.period = .custom
            store.customDate = Date().addingTimeInterval(-3 * 86400)
            await store.selectPeriod()
            await refresh.value
            try expect(store.snapshot?.day == store.selectedDay && store.state == .loaded, "Out-of-order data")
        }
        await check("Unified report preserves source identities and nested metadata") {
            let data = try Data(contentsOf: fixtures.appendingPathComponent("unified-sessions.json"))
            let snapshot = try CCUsageDecoder.decode(data, day: UsageDay(date: now), report: .unified)
            try expect(snapshot.sessions.count == 4 && Set(snapshot.sessions.map(\.id)).count == 4, "Cross-agent ID collision")
            try expect(snapshot.sessions[0].rawID == snapshot.sessions[1].rawID, "Fixture must exercise duplicate raw IDs")
            try expect(snapshot.sessions[0].projectPath == "/example/project" && snapshot.sessions[1].lastActivity != nil, "Lost nested metadata")
        }
        await check("Additional tokens retained; reasoning already in output is not counted twice") {
            let snapshot = try CCUsageDecoder.decode(Data(contentsOf: fixtures.appendingPathComponent("unified-sessions.json")), day: UsageDay(date: now))
            try expect(snapshot.totals.total == 860 && snapshot.totals.additional == 50, "Lost extra tokens")
            try expect(snapshot.sessions[1].usage.total == 600 && snapshot.sessions[1].reasoningOutputTokens == 150, "Double counted reasoning")
            try expect(snapshot.modelSummaries.reduce(0) { $0 + $1.usage.total } == 860, "Model totals dropped extras")
        }
        await check("All source and model rollups equal the report totals") {
            let snapshot = try CCUsageDecoder.decode(Data(contentsOf: fixtures.appendingPathComponent("unified-sessions.json")), day: UsageDay(date: now))
            try expect(snapshot.sourceSummaries.reduce(0) { $0 + $1.usage.total } == 860, "Source total mismatch")
            try expect(snapshot.sourceSummaries.reduce(0) { $0 + $1.sessionCount } == 4, "Source session mismatch")
            try expect(snapshot.totals.cost == 4.5 && snapshot.modelSummaries.reduce(0) { $0 + $1.usage.cost } == 4.5, "Cost mismatch")
            try expect(snapshot.sourceSummaries.contains { $0.id == "future-agent" && $0.label == "future-agent" }, "New agent discarded")
        }
        await check("Missing model pricing keeps currency formatting and diagnostic flags") {
            let language = L10n.preference; L10n.preference = .english
            defer { L10n.preference = language }
            let snapshot = try CCUsageDecoder.decode(Data(contentsOf: fixtures.appendingPathComponent("unified-sessions.json")), day: UsageDay(date: now))
            try expect(UsageFormat.cost(snapshot.totals) == "$4.50" && UsageFormat.cost(snapshot.sessions[3].usage) == "$0.00", "Currency formatting changed for missing pricing")
            let hidden = try CCUsageDecoder.decode(Data(#"{"session":[{"agent":"codex","period":"a","inputTokens":10}]}"#.utf8), day: UsageDay(date: now))
            try expect(hidden.totals.costIsIncomplete == true, "Hidden cost displayed as known")
        }
        await check("Unified schema requires source and rejects duplicates or inconsistent totals") {
            for json in [#"{"session":[{"period":"a"}]}"#, #"{"session":[{"agent":"codex"}]}"#,
                         #"{"session":[{"agent":"codex","period":"a"},{"agent":"codex","period":"a"}]}"#,
                         #"{"session":[{"agent":"codex","period":"a","inputTokens":10,"totalTokens":9}]}"#,
                         #"{"session":[{"agent":"codex","period":"a","totalTokens":-1}]}"#,
                         #"{"sessions":[]}"#] {
                do { _ = try CCUsageDecoder.decode(Data(json.utf8), day: UsageDay(date: now), report: .unified); throw CheckFailure(description: "Accepted invalid unified response") }
                catch is UsageError { }
            }
            let empty = try CCUsageDecoder.decode(Data(#"{"session":[]}"#.utf8), day: UsageDay(date: now), report: .unified)
            try expect(empty.sessions.isEmpty, "Empty unified report rejected")
        }
        await check("Opaque session IDs round-trip through links; old links remain supported") {
            let rawID = "path/session 1/#?% Unicode тест"
            let id = UsageSource.sessionID(agent: "future-agent", rawID: rawID)
            let route = UsageRoute.session(id)
            try expect(UsageRoute(url: route.url) == route && route.url.scheme == "llmusage", "Unsafe deep-link encoding")
            try expect(UsageRoute(url: URL(string: "claudeusage://overview")!) == .overview, "Old widget link broken")
            let session = UsageSession(id: id, models: [], usage: .zero, lastActivity: nil, agent: "codex",
                originalID: "2026/09/28/rollout-2026-09-28T12-00-00-01a0b123-1234-5678-9abc-0123456789ab")
            try expect(session.shortID == "01a0b123", "Codex short ID shows common rollout prefix")
        }
        await check("Source filter changes all dashboard totals without narrowing widget data") {
            let store = UsageStore(demo: true)
            let total = store.todaySnapshot?.totals.total
            store.sourceFilter = "codex"
            try expect(store.displaySnapshot?.sessions.count == 1 && store.selectedModels == ["gpt-6-astra"], "Source filter ignored")
            try expect(store.todaySnapshot?.totals.total == total && store.displaySnapshot?.totals.total != total, "Dashboard filter contaminated widget")
            store.navigate(.overview)
            try expect(store.sourceFilter.isEmpty, "Widget link must open all-source overview")
            store.navigate(.session("11111111-1111-4111-8111-111111111111"))
            try expect(store.selectedSession?.sourceID == "claude", "Legacy session link not migrated")
        }
        await check("New snapshot files cannot restore a Claude-only legacy cache") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var legacy = SampleData.snapshot(now: now)
            legacy.schemaVersion = 1
            try SnapshotFiles.write(legacy, name: "latest-usage.json", directory: directory)
            let initial = try SnapshotFiles.read(.today, directory: directory)
            try expect(initial == nil, "Old scope silently restored")
            let snapshot = SampleData.multiSourceSnapshot(now: now)
            try SnapshotFiles.write(snapshot, name: SnapshotSlot.today.rawValue, directory: directory)
            let restored = try SnapshotFiles.read(.today, directory: directory)
            try expect(restored == snapshot, "Unified snapshot round trip failed")
        }
        await HistoryChecks.run(check: check)
        await RefreshChecks.run(check: check)
        L10n.preference = .russian // Existing transcript fixtures assert Russian helper labels.
        await TranscriptChecks.run(check: check)
        await RegressionScenarios.run(check: check)
        await PricingScenarios.run(check: check)
        await LocalizationChecks.run(check: check)
        await check("Locale: preference publishes during failed refresh and preserves history") {
            let suite = "local.LLMUsage.LocaleCheck.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let service = RefreshFixtureService(today: UsageDay())
            let repository = MemoryRepository()
            var reloads = 0
            let store = UsageStore(service: service, repository: repository, defaults: defaults, reloadWidget: { reloads += 1 })
            try expect(store.interfaceLanguage == .system, "Language default must be system")
            await store.refresh()
            await store.waitForHistoryBackfill()
            let history = store.history
            let snapshot = store.todaySnapshot
            await service.configure(failure: .timedOut, holdNext: true)
            let request = Task { await store.refresh() }
            defer {
                request.cancel()
                Task { await service.finishHeldRequest() }
            }
            await service.waitUntilHeld()
            store.interfaceLanguage = .english
            try await waitForCheck("Widget language was not published while CLI was held") {
                await repository.readStatus()?.interfaceLanguage == .english
            }
            let during = await repository.readStatus()
            try expect(during?.interfaceLanguage == .english && store.isRefreshing, "Widget language waits for CLI")
            await service.finishHeldRequest()
            await request.value
            store.interfaceLanguage = .russian
            try await waitForCheck("Stored failure was not relocalized") {
                let status = await repository.readStatus()
                return status?.interfaceLanguage == .russian && status?.message == "ccusage не ответил вовремя" && reloads >= 3
            }
            let after = await repository.readStatus()
            try expect(after?.interfaceLanguage == .russian && after?.message == "ccusage не ответил вовремя", "Stored failure did not relocalize")
            try expect(store.history == history && store.todaySnapshot == snapshot && reloads >= 3, "Language cleared data or failed to request widget refresh")
            let restarted = UsageStore(service: service, repository: repository, defaults: defaults, reloadWidget: {})
            try expect(restarted.interfaceLanguage == .russian, "Language preference not persisted")
        }
        if ProcessInfo.processInfo.arguments.contains("--live-cli") {
            await check("Installed ccusage: cached tariffs price new offline usage after restart") {
                try await PricingScenarios.liveCheck()
            }
            await check("Installed ccusage: resolver, version, real query with online pricing enabled") {
                let service = CCUsageService(pricing: ClaudePricingCache(directory: root.appendingPathComponent("build/PricingLiveChecks")))
                let version = try await service.diagnose(customPath: "", forceDetect: true)
                let snapshot = try await service.fetch(day: UsageDay(), customPath: "")
                try expect(!version.version.isEmpty && snapshot.day.isToday(), "Real CLI integration")
                let allAgents = try await service.fetch(day: UsageDay(), customPath: "", mode: .allAgents)
                try expect(allAgents.day.isToday(), "All-agent live integration")
                // Compare normalized totals with the same real JSON response, not a later refresh.
                let output = try await ProcessRunner().run(executable: URL(fileURLWithPath: version.path), arguments: CCUsageService.arguments(for: UsageDay(), report: .claude))
                let normalized = try CCUsageDecoder.decode(output.stdout, day: UsageDay(), report: .claude)
                let json = try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any]
                let totals = json?["totals"] as? [String: Any]
                let reportedTokens = (totals?["totalTokens"] as? NSNumber)?.int64Value
                let reportedCost = (totals?["totalCost"] as? NSNumber)?.doubleValue
                try expect(reportedTokens == normalized.totals.total, "Normalized live tokens disagree with CLI")
                if let reportedCost { try expect(abs(reportedCost - normalized.totals.cost) < 0.000001, "Normalized live cost disagrees with CLI") }
                print("  \(version.version); Claude: \(snapshot.sessions.count) sessions, all agents: \(allAgents.sessions.count); focused totals match JSON")
            }
        }
        print("\n\(passed) portable checks passed; \(failures.count) failed.")
        if !failures.isEmpty { exit(1) }
    }
}
