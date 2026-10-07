import Foundation

struct TranscriptTelemetryIdentity: Sendable, Equatable {
    var sessionID: String?
    var requestID: String?
    var clientRequestID: String?
}

struct TelemetryReconciliation: Sendable {
    enum Match: String, Codable, Sendable { case matched, countersDiffer, modelDiffers, ambiguous, unlinked, service, error, conflict }
    struct Row: Sendable, Identifiable {
        var event: ClaudeTelemetryEvent
        var match: Match
        var request: TranscriptRequest?
        var id: String { event.id }
        var priceDiffers: Bool {
            guard let cost = event.cost, let request, request.priced else { return false }
            return abs(NSDecimalNumber(decimal: cost).doubleValue - request.usage.cost) > 0.000001
        }
    }
    var rows: [Row]
    var matched: Int
    var mainRequests: Int
    var claudeMatchedCost: Decimal?
    var appMatchedCost: Double?
    var snapshotCountersMatch: Bool?
    var sessionClaudeCost: Decimal?
    var sessionAppCost: Double?
    var hasTranscript: Bool
    var reasons: Set<String>
}

enum ClaudeTelemetryReconciler {
    static func modelKey(_ model: String) -> String {
        let canonical = ClaudeSessionAccounting.canonical(model)
        return canonical.hasPrefix("claude-") ? canonical : model
    }
    static func modelsAgree(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let left = ClaudeSessionAccounting.canonical(lhs), right = ClaudeSessionAccounting.canonical(rhs)
        return left.hasPrefix("claude-") && left == right
    }
    static func reconcile(sessionID: String, events: [ClaudeTelemetryEvent], transcript: SessionTranscript?, day: UsageDay? = nil) -> TelemetryReconciliation {
        let sid = sessionID.lowercased()
        let requests = (transcript?.requests ?? []).filter { !$0.isReplay && !$0.isSupplemental && (day == nil || $0.belongs(to: day!)) }
        let selected = events.filter { $0.sessionID == sid && (day == nil || ($0.date >= day!.date && $0.date < day!.end)) }
        let conflicts = TelemetrySnapshot.conflictingKeys(events)
        var linked = Set<String>()
        let rows = selected.sorted { $0.date < $1.date }.map { event -> TelemetryReconciliation.Row in
            if event.kind == .apiError { return .init(event: event, match: .error) }
            if let key = event.callKey, conflicts.contains(key) { return .init(event: event, match: .conflict) }
            if event.source == .title || event.source == .rename || event.source == .compact { return .init(event: event, match: .service) }
            let candidates = requests.filter { request in
                guard let identity = request.telemetryIdentity, identity.sessionID == sid else { return false }
                if let id = event.requestID, let other = identity.requestID {
                    if let client = event.clientRequestID, let otherClient = identity.clientRequestID, client != otherClient { return false }
                    return id == other
                }
                if let id = event.clientRequestID, let other = identity.clientRequestID { return id == other }
                return false
            }
            guard candidates.count == 1, let request = candidates.first else { return .init(event: event, match: candidates.isEmpty ? .unlinked : .ambiguous) }
            guard !linked.contains(request.id) else { return .init(event: event, match: .ambiguous) }
            guard let model = event.model, modelsAgree(model, request.model) else { return .init(event: event, match: .modelDiffers) }
            let pairs: [(Int64?, Int64?)] = [(event.input, request.billing.tokens["input_tokens"]), (event.output, request.billing.tokens["output_tokens"]),
                (event.cacheRead, request.billing.tokens["cache_read_input_tokens"]), (event.cacheWrite, request.billing.tokens["cache_creation_input_tokens"])]
            guard pairs.allSatisfy({ $0.0 != nil && $0.1 != nil && $0.0 == $0.1 }) else { return .init(event: event, match: .countersDiffer, request: request) }
            linked.insert(request.id)
            return .init(event: event, match: .matched, request: request)
        }
        let matched = rows.filter { $0.match == .matched }
        let costs = matched.compactMap { $0.event.cost }
        let all = (transcript?.requests ?? []).filter { !$0.isReplay }
        let paid = events.filter { $0.kind == .apiRequest && $0.sessionID == sid && $0.callKey.map { !conflicts.contains($0) } == true }
        let hasSnapshot = transcript?.claudeSnapshotValidated == true || all.contains(where: \.isSupplemental)
        var snapshotMatch: Bool?
        if hasSnapshot && transcript?.usageUncertain != true {
            // Decimal sums avoid Int64 overflow even with hostile large counters.
            let fields: [(KeyPath<ClaudeTelemetryEvent, Int64?>, KeyPath<TokenUsage, Int64>)] = [(\.input, \.input), (\.output, \.output), (\.cacheRead, \.cacheRead), (\.cacheWrite, \.cacheCreate)]
            let eventGroups = Dictionary(grouping: paid, by: { modelKey($0.model ?? "") })
            let requestGroups = Dictionary(grouping: all, by: { modelKey($0.model) })
            snapshotMatch = !paid.isEmpty && Set(eventGroups.keys) == Set(requestGroups.keys) && requestGroups.allSatisfy { model, requests in
                let events = eventGroups[model] ?? []
                return !model.isEmpty && fields.allSatisfy { e, r in
                    events.allSatisfy { $0[keyPath: e] != nil }
                        && events.reduce(Decimal(0)) { $0 + Decimal($1[keyPath: e]!) } == requests.reduce(Decimal(0)) { $0 + Decimal($1.usage[keyPath: r]) }
                }
            }
        }
        var reasons: Set<String> = ["collection_may_be_partial", "duration_is_per_api_call", "ttl_not_in_standard_events"]
        if transcript == nil { reasons.insert("transcript_unavailable") }
        if linked.count != requests.count { reasons.insert("main_request_coverage_incomplete") }
        if matched.contains(where: \.priceDiffers) { reasons.insert("rates_or_pricing_version_differ") }
        if !conflicts.isEmpty { reasons.insert("conflicting_call_ids") }
        if selected.contains(where: \.usesReceiveTime) { reasons.insert("receive_time_fallback") }
        if day != nil && hasSnapshot { reasons.insert("snapshot_is_whole_session_context") }
        return .init(rows: rows, matched: linked.count, mainRequests: requests.count,
            claudeMatchedCost: costs.count == matched.count && !costs.isEmpty ? costs.reduce(0, +) : nil,
            appMatchedCost: !matched.isEmpty && matched.allSatisfy({ $0.request?.priced == true }) ? matched.reduce(0) { $0 + $1.request!.usage.cost } : nil,
            snapshotCountersMatch: snapshotMatch,
            sessionClaudeCost: snapshotMatch == true && paid.allSatisfy({ $0.cost != nil }) ? paid.reduce(Decimal(0)) { $0 + $1.cost! } : nil,
            sessionAppCost: snapshotMatch == true && all.allSatisfy(\.priced) ? all.reduce(0) { $0 + $1.usage.cost } : nil,
            hasTranscript: transcript != nil, reasons: reasons)
    }
    static let rateKeys: Set<String> = ["inputCostPerToken", "outputCostPerToken", "cacheCreationInputTokenCost", "cacheReadInputTokenCost", "cacheCreationInputTokenCostAbove1hr", "inputCostPerTokenAbove200kTokens", "outputCostPerTokenAbove200kTokens", "cacheCreationInputTokenCostAbove200kTokens", "cacheReadInputTokenCostAbove200kTokens", "fastMultiplier", "maxInputTokens"]
    /// Numeric pricing projection only. Unknown keys and strings never survive.
    static func rates(_ data: Data) -> [String: [String: Double]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let defaults = root["defaults"] as? [String: Any] ?? [:]
        let maps = defaults["pricingOverrides"] as? [String: Any] ?? [:]
        var result: [String: [String: Double]] = [:]
        for (model, value) in maps where ClaudeTelemetrySanitizer.model(model) != nil {
            for (key, value) in value as? [String: Any] ?? [:] where rateKeys.contains(key) {
                if let text = ClaudeTelemetrySanitizer.decimal(value), let number = Double(text) { result[model, default: [:]][key] = number }
            }
        }
        return result
    }
}
