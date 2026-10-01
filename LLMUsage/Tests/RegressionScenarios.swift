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
    var modes: [UsageUpdateMode] = []
    var fixtureSessions: [UsageSession]?
    func setSessions(_ sessions: [UsageSession]) { fixtureSessions = sessions }
    private var holdNext = false
    private var release: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func holdNextRequest() { holdNext = true }
    func waitUntilHeld() async {
        if release != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func finishHeldRequest() { release?.resume(); release = nil }
    func configure(cost: Double, at date: Date, fails: Bool = false) {
        self.cost = cost; timestamp = date; self.fails = fails
    }
    func fetch(day: UsageDay, customPath: String, mode: UsageUpdateMode) async throws -> UsageSnapshot {
        requests.append(day)
        modes.append(mode)
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                release = continuation
                waiting?.resume(); waiting = nil
            }
        }
        if fails { throw UsageError.timedOut }
        return .init(generatedAt: timestamp, day: day,
                     sessions: fixtureSessions ?? [.init(id: "s-" + day.key, models: ["test"], usage: .init(cost: mode == .allAgents ? cost + 10 : cost))])
    }
    func count(_ day: UsageDay) -> Int { requests.filter { $0 == day }.count }
    func diagnose(customPath: String, forceDetect: Bool) -> CLIDiagnostics { .init(path: "fixture", version: "1") }
}

/// Exercises the actual resolver/process/decoder pipeline without accessing user logs.
private struct RegressionCLI {
    let directory: URL
    var executable: String { directory.appendingPathComponent("ccusage").path }
    static let claude = #"{"sessions":[{"sessionId":"shared","modelsUsed":["opus"],"inputTokens":20,"outputTokens":2,"totalTokens":22,"totalCost":2,"lastActivity":"2026-09-28T12:00:00Z","projectPath":"/fixture/project","modelBreakdowns":[{"modelName":"opus","inputTokens":20,"outputTokens":2,"cost":2}]}],"totals":{"totalCost":999}}"#
    static let unified = #"{"session":[{"agent":"claude","period":"shared","inputTokens":100,"totalCost":10},{"agent":"claude","period":"outside-day","inputTokens":200,"totalCost":20},{"agent":"codex","period":"shared","modelsUsed":["gpt"],"inputTokens":30,"totalCost":3},{"agent":"future-agent","period":"future","inputTokens":5}],"totals":{"totalCost":999}}"#

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LLM Usage CLI \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        fixture_dir="${0%/*}"
        printf '%s\\n' "$*" >> "$fixture_dir/requests"
        case "$1" in
          claude) report=claude ;;
          session) report=unified ;;
          *) exit 9 ;;
        esac
        if [ -f "$fixture_dir/fail-$report" ]; then
          printf '%s\\n' "fixture $report failed" >&2
          exit 7
        fi
        /bin/cat "$fixture_dir/$report.json"
        """
        try script.write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
        try write(Self.claude, name: "claude.json")
        try write(Self.unified, name: "unified.json")
    }
    func write(_ text: String, name: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func requests() throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent("requests"), encoding: .utf8).split(separator: "\n").map(String.init)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
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

private actor RegressionPricing: ClaudePricingProviding {
    var calls = 0
    func refresh() throws -> ClaudePricingOverrides {
        calls += 1
        return try ClaudePricingCache.parse(PricingScenarios.catalog)
    }
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
        await check("Amounts: exclusions and missing prices retain the dollar sign without inequality symbols") {
            let language = L10n.preference
            defer { L10n.preference = language }
            for locale in [InterfaceLanguage.english, .russian] {
                L10n.preference = locale
                for amount in [0.0, 4.5, 75.95, 123.45, 1_234, 1_234_567] {
                    let normal = TokenUsage(cost: amount)
                    let partial = TokenUsage(cost: amount, costIsIncomplete: true)
                    for formatted in [UsageFormat.cost(partial), UsageFormat.menuBarCost(partial)] {
                        try requireRegression(formatted.hasPrefix("$") && !formatted.contains("≥"), "Currency vanished or an inequality symbol was added")
                    }
                    try requireRegression(UsageFormat.cost(normal) == UsageFormat.cost(partial)
                        && UsageFormat.menuBarCost(normal) == UsageFormat.menuBarCost(partial), "Missing-price status changed amount styling")
                }
            }
        }
        await check("Model exclusions: provider defaults, exact overrides and reversible mixed sessions") {
            var policy = ModelExclusionPolicy()
            for model in ["GLM-5", "glm4.7", "zai/custom", "z-ai/glm-4.5", "openrouter/z-ai/glm-5", "z.ai:model"] {
                try requireRegression(!policy.includes(model), "Z.ai default missed: \(model)")
            }
            for model in ["gpt-6", "claude-opus", "my-glm-wrapper", "glmish", "other-zai-model"] {
                try requireRegression(policy.includes(model), "Unrelated model excluded: \(model)")
            }
            let session = UsageSession(id: "mixed", models: ["GLM-5", "paid"], usage: .init(input: 30, cost: 9),
                modelBreakdowns: [.init(id: "GLM-5", usage: .init(input: 10, cost: 6)),
                                  .init(id: "paid", usage: .init(input: 20, cost: 3))])
            let raw = UsageSnapshot(generatedAt: Date(), day: .init(), sessions: [session])
            let adjusted = raw.applyingExclusions(policy)
            try requireRegression(adjusted.totals.cost == 3 && adjusted.totals.total == 20 && adjusted.sessions.count == 1, "Excluded cost or tokens incorrect")
            try requireRegression(adjusted.sourceSummaries.first?.usage.cost == 3 && adjusted.modelSummaries.reduce(0) { $0 + $1.usage.cost } == 3, "Screen totals disagree")
            try requireRegression(adjusted.applyingExclusions(policy) == adjusted, "Repeated application subtracts cost again")
            policy.overrides["glm-5"] = true
            try requireRegression(adjusted.applyingExclusions(policy) == raw, "Re-inclusion failed to restore the original estimate")
            policy.overrides["paid"] = false
            try requireRegression(raw.applyingExclusions(policy).totals.cost == 6, "Explicit override did not win")
            let roundTrip = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(adjusted))
            try requireRegression(roundTrip.applyingExclusions(policy).totals.cost == 6, "Saved raw costs cannot be reprojected")
        }
        await check("Model exclusions: unknown prices and incomplete mixed breakdowns preserve ordinary totals") {
            let policy = ModelExclusionPolicy()
            let unpriced = UsageSession(id: "z", models: ["glm-5"], usage: .init(input: 12, costIsIncomplete: true))
            try requireRegression(unpriced.applyingExclusions(policy).usage.costIsIncomplete != true, "Excluded unknown price makes paid totals incomplete")
            let mixed = UsageSession(id: "m", models: ["glm-5", "paid"], usage: .init(input: 12, cost: 9),
                modelBreakdowns: [.init(id: "glm-5", usage: .init(input: 2, cost: 1))])
            let result = mixed.applyingExclusions(policy)
            try requireRegression(result.usage.cost == 0 && result.usage.costIsIncomplete != true && result.usage.total == 0, "An excluded mixed allocation changed amount styling or remained in totals")
            var included = policy
            included.overrides["glm-5"] = true
            try requireRegression(result.applyingExclusions(included) == mixed, "Incomplete session did not round-trip")
            let unknown = UsageSession(id: "u", models: [], usage: .init(input: 10, cost: 2, costIsIncomplete: true))
            try requireRegression(unknown.applyingExclusions(policy) == unknown, "Unknown-model session silently excluded")
        }
        await check("Model exclusions: history, old cache migration and widget policy round-trip") {
            let day = UsageDay()
            let context = UsageDataContext(timezone: day.timezone, customPath: "")
            let raw = UsageSnapshot(dataContext: context, generatedAt: Date(), day: day,
                sessions: [.init(id: "z", models: ["glm-5"], usage: .init(input: 10, cost: 6)),
                           .init(id: "p", models: ["paid"], usage: .init(input: 20, cost: 3))])
            var history = UsageHistory(context: context)
            history.record(raw, today: day)
            let projected = history.applyingExclusions(.init())
            try requireRegression(projected.days.first?.usage.cost == 3 && projected.days.first?.usage.total == 20, "Historical cost differs from snapshot")
            let policy = ModelExclusionPolicy(overrides: ["glm-5": true, "paid": false])
            let restored = try JSONDecoder().decode(UsageHistory.self, from: JSONEncoder().encode(projected))
            try requireRegression(restored.applyingExclusions(policy).days.first?.usage.cost == 6, "Historical raw costs were discarded")
            var legacy = history
            legacy.days[0].usageComponents = nil
            try requireRegression(legacy.applyingExclusions(policy).days.isEmpty, "Unattributed legacy history shown as recalculated")
            let status = RefreshStatus(attemptedAt: Date(), message: nil, refreshMinutes: 15, modelExclusionPolicy: policy)
            let saved = try JSONDecoder().decode(RefreshStatus.self, from: JSONEncoder().encode(status))
            try requireRegression(raw.applyingExclusions(saved.modelExclusionPolicy!).totals.cost == 6, "Widget did not receive current cost rules")
            var rounding = raw
            rounding.sessions = [.init(id: "rounding", models: ["paid"], usage: .init(input: 3, cost: 0.0051, costIsIncomplete: true),
                modelBreakdowns: [.init(id: "paid", usage: .init(input: 3, cost: 0.0049))])]
            let daily = DailyUsageTotal(snapshot: rounding).applyingExclusions(.init())
            try requireRegression(daily?.usage == rounding.totals, "History changed unexcluded CLI rounding or incomplete-pricing status")
        }
        await check("Models reference: excluded amounts stay visible only in the reference projection") {
            let excluded = TokenUsage(input: 10, output: 20, cacheCreate: 30, cacheRead: 40, cost: 5, additional: 50)
            let included = TokenUsage(input: 60, cost: 2)
            let manual = TokenUsage(output: 70, cost: 8)
            let raw = UsageSnapshot(generatedAt: Date(), day: .init(), sessions: [
                .init(id: "default", models: ["GLM-5"], usage: excluded),
                .init(id: "included", models: ["paid"], usage: included),
                .init(id: "manual", models: ["manual-model"], usage: manual, agent: "codex")
            ])
            var policy = ModelExclusionPolicy(overrides: ["manual-model": false])
            let adjusted = raw.applyingExclusions(policy)
            let models = adjusted.reportedModelSummaries(applying: policy)
            try requireRegression(models.map(\.id) == ["manual-model", "GLM-5", "paid"], "Reference order uses excluded zero costs")
            try requireRegression(models[0].isExcluded && models[1].isExcluded && !models[2].isExcluded,
                                  "Default/manual exclusions were not labeled")
            for (name, usage) in [("GLM-5", excluded), ("paid", included), ("manual-model", manual)] {
                let row = models.first { $0.id == name }!
                try requireRegression(row.usage.total == usage.total && row.usage.cost == usage.cost
                    && row.usage.categories.allSatisfy { row.usage.value(for: $0) == usage.value(for: $0) },
                                      "Reference details lost a token category or original cost")
            }
            try requireRegression(adjusted.totals.total == included.total && adjusted.totals.cost == included.cost
                && adjusted.sessions.first?.usage.total == 0 && adjusted.sessions.first?.usage.cost == 0,
                                  "Reference amounts leaked into overview/menu/session/widget totals")
            try requireRegression(adjusted.modelSummaries.reduce(0) { $0 + $1.usage.cost } == 2
                && adjusted.sourceSummaries.reduce(0) { $0 + $1.usage.cost } == 2, "Accounted summaries changed")
            let filtered = adjusted.filtered(source: "codex").reportedModelSummaries(applying: policy)
            try requireRegression(filtered.count == 1 && filtered[0].id == "manual-model" && filtered[0].usage.cost == 8,
                                  "Reference view ignored the source filter")
            policy.overrides["glm-5"] = true
            policy.overrides["manual-model"] = true
            let restored = adjusted.applyingExclusions(policy)
            let rows = restored.reportedModelSummaries(applying: policy)
            try requireRegression(rows.allSatisfy { !$0.isExcluded } && restored.totals.cost == 15
                && rows.map(\.usage) == models.map(\.usage), "Re-inclusion changed the reference values")
            let roundTrip = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(adjusted))
            try requireRegression(roundTrip.reportedModelSummaries(applying: .init(overrides: ["manual-model": false])) == models,
                                  "Saved exclusions lost reference rows after restart")
        }
        await check("Models reference: complete and incomplete mixed sessions never duplicate usage") {
            let raw = UsageSnapshot(generatedAt: Date(), day: .init(), sessions: [
                .init(id: "complete", models: ["glm-5", "paid"], usage: .init(input: 30, cost: 9),
                    modelBreakdowns: [.init(id: "glm-5", usage: .init(input: 10, cost: 6)),
                                      .init(id: "paid", usage: .init(input: 20, cost: 3))]),
                .init(id: "incomplete", models: ["paid", "glm-5"], usage: .init(input: 40, cost: 12),
                    modelBreakdowns: [.init(id: "glm-5", usage: .init(input: 2, cost: 1))]),
                .init(id: "incomplete-reversed", models: ["glm-5", "paid"], usage: .init(input: 5, cost: 1)),
                .init(id: "unknown", models: [], usage: .init(input: 7, cost: 2))
            ])
            let adjusted = raw.applyingExclusions(.init())
            let rows = adjusted.reportedModelSummaries(applying: .init())
            let mixed = rows.first { $0.id == "glm-5, paid" }
            try requireRegression(rows.count == 4 && mixed?.usage.total == 45 && mixed?.usage.cost == 13
                && mixed?.sessionCount == 2 && mixed?.isExcluded == true, "Incomplete breakdown was split, duplicated or mislabeled")
            try requireRegression(rows.reduce(0) { $0 + $1.usage.total } == raw.totals.total
                && rows.reduce(0) { $0 + $1.usage.cost } == raw.totals.cost, "Raw mixed totals disagree")
            try requireRegression(rows.first { $0.id == "paid" }?.usage.cost == 3
                && rows.first { $0.id == "glm-5" }?.usage.cost == 6
                && rows.first { $0.id.isEmpty }?.isExcluded == false, "Complete/unknown allocations changed")
            try requireRegression(adjusted.totals.total == 27 && adjusted.totals.cost == 5, "Mixed exclusions no longer protect totals")
        }
        await check("Models reference: unknown prices and all-excluded days retain raw diagnostics") {
            let raw = UsageSnapshot(generatedAt: Date(), day: .init(), sessions: [
                .init(id: "unpriced", models: ["glm-5"], usage: .init(input: 100, costIsIncomplete: true)),
                .init(id: "priced", models: ["glm-5"], usage: .init(input: 200, cost: 5))
            ])
            let adjusted = raw.applyingExclusions(.init())
            let rows = adjusted.reportedModelSummaries(applying: .init())
            try requireRegression(rows.count == 1 && rows[0].usage.total == 300 && rows[0].usage.cost == 5
                && rows[0].usage.costIsIncomplete == true && rows[0].sessionCount == 2 && rows[0].isExcluded,
                                  "All-excluded reference rows became empty or lost missing-price diagnostics")
            try requireRegression(adjusted.totals.total == 0 && adjusted.totals.cost == 0
                && adjusted.totals.costIsIncomplete != true, "Reference diagnostics polluted accounted totals")
        }
        await check("Model exclusions: store recalculates all dates, persists and survives in-flight refresh") {
            let suite = "CostExclusionRegression.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let clock = RegressionClock(), service = RegressionService(), repository = RegressionRepository()
            await service.setSessions([.init(id: "z", models: ["glm-5"], usage: .init(input: 10, cost: 6)),
                                       .init(id: "p", models: ["paid"], usage: .init(input: 20, cost: 3))])
            let store = UsageStore(service: service, repository: repository, defaults: defaults, now: { clock.now }, reloadWidget: {})
            await store.refresh()
            await store.waitForHistoryBackfill()
            try requireRegression(store.todaySnapshot?.totals.cost == 3 && store.history?.days.count == 7, "Default exclusion did not reach store/history")
            store.period = .custom
            store.customDate = clock.now.addingTimeInterval(-14 * 86400)
            await store.selectPeriod()
            store.setModelIncluded(false, model: " PAID ")
            try requireRegression(store.snapshot?.totals.cost == 0 && store.todaySnapshot?.totals.cost == 0 && store.previousSnapshot?.totals.cost == 0, "A displayed date retained excluded costs")
            try requireRegression(store.history?.days.allSatisfy { $0.usage.cost == 0 && $0.usage.total == 0 } == true, "Seven-day history was not recalculated")
            let historicalReference = store.displaySnapshot!.reportedModelSummaries(applying: store.modelExclusionPolicy)
            try requireRegression(store.displaySnapshot?.day == store.selectedDay && historicalReference.count == 2
                && historicalReference.allSatisfy(\.isExcluded) && historicalReference.reduce(0) { $0 + $1.usage.cost } == 9,
                                  "Changing dates or exclusions erased the Models reference amounts")
            store.setModelIncluded(true, model: "glm-5")
            try requireRegression(store.snapshot?.totals.cost == 6, "Re-inclusion requires an unnecessary fetch")
            await service.holdNextRequest()
            let refresh = Task { await store.refresh() }
            await service.waitUntilHeld()
            store.setModelIncluded(true, model: "paid")
            await service.finishHeldRequest()
            await refresh.value
            await store.waitForHistoryBackfill()
            try requireRegression(store.snapshot?.totals.cost == 9 && store.todaySnapshot?.totals.cost == 9, "In-flight refresh overwrote the new policy")
            await service.configure(cost: 1, at: clock.now, fails: true)
            let reopened = UsageStore(service: service, repository: repository, defaults: defaults, now: { clock.now }, reloadWidget: {})
            await reopened.refresh()
            try requireRegression(reopened.todaySnapshot?.totals.cost == 9 && reopened.modelExclusionPolicy == store.modelExclusionPolicy, "Restart/offline restoration lost model choices")
            let status = await repository.readStatus()
            let stored = await repository.read(.today)
            try requireRegression(stored?.applyingExclusions(status?.modelExclusionPolicy ?? .init()).totals.cost == 9, "Widget and app amounts disagree")
            store.setModelIncluded(false, model: "future-model")
            let coldStore = UsageStore(service: service, repository: repository, defaults: defaults, now: { clock.now }, reloadWidget: {})
            try requireRegression(coldStore.snapshot == nil && coldStore.excludedModels.contains("future-model"),
                                  "The excluded-model list is unavailable before a report loads")
            clock.now = clock.now.addingTimeInterval(86400)
            await service.configure(cost: 1, at: clock.now)
            await service.setSessions([.init(id: "future", models: ["future-model"],
                usage: .init(input: 10, output: 20, cacheCreate: 30, cacheRead: 40, cost: 50, additional: 60))])
            await store.refresh()
            await store.waitForHistoryBackfill()
            try requireRegression(store.todaySnapshot?.totals.total == 0 && store.todaySnapshot?.totals.cost == 0,
                                  "A saved exclusion missed future activity or a token category")
        }
        await check("Update mode: Claude only runs one dated command with stable session IDs") {
            let cli = try RegressionCLI()
            defer { cli.remove() }
            let day = UsageDay(date: ISO8601DateFormatter().date(from: "2026-09-28T18:00:00Z")!)
            let snapshot = try await CCUsageService(pricing: EmptyPricingFixture()).fetch(day: day, customPath: cli.executable)
            let requests = try cli.requests()
            try requireRegression(requests == ["claude session --json --since 20260928 --until 20260928 --timezone UTC --mode calculate --order desc --no-offline"], "Default mode ran another command or widened the day")
            try requireRegression(snapshot.sessions.count == 1 && snapshot.totals.total == 22 && snapshot.totals.cost == 2, "Claude report totals were lost")
            let session = snapshot.sessions[0]
            try requireRegression(session.id == UsageSource.sessionID(agent: "claude", rawID: "shared") && session.rawID == "shared", "Claude identity is not source-qualified")
            try requireRegression(session.projectPath == "/fixture/project" && session.lastActivity != nil && session.modelBreakdowns.first?.usage.cost == 2, "Claude metadata or model breakdown lost")
        }
        await check("Update mode: all agents replaces whole-session Claude totals and preserves other sources") {
            let cli = try RegressionCLI()
            defer { cli.remove() }
            let day = UsageDay(date: ISO8601DateFormatter().date(from: "2026-09-28T18:00:00Z")!, timezone: "Europe/Moscow")
            let service = CCUsageService(pricing: EmptyPricingFixture())
            let snapshot = try await service.fetch(day: day, customPath: cli.executable, mode: .allAgents)
            let requests = try cli.requests()
            try requireRegression(requests.count == 2 && Set(requests.map { $0.components(separatedBy: " --json")[0] }) == ["claude session", "session"], "All-agent mode did not issue exactly both reports")
            try requireRegression(requests.allSatisfy { $0.contains("--since 20260928 --until 20260928 --timezone Europe/Moscow") }, "Report bounds or timezone diverged")
            try requireRegression(snapshot.sessions.count == 3 && snapshot.totals.total == 57 && snapshot.totals.cost == 5, "Claude was appended or lifetime totals were retained")
            try requireRegression(Set(snapshot.sessions.map(\.id)).count == 3 && snapshot.sessions.filter { $0.sourceID == "claude" }.count == 1, "Cross-agent IDs collided")
            try requireRegression(snapshot.sessions.contains { $0.sourceID == "future-agent" } && snapshot.totals.costIsIncomplete == true, "Other agents or incomplete pricing lost")
            let focused = try await service.fetch(day: day, customPath: cli.executable, mode: .claudeOnly)
            try requireRegression(snapshot.sessions.first { $0.sourceID == "claude" } == focused.sessions.first, "Switching modes changed Claude identity or metadata")
        }
        await check("Pricing: both reports share one private config and clean it up on success/failure") {
            let cli = try RegressionCLI()
            defer { cli.remove() }
            let pricing = RegressionPricing()
            let service = CCUsageService(pricing: pricing)
            _ = try await service.fetch(day: UsageDay(), customPath: cli.executable, mode: .allAgents)
            var requests = try cli.requests()
            let paths = requests.compactMap { $0.components(separatedBy: " --config ").dropFirst().first }
            let calls = await pricing.calls
            try requireRegression(calls == 1 && paths.count == 2 && Set(paths).count == 1,
                                  "Reports did not receive the same pricing config")
            try requireRegression(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "Temporary config leaked after success")
            try cli.write("fail", name: "fail-claude")
            do {
                _ = try await service.fetch(day: UsageDay(), customPath: cli.executable)
                throw RegressionFailure(description: "Failed CLI report succeeded")
            } catch UsageError.processFailed(7, _) { }
            requests = try cli.requests()
            let path = requests.last!.components(separatedBy: " --config ").last!
            try requireRegression(!FileManager.default.fileExists(atPath: path), "Temporary config leaked after failure")
        }
        await check("Update mode: empty unified report recovers Claude and empty Claude removes stale rows") {
            let cli = try RegressionCLI()
            defer { cli.remove() }
            let service = CCUsageService(pricing: EmptyPricingFixture()), day = UsageDay()
            try cli.write(#"{"session":[]}"#, name: "unified.json")
            let recovered = try await service.fetch(day: day, customPath: cli.executable, mode: .allAgents)
            try requireRegression(recovered.sessions.count == 1 && recovered.totals.total == 22, "The reported empty-unified regression was not recovered")
            try cli.write(RegressionCLI.unified, name: "unified.json")
            try cli.write(#"{"sessions":[]}"#, name: "claude.json")
            let emptyClaude = try await service.fetch(day: day, customPath: cli.executable, mode: .allAgents)
            try requireRegression(emptyClaude.sessions.count == 2 && emptyClaude.sessions.allSatisfy { $0.sourceID != "claude" } && emptyClaude.totals.total == 35, "An empty focused day retained unified Claude lifetime usage")
        }
        await check("Update mode: either failed or malformed report rejects partial all-agent results") {
            let cli = try RegressionCLI()
            defer { cli.remove() }
            for report in ["claude", "unified"] {
                try cli.write("fail", name: "fail-" + report)
                do {
                    _ = try await CCUsageService(pricing: EmptyPricingFixture()).fetch(day: UsageDay(), customPath: cli.executable, mode: .allAgents)
                    throw RegressionFailure(description: "A failed \(report) report was accepted as a partial success")
                } catch UsageError.processFailed(7, _) { }
                try FileManager.default.removeItem(at: cli.directory.appendingPathComponent("fail-" + report))
                // A valid JSON document in the wrong report format must also fail.
                try cli.write(report == "claude" ? #"{"session":[]}"# : #"{"sessions":[]}"#, name: report + ".json")
                do {
                    _ = try await CCUsageService(pricing: EmptyPricingFixture()).fetch(day: UsageDay(), customPath: cli.executable, mode: .allAgents)
                    throw RegressionFailure(description: "The wrong \(report) schema was accepted")
                } catch UsageError.malformedJSON { }
                try cli.write(report == "claude" ? RegressionCLI.claude : RegressionCLI.unified, name: report + ".json")
            }
        }
        await check("Update mode: defaults, persisted preference, history and widget contexts remain isolated") {
            let suite = "LLMUsage.UpdateMode.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let service = RegressionService(), repository = RegressionRepository(), clock = RegressionClock()
            let store = UsageStore(service: service, repository: repository, defaults: defaults, now: { clock.now }, reloadWidget: {})
            try requireRegression(store.updateMode == .claudeOnly, "New installs must default to Claude only")
            await store.refresh(); await store.waitForHistoryBackfill()
            store.updateMode = .allAgents
            try requireRegression(store.snapshot == nil && store.history == nil && store.todaySnapshot == nil, "Mode switch left old data visible")
            await store.selectPeriod(); await store.waitForHistoryBackfill()
            let allRequests = await service.modes
            try requireRegression(allRequests == Array(repeating: .claudeOnly, count: 7) + Array(repeating: .allAgents, count: 7), "Selected mode was not used for today and history")
            let history = await repository.readHistory(), status = await repository.readStatus()
            try requireRegression(history?.context.updateMode == .allAgents && status?.dataContext?.updateMode == .allAgents && store.todaySnapshot?.totals.cost == 11, "Widget/history context did not follow mode")
            let restarted = UsageStore(service: service, repository: repository, defaults: defaults, now: { clock.now }, reloadWidget: {})
            try requireRegression(restarted.updateMode == .allAgents, "Mode preference was not persisted")
            store.sourceFilter = "codex"; store.selectedSessionID = "old-selection"
            store.updateMode = .claudeOnly
            try requireRegression(store.sourceFilter.isEmpty && store.selectedSessionID == nil && store.previousSnapshot == nil, "Old source filter or selection survived mode change")
            await store.selectPeriod(); await store.waitForHistoryBackfill()
            try requireRegression(store.todaySnapshot?.totals.cost == 1 && store.history?.days.allSatisfy { $0.usage.cost == 1 } == true, "All-agent amounts leaked into Claude history")
        }
        await check("Update mode: legacy cache and cache from another mode are not restored") {
            let legacy = try JSONDecoder().decode(UsageDataContext.self, from: Data(#"{"timezone":"UTC","customPath":""}"#.utf8))
            try requireRegression(legacy.updateMode == nil && legacy != UsageDataContext(timezone: "UTC", customPath: ""), "Legacy unified cache was reinterpreted as corrected Claude data")
            for mode in UsageUpdateMode.allCases {
                let context = UsageDataContext(timezone: "UTC", customPath: "", updateMode: mode)
                let decoded = try JSONDecoder().decode(UsageDataContext.self, from: JSONEncoder().encode(context))
                try requireRegression(decoded == context, "Mode was lost during cache round-trip")
            }
            for context in [legacy, UsageDataContext(timezone: "UTC", customPath: "", updateMode: .allAgents)] {
                let suite = "LLMUsage.ModeCache.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let clock = RegressionClock(), service = RegressionService(), repository = RegressionRepository()
                var old = UsageSnapshot(generatedAt: clock.now, day: UsageDay(date: clock.now), sessions: [])
                old.dataContext = context
                await repository.write(old, to: .today)
                await repository.writeHistory(UsageHistory(context: context, days: [DailyUsageTotal(snapshot: old)]))
                await service.configure(cost: 1, at: clock.now, fails: true)
                let store = UsageStore(service: service, repository: repository, defaults: defaults, now: { clock.now }, reloadWidget: {})
                await store.refresh()
                try requireRegression(store.snapshot == nil && store.history == nil && store.state == .error, "An incompatible saved cache masked a failed new-mode fetch")
            }
        }
        await check("Update mode: switching during refresh discards the late old-mode result") {
            let suite = "LLMUsage.ModeInFlight.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let clock = RegressionClock(), service = RegressionService(), repository = RegressionRepository()
            let store = UsageStore(service: service, repository: repository, defaults: defaults, now: { clock.now }, reloadWidget: {})
            store.updateMode = .allAgents
            await service.holdNextRequest()
            let refresh = Task { await store.refresh() }
            await service.waitUntilHeld()
            store.updateMode = .claudeOnly
            await service.finishHeldRequest()
            await refresh.value
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while store.todaySnapshot == nil || store.isRefreshing {
                guard ContinuousClock.now < deadline else { throw RegressionFailure(description: "New mode was not fetched after the old request finished") }
                try await Task.sleep(for: .milliseconds(10))
            }
            await store.waitForHistoryBackfill()
            let saved = await repository.read(.today)
            try requireRegression(store.todaySnapshot?.totals.cost == 1 && saved?.dataContext?.updateMode == .claudeOnly && saved?.totals.cost == 1, "Late all-agent result overwrote Claude-only data")
        }
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
