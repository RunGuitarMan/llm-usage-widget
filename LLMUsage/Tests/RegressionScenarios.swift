import Foundation
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#elseif !PORTABLE_CHECKS
@testable import LLMUsage
#endif

private struct RegressionFailure: Error, CustomStringConvertible { var description: String }
private func requireRegression(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw RegressionFailure(description: message) }
}

@MainActor private final class RegressionClock {
    var now = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!
}

private actor RegressionService: CCUsageServing {
    var cost = 1.0
    var timestamp = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!
    var fails = false
    var requests: [UsageDay] = []
    func configure(cost: Double, at date: Date, fails: Bool = false) {
        self.cost = cost; timestamp = date; self.fails = fails
    }
    func fetch(day: UsageDay, customPath: String) async throws -> UsageSnapshot {
        requests.append(day)
        if fails { throw UsageError.timedOut }
        return .init(generatedAt: timestamp, day: day,
                     sessions: [.init(id: "s-" + day.key, models: ["test"], usage: .init(cost: cost))])
    }
    func count(_ day: UsageDay) -> Int { requests.filter { $0 == day }.count }
    func diagnose(customPath: String, forceDetect: Bool) -> CLIDiagnostics { .init(path: "fixture", version: "1") }
}

private actor RegressionRepository: SnapshotPersisting {
    var snapshots: [SnapshotSlot: UsageSnapshot] = [:]
    var status: RefreshStatus?
    var history: UsageHistory?
    func read(_ slot: SnapshotSlot) -> UsageSnapshot? { snapshots[slot] }
    func write(_ snapshot: UsageSnapshot, to slot: SnapshotSlot) { snapshots[slot] = snapshot }
    func readStatus() -> RefreshStatus? { status }
    func writeStatus(_ status: RefreshStatus) { self.status = status }
    func readHistory() -> UsageHistory? { history }
    func writeHistory(_ history: UsageHistory) { self.history = history }
}

/// Lets a deliberately uncooperative old search finish after the newer one.
private final class RegressionSearchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    let release = DispatchSemaphore(value: 0)
    func start() { lock.lock(); began = true; lock.unlock() }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return began }
}

/// Shared by XCTest and the CLT harness, so regression coverage does not diverge.
enum RegressionScenarios {
    @MainActor static func run(check: (String, () async throws -> Void) async -> Void) async {
        await check("Regression: parallel tool records and exports grow linearly") {
            for count in [1, 20, 80] {
                var decoder = TranscriptDecoder(source: "claude")
                let calls: [String: Any] = ["message": ["role": "assistant", "content": (0..<count).map {
                    ["type": "tool_use", "id": "c\($0)", "name": "Read", "input": ["path": "file\($0)"]] as [String: Any]
                }], "envelopeMarker": "CALL-ENVELOPE"]
                let results: [String: Any] = ["message": ["role": "user", "content": (0..<count).map {
                    ["type": "tool_result", "tool_use_id": "c\($0)", "content": "result\($0):" + String(repeating: "x", count: 20_000)]
                }], "envelopeMarker": "RESULT-ENVELOPE"]
                decoder.append(calls); decoder.append(results)
                let events = decoder.finish()
                try requireRegression(events.count == count && events.allSatisfy(\.hasResult), "Tools/results were dropped")
                for (index, event) in events.enumerated() {
                    try requireRegression(event.output.hasPrefix("result\(index):"), "Parallel results were mixed")
                    try requireRegression(event.records.count == 2, "Duplicated source reference inside an event")
                }
                let unique = Dictionary(events.flatMap(\.records).map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
                try requireRegression(unique.count == 2, "The same envelope was allocated per tool")
                let sourceBytes = try JSONSerialization.data(withJSONObject: calls).count + JSONSerialization.data(withJSONObject: results).count
                let text = SessionTranscript(events: events).exportText
                try requireRegression(text.components(separatedBy: "RESULT-ENVELOPE").count == 2, "Export duplicates shared envelopes")
                try requireRegression(text.utf8.count < sourceBytes * 3, "Export grows with tools × envelope size")
            }
        }
        await check("Regression: tool-only and context-only exports retain outer metadata") {
            for message: [String: Any] in [
                ["role": "assistant", "tool_calls": [["id": "c", "function": ["name": "exec", "arguments": "{}"]]]],
                ["role": "assistant", "content": [["type": "thinking", "thinking": "context"]]]
            ] {
                var decoder = TranscriptDecoder(source: "claude")
                decoder.append(["message": message, "uuid": "outer-identity", "model": "outer-model"])
                let text = SessionTranscript(events: decoder.finish()).exportText
                try requireRegression(text.contains("outer-identity") && text.contains("outer-model"), "Original envelope metadata disappeared")
            }
        }
        await check("Regression: Codex attachments deduplicate without erasing repeated turns") {
            let previous = L10n.preference
            defer { L10n.preference = previous }
            for language in [InterfaceLanguage.russian, .english] {
                L10n.preference = language
                for responseFirst in [true, false] {
                    var decoder = TranscriptDecoder(source: "codex")
                    for (text, attachment) in [("again", true), ("again", true), ("again", false), ("", true)] {
                        let fallback: [String: Any] = ["type": "event_msg", "payload": ["type": "user_message", "message": text, "images": attachment ? ["image"] : []]]
                        var content: [[String: Any]] = [["type": "input_text", "text": text]]
                        if attachment { content.append(["type": "input_image", "image_url": "data:image/png;base64,AAA"]) }
                        let response: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "user", "content": content]]
                        for row in responseFirst ? [response, fallback] : [fallback, response] { decoder.append(row) }
                    }
                    let events = decoder.finish()
                    try requireRegression(events.count == 4 && events.allSatisfy { $0.kind == .user }, "Duplicate turn or missing repeated prompt")
                    try requireRegression(events.allSatisfy { $0.records.count == 2 }, "Wire metadata lost during deduplication")
                }
            }
        }
        await check("Regression: JSONL and NDJSON discovery share exact header matching") {
            for suffix in ["jsonl", "ndjson", "json"] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let dir = root.appendingPathComponent(".gemini/tmp/project/chats")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let records = [#"{"sessionId":"expected","role":"user","content":"hello"}"#,
                               #"{"role":"assistant","content":"answer"}"#]
                let content = suffix == "json" ? "{\"sessionId\":\"expected\",\"messages\":[" + records.joined(separator: ",") + "]}" : records.joined(separator: "\n")
                try content.write(to: dir.appendingPathComponent("unrelated-name." + suffix), atomically: true, encoding: .utf8)
                let session = UsageSession(id: "expected", models: [], usage: .zero, agent: "gemini", originalID: "expected")
                let transcript = try await TranscriptService(home: root, environment: [:]).load(session: session)
                try requireRegression(transcript.messageCount == 2, "Header discovery failed for \(suffix)")
                var wrong = session; wrong.originalID = "hello"
                do {
                    _ = try await TranscriptService(home: root, environment: [:]).load(session: wrong)
                    throw RegressionFailure(description: "A chat body was mistaken for a session ID")
                } catch is TranscriptError { }
            }
        }
        await check("Regression: background transcript search preserves all fields and context grouping") {
            var one = TranscriptEvent(id: "1", kind: .assistant, title: "Answer", text: "HELLO", raw: "envelope-only")
            one.input = "input-only"; one.output = "output-only"
            let events = [one, TranscriptEvent(id: "2", kind: .context, title: "Context", raw: "hidden-only"),
                          TranscriptEvent(id: "3", kind: .context, title: "Context", raw: "hidden-only")]
            let transcript = SessionTranscript(events: events)
            for query in ["hello", "input-only", "output-only", "envelope-only", "hidden-only", "absent"] {
                let result = try TranscriptSearchResult.evaluate(.init(transcript: transcript, query: query))
                try requireRegression(result.rows.flatMap(\.events).map(\.id) == events.filter { $0.matches(query) }.map(\.id), "Search semantics changed for \(query)")
                try requireRegression(result.eventCount == result.rows.flatMap(\.events).count, "Count disagrees with rows")
            }
            let hidden = try TranscriptSearchResult.evaluate(.init(transcript: transcript))
            let shown = try TranscriptSearchResult.evaluate(.init(transcript: transcript, showContext: true))
            try requireRegression(hidden.eventCount == 1 && shown.eventCount == 3 && shown.rows.count == 2, "Context visibility/grouping changed")
        }
        await check("Regression: session search shares rows, sorting and aggregate totals") {
            let snapshot = SampleData.multiSourceSnapshot()
            for sort in SessionSort.allCases {
                let result = try SessionSearchResult.evaluate(.init(sessions: snapshot.sessions, source: "codex", sort: sort))
                let expected = sort.sorted(snapshot.sessions.filter { $0.sourceID == "codex" })
                try requireRegression(result.sessions == expected && result.total == expected.reduce(.zero, { $0 + $1.usage }), "Table totals or ordering diverged")
            }
            let result = try SessionSearchResult.evaluate(.init(sessions: snapshot.sessions, query: "GPT", model: "gpt-6-astra"))
            try requireRegression(result.sessions.count == 1 && result.sessions[0].sourceID == "codex", "Combined model/text filtering changed")
        }
        await check("Regression: search executes off main thread and rejects late completions") {
            let gate = RegressionSearchGate()
            let results = SearchResults<Int, Int>(initial: 0) { value in
                try requireRegression(!Thread.isMainThread, "Search ran on the UI thread")
                if value == 1 { gate.start(); _ = gate.release.wait(timeout: .now() + 2) }
                return value
            }
            let old = Task { await results.update(1, delay: .zero) }
            defer { gate.release.signal() }
            for _ in 0..<100 where !gate.started { try await Task.sleep(for: .milliseconds(10)) }
            try requireRegression(gate.started, "Search never began")
            await results.update(2, delay: .zero)
            gate.release.signal()
            await old.value
            try requireRegression(results.value == 2 && !results.isSearching, "Old search overwrote the newest result")
        }
        await check("Regression: cancelled debounce never publishes and subsequent search recovers") {
            let results = SearchResults<Int, Int>(initial: 0) { $0 }
            let cancelled = Task { await results.update(1, delay: .seconds(60)) }
            for _ in 0..<100 where !results.isSearching { await Task.yield() }
            cancelled.cancel()
            await cancelled.value
            try requireRegression(results.value == 0 && !results.isSearching, "Cancelled request was published or kept loading")
            await results.update(3, delay: .zero)
            try requireRegression(results.value == 3, "Cancellation prevented the next request")
        }
        await check("Regression: cache expiry respects completion, six hours, and DST") {
            let now = ISO8601DateFormatter().date(from: "2026-03-10T12:00:00Z")!
            let day = UsageDay(date: now, timezone: "America/New_York").adding(days: -2)
            var snapshot = UsageSnapshot(generatedAt: now, day: day, sessions: [])
            try requireRegression(snapshot.canReuse(for: day, now: now.addingTimeInterval(21599), liveInterval: 180), "Completed day expired too soon")
            try requireRegression(!snapshot.canReuse(for: day, now: now.addingTimeInterval(21600), liveInterval: 180), "Completed day never expires")
            snapshot.generatedAt = day.end.addingTimeInterval(-1)
            try requireRegression(!snapshot.canReuse(for: day, now: now, liveInterval: 180), "Partial day reused after midnight")
            snapshot.generatedAt = now.addingTimeInterval(1)
            try requireRegression(!snapshot.canReuse(for: day, now: now, liveInterval: 180), "Future timestamp bypassed expiry")
        }
        await check("Regression: manual and expired historical selections refetch outside the week") {
            try await withStore { store, service, clock in
                let past = UsageDay(date: clock.now).adding(days: -10)
                store.period = .custom; store.customDate = past.date
                await store.refresh(reason: .startup); await store.waitForHistoryBackfill()
                clock.now.addTimeInterval(60)
                await service.configure(cost: 2, at: clock.now)
                await store.refresh(); await store.waitForHistoryBackfill()
                let manualCount = await service.count(past)
                try requireRegression(store.snapshot?.totals.cost == 2 && manualCount == 2, "Manual refresh reused old historical data")
                await store.selectPeriod()
                let reusedCount = await service.count(past)
                try requireRegression(reusedCount == 2, "Fresh historical selection unnecessarily refetched")
                clock.now.addTimeInterval(21600)
                await service.configure(cost: 3, at: clock.now)
                await store.selectPeriod(); await store.waitForHistoryBackfill()
                let expiredCount = await service.count(past)
                try requireRegression(store.snapshot?.totals.cost == 3 && expiredCount == 3, "Expired old date stayed cached forever")
                try requireRegression(store.todaySnapshot?.day != past, "Historical data overwrote widget today")
            }
        }
        await check("Regression: failed rollover preserves data with its actual day label") {
            try await withStore { store, service, clock in
                await store.refresh(reason: .startup); await store.waitForHistoryBackfill()
                let previous = store.snapshot!
                clock.now = previous.day.end.addingTimeInterval(60)
                await service.configure(cost: 0, at: clock.now, fails: true)
                await store.refresh(reason: .automatic)
                try requireRegression(store.snapshot == previous && store.state == .stale, "Rollover erased last successful data")
                for language in [InterfaceLanguage.russian, .english] {
                    let saved = L10n.preference; L10n.preference = language
                    defer { L10n.preference = saved }
                    try requireRegression(previous.day.spendingTitle(now: clock.now) == L10n.text("Расходы за вчера"), "Old data relabelled as today")
                    try requireRegression(store.selectedDay.spendingTitle(now: clock.now) == L10n.text("Расходы за сегодня"), "Current day label broken")
                }
            }
        }
        await check("Regression: dated routes round-trip opaque IDs, timezones and legacy links") {
            let id = UsageSource.sessionID(agent: "codex", rawID: "/tmp/Пример #1?/% log")
            for timezone in ["UTC", "Europe/Moscow", "America/New_York", "Pacific/Kiritimati"] {
                let day = UsageDay(date: Date(timeIntervalSince1970: 1772971200), timezone: timezone)
                for route in [UsageRoute.datedSession(id, day), .datedSessions(day), .session(id), .sessions] {
                    try requireRegression(UsageRoute(url: route.url) == route, "Route lost ID or calendar context")
                }
            }
            try requireRegression(UsageRoute(url: URL(string: "claudeusage://session/legacy")!) == .session("legacy"), "Legacy route broken")
            for query in ["day=20260230&timezone=UTC", "day=20260101&timezone=Invalid", "day=20260101", "timezone=UTC", "day=20260101&day=20260102", "day=20260101&timezone=UTC&x=1"] {
                try requireRegression(UsageRoute(url: URL(string: "llmusage://sessions?" + query)!) == nil, "Invalid route accepted: \(query)")
            }
        }
        await check("Regression: widget session navigation loads the linked historical day") {
            try await withStore { store, service, clock in
                await store.refresh(reason: .startup); await store.waitForHistoryBackfill()
                let day = UsageDay(date: clock.now).adding(days: -10)
                store.navigate(UsageRoute(url: UsageRoute.datedSession("s-" + day.key, day).url)!)
                for _ in 0..<100 where store.snapshot?.day != day || store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
                try requireRegression(store.snapshot?.day == day && store.selectedSession?.id == "s-" + day.key, "Widget opened today's or missing session")
                let count = await service.count(day)
                try requireRegression(count == 1, "Cold route did not fetch the target day exactly once")
                store.navigate(.datedSessions(day))
                try requireRegression(store.snapshot?.day == day && store.selectedSessionID == nil, "Dated background link lost context")
                store.navigate(.sessions)
                try requireRegression(store.period == .today && store.snapshot == store.todaySnapshot, "Legacy sessions link retained an unrelated period")
                await store.waitForHistoryBackfill()
            }
        }
        await check("Regression: dated widget navigation applies its timezone before loading") {
            try await withStore { store, _, clock in
                let day = UsageDay(date: clock.now.addingTimeInterval(-86400), timezone: "America/New_York")
                store.navigate(.datedSession("s-" + day.key, day))
                for _ in 0..<100 where store.snapshot?.day != day || store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
                try requireRegression(store.timezone == day.timezone && store.selectedDay == day && store.snapshot?.day == day, "Route queried a different timezone/day")
                try requireRegression(store.selectedSession != nil, "Session selection was lost during configuration reset")
                await store.waitForHistoryBackfill()
            }
        }
    }

    @MainActor private static func withStore(_ action: (UsageStore, RegressionService, RegressionClock) async throws -> Void) async throws {
        let suite = "LLMUsage.Regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = RegressionService(), clock = RegressionClock()
        let store = UsageStore(service: service, repository: RegressionRepository(), defaults: defaults,
                               now: { clock.now }, reloadWidget: {})
        try await action(store, service, clock)
        await store.waitForHistoryBackfill()
    }
}
