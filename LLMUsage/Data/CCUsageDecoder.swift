import Foundation

enum CCUsageDecoder {
    enum Report: Sendable { case claude, unified }

    static func decode(_ data: Data, day: UsageDay, now: Date = Date(), report: Report? = nil) throws -> UsageSnapshot {
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            if report == .unified && !payload.unified {
                throw UsageError.malformedJSON("Нужен общий отчёт ccusage session с полями session, agent и period. Обновите ccusage до версии с поддержкой всех источников (проверено с 20.0.26).")
            }
            if report == .claude && payload.unified {
                throw UsageError.malformedJSON("Expected ccusage claude session report with a sessions array")
            }
            guard payload.sessions.count <= 100_000 else { throw UsageError.outputTooLarge }
            var sessions = try payload.sessions.map { try $0.normalized(timezone: day.timezone, unified: payload.unified) }
            if report == .claude {
                // Keep identities stable across collection modes and distinct from other agents.
                for index in sessions.indices {
                    sessions[index].id = UsageSource.sessionID(agent: "claude", rawID: sessions[index].rawID)
                }
            }
            guard Set(sessions.map(\.id)).count == sessions.count else {
                throw UsageError.malformedJSON("Duplicate source/session identity in ccusage response")
            }
            return .init(generatedAt: now, day: day, sessions: sessions)
        } catch let error as UsageError { throw error }
        catch { throw UsageError.malformedJSON(String(describing: error)) }
    }

    private struct Payload: Decodable {
        var sessions: [SessionDTO]
        var unified: Bool
        enum CodingKeys: String, CodingKey { case session, sessions }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // Require a recognized report: {} or a daily report must not erase good data.
            unified = values.contains(.session)
            sessions = try values.decode([SessionDTO].self, forKey: unified ? .session : .sessions)
        }
    }

    private struct Metadata: Decodable {
        var lastActivity: String?
        var projectPath: String?
        var reasoningOutputTokens: Int64?
    }

    private struct SessionDTO: Decodable {
        var period: String?
        var agent: String?
        var sessionId: String?
        var modelsUsed: [String]?
        var models: [String]?
        var inputTokens: Int64?
        var outputTokens: Int64?
        var cacheCreationTokens: Int64?
        var cacheReadTokens: Int64?
        var totalTokens: Int64?
        var totalCost: Double?
        var lastActivity: String?
        var projectPath: String?
        var modelBreakdowns: [ModelDTO]?
        var metadata: Metadata?

        func normalized(timezone: String, unified: Bool) throws -> UsageSession {
            let rawID = unified ? period : sessionId
            let source = unified ? agent : "claude"
            guard let rawID, !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UsageError.malformedJSON("Missing session ID or agent in ccusage response")
            }
            var usage = try validatedUsage(input: inputTokens, output: outputTokens, create: cacheCreationTokens,
                                           read: cacheReadTokens, total: totalTokens, cost: totalCost)
            let breakdowns = try (modelBreakdowns ?? []).map { try $0.normalized() }
            if breakdowns.contains(where: { $0.usage.costIsIncomplete == true }) { usage.costIsIncomplete = true }
            let names = modelsUsed ?? models ?? breakdowns.map(\.id)
            let activity = metadata?.lastActivity ?? lastActivity
            let reasoning = metadata?.reasoningOutputTokens
            if let reasoning, !(0...1_000_000_000_000).contains(reasoning) {
                throw UsageError.malformedJSON("Out-of-range reasoning token count")
            }
            return UsageSession(id: unified ? UsageSource.sessionID(agent: source, rawID: rawID) : rawID,
                                models: Array(Set(names.filter { !$0.isEmpty })).sorted(), usage: usage,
                                lastActivity: parseDate(activity, timezone: timezone),
                                activityHasTime: activity?.contains("T") ?? false,
                                projectPath: metadata?.projectPath ?? projectPath, modelBreakdowns: breakdowns,
                                agent: source, originalID: rawID, reasoningOutputTokens: reasoning)
        }
    }

    private struct ModelDTO: Decodable {
        var modelName: String?
        var model: String?
        var inputTokens: Int64?
        var outputTokens: Int64?
        var cacheCreationTokens: Int64?
        var cacheReadTokens: Int64?
        var totalTokens: Int64?
        var cost: Double?
        var totalCost: Double?
        var missingPricing: Bool?

        func normalized() throws -> ModelUsage {
            var usage = try validatedUsage(input: inputTokens, output: outputTokens, create: cacheCreationTokens,
                                           read: cacheReadTokens, total: totalTokens, cost: totalCost ?? cost)
            if missingPricing == true { usage.costIsIncomplete = true }
            return .init(id: modelName ?? model ?? "", usage: usage)
        }
    }

    private static func validatedUsage(input: Int64?, output: Int64?, create: Int64?, read: Int64?,
                                       total: Int64?, cost: Double?) throws -> TokenUsage {
        let values: [Int64] = [input ?? 0, output ?? 0, create ?? 0, read ?? 0]
        guard values.allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000_000 }),
              (cost ?? 0).isFinite, (cost ?? 0) >= 0, (cost ?? 0) <= 1_000_000_000_000 else {
            throw UsageError.malformedJSON("Negative, non-finite or out-of-range usage value")
        }
        let components = values.reduce(0, +)
        if let total, total < components || total > 5_000_000_000_000 {
            throw UsageError.malformedJSON("Total token count is inconsistent with its components")
        }
        return .init(input: values[0], output: values[1], cacheCreate: values[2], cacheRead: values[3], cost: cost ?? 0,
                     additional: (total ?? components) - components, costIsIncomplete: cost == nil)
    }

    private static func parseDate(_ string: String?, timezone: String) -> Date? {
        guard let string else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = iso.date(from: string) { return value }
        iso.formatOptions = [.withInternetDateTime]
        if let value = iso.date(from: string) { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timezone)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}
