import Foundation
import CoreFoundation

/// Session snapshots include background calls absent from assistant messages.
/// Recover only uncached token differences with a proven session/model match;
/// never reuse the snapshot's price with a different set of user tariffs.
enum ClaudeSessionAccounting {
    static func canonical(_ model: String) -> String {
        var value = model.lowercased().split(separator: "/").last.map(String.init) ?? model.lowercased()
        if value.hasSuffix("[1m]") { value.removeLast(4) }
        return value.replacingOccurrences(of: ".", with: "-")
    }

    static func annotate(_ original: SessionTranscript) -> SessionTranscript {
        var result = original
        let records = TranscriptUsageParser.records(original)
        let rows = records.map { ($0, (try? JSONSerialization.jsonObject(with: Data($0.text.utf8))) as? [String: Any] ?? [:]) }
        let snapshots = rows.filter { $0.1["modelUsage"] is [String: Any] }
        guard !snapshots.isEmpty else { return result }
        let sessions = Set(rows.compactMap { _, row -> String? in
            guard row["type"] as? String == "assistant" else { return nil }
            return row["sessionId"] as? String
        })
        guard sessions.count == 1, let session = sessions.first else { result.usageUncertain = true; return result }
        var accepted: [String: TranscriptRequest] = [:]
        for (record, row) in snapshots {
            guard row["sessionId"] as? String == session else { result.usageUncertain = true; continue }
            let prefix = original.requests.filter { $0.sequence <= record.sequence && !$0.isReplay }
            guard !prefix.isEmpty else { result.usageUncertain = true; continue }
            let groups = Dictionary(grouping: prefix, by: { canonical($0.model) })
            var proposal: [String: TranscriptRequest] = [:]
            var valid = true
            var used = Set<String>()
            for (name, value) in TranscriptJSON.object(row["modelUsage"]) {
                let key = canonical(name), raw = TranscriptJSON.object(value)
                let fields = ["inputTokens", "outputTokens", "cacheCreationInputTokens", "cacheReadInputTokens"]
                guard used.insert(key).inserted, let requests = groups[key],
                      Set(requests.map(\.model)).count == 1, let model = requests.first?.model,
                      requests.allSatisfy({ $0.billing.speed != "fast" }),
                      let counts = TranscriptUsageParser.numbers(raw, keys: fields), counts.count == 4,
                      let searches = raw["webSearchRequests"].flatMap(TranscriptUsageParser.number), searches == 0,
                      let price = raw["costUSD"] as? NSNumber, CFGetTypeID(price) != CFBooleanGetTypeID(),
                      price.doubleValue.isFinite, price.doubleValue >= 0 else { valid = false; break }
                let base = requests.reduce(TokenUsage.zero) { $0 + $1.usage }
                guard counts[fields[0]]! >= base.input, counts[fields[1]]! >= base.output,
                      counts[fields[2]] == base.cacheCreate, counts[fields[3]] == base.cacheRead else { valid = false; break }
                let input = counts[fields[0]]! - base.input, output = counts[fields[1]]! - base.output
                // Without individual request boundaries, crossing a tariff tier
                // or a fast/standard mix cannot be priced faithfully.
                guard input < 200_000, output < 200_000,
                      input >= (accepted[key]?.usage.input ?? 0), output >= (accepted[key]?.usage.output ?? 0) else { valid = false; break }
                let requestDates = prefix.compactMap(\.timestamp)
                let dates = requestDates + rows.filter { $0.0.sequence <= record.sequence }.compactMap {
                    TranscriptJSON.date($0.1["timestamp"] ?? $0.1["created_at"])
                }
                guard requestDates.count == prefix.count, let first = dates.min(), let last = dates.max() else { valid = false; break }
                if input + output > 0 {
                    proposal[key] = .init(id: "request-accounting-\(record.sequence)-\(proposal.count)", model: model,
                        timestamp: last, eventIDs: [], billing: .init(tokens: ["input_tokens": input, "output_tokens": output]),
                        usage: .init(input: input, output: output, costIsIncomplete: true), sequence: record.sequence,
                        accountingIntervalStart: first, accountingIntervalEnd: last)
                }
            }
            guard valid, used == Set(groups.keys), Set(accepted.keys).isSubset(of: used) else {
                result.usageUncertain = true; continue
            }
            result.claudeSnapshotValidated = true
            accepted = proposal // A snapshot replaces the previous cumulative one.
        }
        result.requests += accepted.keys.sorted().compactMap { accepted[$0] }
        return result
    }
}
