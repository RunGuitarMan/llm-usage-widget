import Foundation
import CoreFoundation

/// Claude Code writes cumulative session totals with `modelUsage` (2.1.x
/// `cost-state` rows, older metadata rows). They equal `/usage`: subagent calls
/// whose transcript holds only placeholders, background calls and earlier days
/// of a resumed session are included. Every validated snapshot closes one
/// segment; only its remainder over the transcript becomes a supplemental
/// request, dated by that segment. Tariffs remain the report's own.
enum ClaudeSessionAccounting {
    static func canonical(_ model: String) -> String {
        var value = model.lowercased().split(separator: "/").last.map(String.init) ?? model.lowercased()
        if value.hasSuffix("[1m]") { value.removeLast(4) }
        return value.replacingOccurrences(of: ".", with: "-")
    }

    private struct Total: Equatable {
        var input: Int64 = 0, output: Int64 = 0, read: Int64 = 0, write: Int64 = 0, cost: Double = 0
        static func - (lhs: Total, rhs: Total) -> Total {
            .init(input: lhs.input - rhs.input, output: lhs.output - rhs.output, read: lhs.read - rhs.read,
                  write: lhs.write - rhs.write, cost: lhs.cost - rhs.cost)
        }
        var isNonNegative: Bool { input >= 0 && output >= 0 && read >= 0 && write >= 0 && cost >= -1e-9 }
        var isEmpty: Bool { input == 0 && output == 0 && read == 0 && write == 0 }
    }

    private struct Snapshot {
        var sequence: Int
        var origin: String?
        var totals: [String: Total] = [:]
        var names: [String: String] = [:]
        var explicit: Date?
        var through: Date?
        var until: Date?
        var boundary: Date? { explicit ?? through }
    }

    static func annotate(_ original: SessionTranscript) -> SessionTranscript {
        var result = original
        let records = TranscriptUsageParser.records(original)
        let rows = records.map { ($0, (try? JSONSerialization.jsonObject(with: Data($0.text.utf8))) as? [String: Any] ?? [:]) }
        let snapshotRows = rows.filter { $0.1["modelUsage"] is [String: Any] }
        guard !snapshotRows.isEmpty else { return result }
        let sessions = Set(rows.compactMap { _, row -> String? in
            guard row["type"] as? String == "assistant" else { return nil }
            return row["sessionId"] as? String
        })
        guard sessions.count <= 1, let session = sessions.first ?? snapshotRows.first?.1["sessionId"] as? String else {
            result.markUsageUncertain(at: nil); return result
        }
        func date(_ row: [String: Any]) -> Date? { TranscriptJSON.date(row["timestamp"] ?? row["created_at"]) }
        var originOf: [Int: String?] = [:]
        for record in records where originOf[record.sequence] == nil { originOf[record.sequence] = .some(record.origin) }

        let indexes = original.requests.indices.filter { !original.requests[$0].isReplay && !original.requests[$0].isSupplemental }
        var tariffNames: [String: String] = [:], ambiguousNames = Set<String>(), fastModels = Set<String>()
        for (key, items) in Dictionary(grouping: indexes.map { original.requests[$0] }, by: { canonical($0.model) }) {
            let names = Set(items.map(\.model))
            if names.count == 1 { tariffNames[key] = names.first! } else { ambiguousNames.insert(key) }
            if items.contains(where: { $0.billing.speed == "fast" }) { fastModels.insert(key) }
        }
        // A request in the snapshot's own file is ordered by position. Other files
        // (subagents) are ordered by time: a total is written when its process
        // ends, and a resumed process records its prompt before any subagent row.
        func before(_ request: TranscriptRequest, _ snapshot: Snapshot) -> Bool? {
            if let origin = originOf[request.sequence], origin == snapshot.origin { return request.sequence < snapshot.sequence }
            guard let time = request.timestamp else { return nil }
            if let explicit = snapshot.explicit { return time <= explicit }
            guard let until = snapshot.until else { return true }
            return time < until
        }

        let fields = ["inputTokens", "outputTokens", "cacheCreationInputTokens", "cacheReadInputTokens"]
        var baseline: [String: Total] = [:]
        var previous: Snapshot?
        var assigned = Set<Int>(), covered = Set<Int>()
        var proposals: [TranscriptRequest] = []
        var coverage: [ClaudeAccountingCoverage] = []
        var accepted = false
        for (record, row) in snapshotRows {
            var snapshot = Snapshot(sequence: record.sequence, origin: record.origin, explicit: TranscriptJSON.date(row["timestamp"]))
            var parsed = row["sessionId"] as? String == session
            for (name, value) in TranscriptJSON.object(row["modelUsage"]) where parsed {
                let key = canonical(name), raw = TranscriptJSON.object(value)
                guard snapshot.totals[key] == nil,
                      let counts = TranscriptUsageParser.numbers(raw, keys: fields), counts.count == 4,
                      let searches = raw["webSearchRequests"].flatMap(TranscriptUsageParser.number), searches == 0,
                      let price = raw["costUSD"] as? NSNumber, CFGetTypeID(price) != CFBooleanGetTypeID(),
                      price.doubleValue.isFinite, price.doubleValue >= 0 else { parsed = false; break }
                snapshot.totals[key] = .init(input: counts[fields[0]]!, output: counts[fields[1]]!, read: counts[fields[3]]!,
                                             write: counts[fields[2]]!, cost: price.doubleValue)
                snapshot.names[key] = name
            }
            // A foreign or malformed total is not evidence of a segment boundary.
            guard parsed else { result.markUsageUncertain(at: nil); continue }
            var valid = true
            let sameFile = rows.filter { $0.0.origin == record.origin }
            snapshot.through = sameFile.filter { $0.0.sequence < record.sequence }.compactMap { date($0.1) }.max()
            snapshot.until = sameFile.filter { $0.0.sequence > record.sequence }.compactMap { date($0.1) }.min()

            var segment: [Int] = []
            var segmentDates = sameFile.filter { $0.0.sequence <= record.sequence && $0.0.sequence > (previous?.sequence ?? Int.min) }.compactMap { date($0.1) }
            for index in indexes where !assigned.contains(index) {
                let request = original.requests[index]
                guard let isBefore = before(request, snapshot) else {
                    if request.usage.total > 0 || request.countersUnknown { valid = false }
                    continue
                }
                if isBefore { segment.append(index) }
            }
            var observed: [String: Total] = [:]
            for index in segment {
                let request = original.requests[index], key = canonical(request.model)
                guard request.usage.total > 0 || request.countersUnknown else { continue }
                guard let time = request.timestamp else { valid = false; continue }
                segmentDates.append(time)
                var total = observed[key] ?? .init()
                total.input += request.usage.input; total.output += request.usage.output
                total.read += request.usage.cacheRead; total.write += request.usage.cacheCreate
                observed[key] = total
            }
            if !Set(observed.keys).isSubset(of: snapshot.totals.keys) || !ambiguousNames.isDisjoint(with: observed.keys)
                || !fastModels.isDisjoint(with: observed.keys) { valid = false }
            // The cumulative total normally continues across a resume. Claude Code
            // restarts it when another session of the project ended in between.
            func remainders(from base: [String: Total]) -> [String: Total]? {
                guard Set(base.keys).isSubset(of: snapshot.totals.keys) else { return nil }
                var output: [String: Total] = [:]
                for (key, total) in snapshot.totals {
                    var remainder = total - (base[key] ?? .init()) - (observed[key] ?? .init())
                    guard remainder.isNonNegative else { return nil }
                    remainder.cost = max(0, total.cost - (base[key]?.cost ?? 0))
                    output[key] = remainder
                }
                return output
            }
            let remainder = valid ? (remainders(from: baseline) ?? (previous == nil ? nil : remainders(from: [:]))) : nil
            let start = previous?.boundary
            let models = Set(snapshot.totals.keys).union(observed.keys)
            if let remainder {
                for key in remainder.keys.sorted() {
                    let value = remainder[key]!
                    guard !value.isEmpty else { continue }
                    guard let first = segmentDates.min(), let last = segmentDates.max() else { valid = false; break }
                    let model = tariffNames[key] ?? snapshot.names[key].map { $0.hasSuffix("[1m]") ? String($0.dropLast(4)) : $0 } ?? key
                    let shared = segment.filter { canonical(original.requests[$0].model) == key }.map { original.requests[$0].id }
                    proposals.append(.init(id: "request-accounting-\(record.sequence)-\(proposals.count)", model: model,
                        timestamp: last, eventIDs: [], billing: .init(tokens: ["input_tokens": value.input, "output_tokens": value.output,
                            "cache_read_input_tokens": value.read, "cache_creation_input_tokens": value.write]),
                        usage: .init(input: value.input, output: value.output, cacheCreate: value.write, cacheRead: value.read, costIsIncomplete: true),
                        sequence: record.sequence, accountingIntervalStart: first, accountingIntervalEnd: last,
                        snapshotCost: value.cost, snapshotCoveredIDs: shared))
                }
            }
            let isCovered = remainder != nil && valid
            if isCovered {
                accepted = true
                covered.formUnion(segment)
            } else {
                // Keep the known transcript part. Placeholders stay unknown and
                // telemetry may still complete this segment.
                proposals.removeAll { $0.sequence == record.sequence }
                let dates = segment.compactMap { original.requests[$0].timestamp }
                if dates.isEmpty { result.markUsageUncertain(at: nil) } else { for day in Set(dates) { result.markUsageUncertain(at: day) } }
            }
            coverage += models.sorted().map { .init(model: $0, through: snapshot.boundary, until: snapshot.explicit ?? snapshot.until, start: start, covered: isCovered) }
            assigned.formUnion(segment)
            // Later totals are compared with this one even when this segment is
            // unexplained, e.g. a counter restarted inside it.
            baseline = snapshot.totals
            previous = snapshot
        }
        for index in covered { result.requests[index].snapshotCovered = true }
        result.claudeSnapshotValidated = accepted
        result.claudeAccountingCoverage = coverage
        result.requests += proposals
        return result
    }

    /// Restore the cache-write TTL of each remainder from Claude's own cost delta:
    /// the remainder's cost minus the transcript requests of the same segment.
    /// Without a unique solution the 5-minute fallback stays and is disclosed.
    static func resolveCacheTTL(_ transcript: inout SessionTranscript, rates: [String: [String: Double]]) {
        let byID = Dictionary(transcript.requests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var fallback = false
        for index in transcript.requests.indices {
            let request = transcript.requests[index]
            guard request.isSupplemental, let delta = request.snapshotCost else { continue }
            guard let rate = ClaudeTelemetryReconciler.rate(for: request.model, in: rates) else {
                if request.usage.cacheCreate > 0 { fallback = true }
                continue
            }
            if ClaudeCacheTTL.isTiered(rate), request.usage.input + request.usage.cacheRead + request.usage.cacheCreate > 200_000 {
                // A tiered tariff cannot be applied to an aggregate faithfully.
                transcript.markUsageUncertain(at: request.timestamp)
            }
            guard request.usage.cacheCreate > 0 else { continue }
            var shared = 0.0
            var solvable = true
            for id in request.snapshotCoveredIDs {
                guard let other = byID[id], let cost = ClaudeCacheTTL.cost(other, rates: rate) else { solvable = false; break }
                shared += cost
            }
            if solvable, let split = ClaudeCacheTTL.split(cost: delta - shared, input: request.usage.input, output: request.usage.output,
                                                          read: request.usage.cacheRead, write: request.usage.cacheCreate, rates: rate) {
                transcript.requests[index].billing.cacheCreation = split
            } else { fallback = true }
        }
        if fallback {
            let notice = L10n.text("Для записи кэша без разбивки TTL применена ставка 5 минут.")
            if !transcript.notices.contains(notice) { transcript.notices.append(notice) }
        }
    }
}

/// Telemetry and session totals carry only an aggregate cache write. Claude's
/// own cost of that call or segment determines the 5m/1h split exactly.
enum ClaudeCacheTTL {
    static func isTiered(_ rates: [String: Double]) -> Bool { rates.keys.contains { $0.contains("Above200k") } }
    /// ccusage and Claude Code price a one-hour write at twice the input rate
    /// unless the tariff names its own one-hour rate.
    static func hourRate(_ rates: [String: Double], input: Double) -> Double { rates["cacheCreationInputTokenCostAbove1hr"] ?? input * 2 }

    /// Claude's price of a known transcript request at standard speed.
    static func cost(_ request: TranscriptRequest, rates: [String: Double]) -> Double? {
        guard request.billing.speed != "fast", !isTiered(rates),
              let input = rates["inputCostPerToken"], let output = rates["outputCostPerToken"],
              let read = rates["cacheReadInputTokenCost"], let write = rates["cacheCreationInputTokenCost"] else { return nil }
        let hour = request.billing.cacheCreation["ephemeral_1h_input_tokens", default: 0]
        let split = request.billing.cacheCreation.values.reduce(0, +)
        let total = request.usage.cacheCreate
        // A zero or empty breakdown leaves the aggregate at the 5-minute rate.
        let hourTokens = split == total ? hour : 0
        return Double(request.usage.input) * input + Double(request.usage.output) * output + Double(request.usage.cacheRead) * read
            + Double(total - hourTokens) * write + Double(hourTokens) * hourRate(rates, input: input)
    }

    static func split(cost: Double, input: Int64, output: Int64, read: Int64, write: Int64, rates: [String: Double]) -> [String: Int64]? {
        guard write > 0, cost.isFinite, !isTiered(rates),
              let inputRate = rates["inputCostPerToken"], let outputRate = rates["outputCostPerToken"],
              let readRate = rates["cacheReadInputTokenCost"], let minute = rates["cacheCreationInputTokenCost"] else { return nil }
        let rest = cost - Double(input) * inputRate - Double(output) * outputRate - Double(read) * readRate
        let tolerance = max(1e-9, abs(cost) * 1e-9)
        if abs(rest - Double(write) * minute) <= tolerance {
            return ["ephemeral_5m_input_tokens": write, "ephemeral_1h_input_tokens": 0]
        }
        let oneHour = Self.hourRate(rates, input: inputRate)
        guard oneHour > minute else { return nil }
        let hours = (rest - Double(write) * minute) / (oneHour - minute)
        let rounded = hours.rounded()
        guard rounded >= 0, rounded <= Double(write), abs(hours - rounded) * (oneHour - minute) <= tolerance else { return nil }
        let hour = Int64(rounded)
        return ["ephemeral_5m_input_tokens": write - hour, "ephemeral_1h_input_tokens": hour]
    }
}
