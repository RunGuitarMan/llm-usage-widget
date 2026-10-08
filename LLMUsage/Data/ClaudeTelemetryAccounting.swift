import Foundation

/// A validated cumulative total already owns every call up to its timestamp.
/// Without an explicit timestamp, its boundary is unknown: do not add telemetry
/// on top of it and guess which side of the snapshot a call belongs to.
struct ClaudeAccountingCoverage: Sendable {
    var model: String
    var through: Date?
}

/// Complete transcript accounting from identified, successful API calls. Prices
/// are deliberately ignored here; the existing helper prices the resulting
/// requests with the same configuration as the rest of the report.
enum ClaudeTelemetryAccounting {
    static let fields = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]

    static func recover(_ original: SessionTranscript, sessionID: String, events: [ClaudeTelemetryEvent], day: UsageDay? = nil) -> SessionTranscript {
        guard let sid = ClaudeTelemetrySanitizer.session(sessionID), !original.imported else { return original }
        var result = original
        let allEvents = events.filter { $0.sessionID == sid && $0.kind == .apiRequest }
        let dayRequests = original.requests.filter { request in day.map { request.belongs(to: $0) } ?? true }
        let requestIDs = Set(dayRequests.compactMap { $0.telemetryIdentity?.requestID })
        let clientIDs = Set(dayRequests.compactMap { $0.telemetryIdentity?.clientRequestID })
        let selected = allEvents.filter { event in
            guard let day else { return true }
            // Completion can arrive after midnight for a request belonging to this day.
            if event.requestID.map(requestIDs.contains) == true || event.clientRequestID.map(clientIDs.contains) == true { return true }
            return event.timestamp.map { $0 >= day.date && $0 < day.end } ?? true
        }
        // Conflicting deliveries remain conflicts even across date boundaries.
        var conflicts = TelemetrySnapshot.conflictingKeys(allEvents)
        let clients = Dictionary(grouping: allEvents.filter { $0.clientRequestID != nil }, by: { $0.clientRequestID! })
        for calls in clients.values where Set(calls.compactMap(\.requestID)).count > 1 {
            conflicts.formUnion(calls.compactMap(\.callKey))
        }
        var seen = Set<String>()
        var uncertain = false
        var recovered = 0
        let models = Set(original.requests.filter { !$0.isReplay && !$0.model.isEmpty && $0.model != "<synthetic>" }.map(\.model))
        var requestIndexes: [String: [Int]] = [:], clientIndexes: [String: [Int]] = [:]
        var withoutRequest = Set<String>(), withoutClient = Set<String>(), withoutEither = Set<String>()
        for (index, request) in original.requests.enumerated() where !request.isReplay && !request.isSupplemental {
            let modelKey = ClaudeTelemetryReconciler.modelKey(request.model)
            let identity = request.telemetryIdentity?.sessionID == sid ? request.telemetryIdentity : nil
            if let id = identity?.requestID { requestIndexes[id, default: []].append(index) } else { withoutRequest.insert(modelKey) }
            if let id = identity?.clientRequestID { clientIndexes[id, default: []].append(index) } else { withoutClient.insert(modelKey) }
            if identity?.requestID == nil && identity?.clientRequestID == nil { withoutEither.insert(modelKey) }
        }
        for event in selected.sorted(by: { $0.date == $1.date ? ($0.callKey ?? "") < ($1.callKey ?? "") : $0.date < $1.date }) {
            guard let key = event.callKey, !conflicts.contains(key) else { uncertain = true; continue }
            guard seen.insert(key).inserted else { continue }
            guard let date = event.timestamp, let model = event.model,
                  ClaudeTelemetrySanitizer.model(model) != nil,
                  let input = event.input, let output = event.output, let read = event.cacheRead, let write = event.cacheWrite,
                  [input, output, read, write].allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000_000 }),
                  let speed = event.speed else { uncertain = true; continue }
            let tokens = Dictionary(uniqueKeysWithValues: zip(fields, [input, output, read, write]))
            let billingSpeed = speed == .fast ? "fast" : "standard"
            // Consider either identity, then require all shared identities to
            // agree. A conflicting request/client pair must not become a new call.
            let candidates = Set((event.requestID.flatMap { requestIndexes[$0] } ?? [])
                + (event.clientRequestID.flatMap { clientIndexes[$0] } ?? [])).sorted()
            guard candidates.count <= 1 else { uncertain = true; continue }
            let existing = candidates.first.map { result.requests[$0] }
            if let existing {
                let identity = existing.telemetryIdentity!
                guard ClaudeTelemetryReconciler.modelsAgree(model, existing.model),
                      event.requestID == nil || identity.requestID == nil || event.requestID == identity.requestID,
                      event.clientRequestID == nil || identity.clientRequestID == nil || event.clientRequestID == identity.clientRequestID,
                      existing.billing.speed == nil || existing.billing.speed == billingSpeed else { uncertain = true; continue }
                if fields.allSatisfy({ existing.billing.tokens[$0] == tokens[$0] }),
                   existing.billing.speed == billingSpeed || (existing.billing.speed == nil && billingSpeed == "standard") { continue }
                // A zero/absent counter or a growing streamed output can be
                // completed. Contradictory positive input/cache counts cannot.
                guard fields.allSatisfy({ field in
                    let old = existing.billing.tokens[field, default: 0]
                    return old == 0 || old == tokens[field] || (field == "output_tokens" && old <= tokens[field]!)
                }) else { uncertain = true; continue }
            }
            if let coverage = result.claudeAccountingCoverage.first(where: { ClaudeTelemetryReconciler.modelsAgree($0.model, model) }),
               coverage.through == nil || date <= coverage.through! {
                // Existing snapshot overhead already includes these calls.
                // Unknown boundaries stay conservative and visibly incomplete.
                if coverage.through == nil { uncertain = true }
                continue
            }
            // Telemetry does not carry the cache-write TTL. Retain a proven
            // transcript split; never invent a 5m/1h tariff for a recovered call.
            let cache = existing?.billing.cacheCreation ?? [:]
            guard write == 0 || (!cache.isEmpty && cache.values.reduce(0, +) == write) else { uncertain = true; continue }
            if let index = candidates.first {
                if result.requests[index].telemetryOriginalTokens == nil {
                    result.requests[index].telemetryOriginalTokens = result.requests[index].billing.tokens.filter { fields.contains($0.key) }
                }
                result.requests[index].billing = .init(tokens: tokens, speed: billingSpeed, cacheCreation: cache)
                result.requests[index].usage = .init(input: input, output: output, cacheCreate: write, cacheRead: read, costIsIncomplete: true)
                result.requests[index].priced = false
                result.requests[index].telemetryRecovery = "completed"
                result.requests[index].accountingModel = billingSpeed == "fast" ? result.requests[index].model + "-fast" : nil
                // Keep the original timestamp/day and visible message ownership.
            } else {
                let aliases = models.filter { ClaudeTelemetryReconciler.modelsAgree($0, model) }
                guard aliases.count <= 1 || aliases.contains(model) else { uncertain = true; continue }
                // Requestless transcript rows may already own this API call.
                // A timestamp or matching token count is not a billing identity.
                let modelKey = ClaudeTelemetryReconciler.modelKey(model)
                let unidentifiable = event.requestID == nil ? withoutClient.contains(modelKey)
                    : event.clientRequestID == nil ? withoutRequest.contains(modelKey) : withoutEither.contains(modelKey)
                guard !unidentifiable, result.requests.count < TranscriptUsageParser.maximumRequests else { uncertain = true; continue }
                let tariffModel = aliases.contains(model) ? model : aliases.first ?? model
                let index = result.requests.count
                if let id = event.requestID { requestIndexes[id, default: []].append(index) }
                if let id = event.clientRequestID { clientIndexes[id, default: []].append(index) }
                result.requests.append(.init(id: "request-telemetry-" + TelemetryJSON.hash(Data((sid + ":" + key).utf8)),
                    model: tariffModel, timestamp: date, eventIDs: [], billing: .init(tokens: tokens, speed: billingSpeed, cacheCreation: cache),
                    usage: .init(input: input, output: output, cacheCreate: write, cacheRead: read, costIsIncomplete: true),
                    sequence: result.requests.count + 1,
                    accountingModel: billingSpeed == "fast" ? tariffModel + "-fast" : nil,
                    telemetryIdentity: .init(sessionID: sid, requestID: event.requestID, clientRequestID: event.clientRequestID),
                    telemetryRecovery: "added"))
            }
            recovered += 1
        }
        if uncertain {
            result.markUsageUncertain(at: day?.date)
            let notice = L10n.text("Часть API-расходов нельзя однозначно восстановить из телеметрии. Итог может быть неполным.")
            if !result.notices.contains(notice) { result.notices.append(notice) }
        }
        if recovered > 0 {
            let notice = L10n.text("Недостающие API-расходы восстановлены по локальной телеметрии и рассчитаны по тарифам отчёта.")
            if !result.notices.contains(notice) { result.notices.append(notice) }
        }
        return result
    }
}
