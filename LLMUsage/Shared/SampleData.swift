import Foundation

enum SampleData {
    static func snapshot(now: Date = Date()) -> UsageSnapshot {
        .init(generatedAt: now, day: .init(date: now), sessions: [
            .init(id: "11111111-1111-4111-8111-111111111111", models: ["opus-5-5"],
                  usage: .init(input: 50, output: 19_149, cacheCreate: 385_620, cacheRead: 4_222_399, cost: 3.16),
                  lastActivity: now.addingTimeInterval(-600)),
            .init(id: "22222222-2222-4222-8222-222222222222", models: ["opus-5-5"],
                  usage: .init(input: 64, output: 26_439, cacheCreate: 234_966, cacheRead: 3_054_921, cost: 2.31),
                  lastActivity: now.addingTimeInterval(-3060))
        ])
    }
    static func multiSourceSnapshot(now: Date = Date()) -> UsageSnapshot {
        var data = snapshot(now: now)
        for index in data.sessions.indices {
            let rawID = data.sessions[index].id
            data.sessions[index].agent = "claude"
            data.sessions[index].originalID = rawID
            data.sessions[index].id = UsageSource.sessionID(agent: "claude", rawID: rawID)
        }
        data.sessions.append(.init(id: UsageSource.sessionID(agent: "codex", rawID: "01a0b123-1234-5678-9abc-0123456789ab"),
                                   models: ["gpt-6-astra"],
                                   usage: .init(input: 280_000, output: 65_000, cacheRead: 5_000_000, cost: 8.72),
                                   lastActivity: now.addingTimeInterval(-120), agent: "codex",
                                   originalID: "01a0b123-1234-5678-9abc-0123456789ab", reasoningOutputTokens: 12_000))
        data.sessions.append(.init(id: UsageSource.sessionID(agent: "gemini", rawID: "b804bac7-1234-5678-9abc-0123456789ab"),
                                   models: ["gemini-3-pro-preview"],
                                   usage: .init(input: 120_000, output: 7_800, cacheRead: 450_000, cost: 0.91, additional: 3_200),
                                   lastActivity: now.addingTimeInterval(-900), agent: "gemini",
                                   originalID: "b804bac7-1234-5678-9abc-0123456789ab"))
        return data
    }

}

extension SampleData {
    /// Deliberate fixtures for demo mode and production-view previews only.
    static func history(now: Date = Date(), context: UsageDataContext = .init(timezone: "UTC", customPath: "")) -> UsageHistory {
        let today = UsageDay(date: now, timezone: context.timezone)
        var result = UsageHistory(context: context)
        for (offset, cost) in zip(-6...0, [12.4, 18.9, 8.25, 0, 27.4, 16.3, 23.36]) {
            var snapshot = multiSourceSnapshot(now: now)
            snapshot.dataContext = context
            snapshot.day = today.adding(days: offset)
            snapshot.sessions = [UsageSession(id: "history-fixture-\(offset)", models: ["fixture"],
                                             usage: TokenUsage(cost: cost), lastActivity: nil)]
            result.record(snapshot, today: today)
        }
        return result
    }
}
