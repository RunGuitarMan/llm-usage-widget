import Foundation
import CryptoKit
import CoreFoundation

enum TelemetryFailure: String, Error, Codable, Sendable {
    case invalidJSON, unsafePath, settingsConflict, settingsChanged, backup, write, sync, replace, postcheck
    case transport, limit, storage, port, disabled, quota, export
}

enum TelemetryJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            // Quantize explicitly: Foundation's fractional formatter/parser pair can
            // otherwise truncate a millisecond on each round trip and change dedup.
            let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
            let fraction = (micros % 1_000_000 + 1_000_000) % 1_000_000
            let seconds = (micros - fraction) / 1_000_000
            let whole = Date(timeIntervalSince1970: Double(seconds)).ISO8601Format()
            try container.encode(String(whole.dropLast()) + String(format: ".%06lldZ", fraction))
        }
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = date(text) else { throw TelemetryFailure.invalidJSON }
            return date
        }
        return try decoder.decode(type, from: data)
    }
    static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? TranscriptJSON.date(text)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct ClaudeTelemetryEvent: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case apiRequest = "api_request", apiError = "api_error" }
    enum Source: String, Codable, Sendable { case main = "repl_main_thread", title = "generate_session_title", rename = "rename_generate_name", compact, other }
    enum Speed: String, Codable, Sendable { case normal, standard, fast }
    enum ErrorCategory: String, Codable, Sendable { case authentication, rateLimit, server, request, unknown }
    var schemaVersion = 1
    var sessionID: String
    var kind: Kind
    var requestID: String?
    var clientRequestID: String?
    var timestamp: Date?
    var timestampNanos: String?
    var receivedAt: Date
    var sequence: Int64?
    var durationMS: Double?
    var model: String?
    var input: Int64?
    var output: Int64?
    var cacheRead: Int64?
    var cacheWrite: Int64?
    var costUSD: String?
    var costMicros: Int64?
    var claudeVersion: String?
    var speed: Speed?
    var source: Source?
    var statusCode: Int64?
    var attempt: Int64?
    var errorCategory: ErrorCategory?
    var id: String { fingerprint }
    var date: Date { timestamp ?? receivedAt }
    var usesReceiveTime: Bool { timestamp == nil }
    var cost: Decimal? { costUSD.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } ?? costMicros.map { Decimal($0) / 1_000_000 } }
    var microsDisagree: Bool {
        guard let costUSD, let value = Decimal(string: costUSD), let costMicros else { return false }
        return abs(NSDecimalNumber(decimal: value * 1_000_000 - Decimal(costMicros)).doubleValue) > 1
    }
    var fingerprint: String {
        var copy = self; copy.receivedAt = Date(timeIntervalSince1970: 0)
        return TelemetryJSON.hash((try? TelemetryJSON.encode(copy)) ?? Data())
    }
    /// An ID identifies a call, not a delivery. Errors/attempts are never paid calls.
    var callKey: String? { (requestID ?? clientRequestID).map { kind.rawValue + ":" + $0 + (kind == .apiError ? ":\(attempt.map(String.init) ?? "unknown")" : "") } }
}

struct ClaudeTelemetryBatch: Sendable {
    var events: [ClaudeTelemetryEvent] = []
    var ignored = 0
    var rejected = 0
    var unmatched = 0
}

/// Raw OTLP exists only on this stack. No payload, exception, body or resource
/// object crosses this boundary. Persisted/exported types have no free-text slot.
enum ClaudeTelemetrySanitizer {
    static let maxEvents = 10_000
    static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, (1...128).contains(value.utf8.count),
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95].contains($0) }) else { return nil }
        return value
    }
    static func model(_ value: Any?) -> String? {
        guard let value = value as? String, (1...160).contains(value.utf8.count),
              value.first?.isLetter == true,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95, 46, 47, 58, 91, 93].contains($0) }),
              !value.contains(".."), !value.contains("//") else { return nil }
        return value
    }
    static func session(_ value: Any?) -> String? {
        guard let text = value as? String, text.count == 36, let uuid = UUID(uuidString: text) else { return nil }
        return uuid.uuidString.lowercased()
    }
    static func number(_ value: Any?) -> String? {
        if let n = value as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.stringValue
        }
        return value as? String
    }
    static func integer(_ value: Any?) -> Int64? {
        guard let text = number(value), !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int64(text) else { return nil }
        return number
    }
    static func decimal(_ value: Any?) -> String? {
        guard let text = number(value), text.count <= 64, let node = try? StrictJSON.parse(Data(text.utf8)),
              case .number = node.value, let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !number.isNaN, number >= 0, number <= Decimal(1_000_000_000) else { return nil }
        return NSDecimalNumber(decimal: number).stringValue
    }
    static func attributes(_ value: Any?) throws -> [String: Any] {
        guard let rows = value as? [[String: Any]] else { return [:] }
        var output: [String: Any] = [:]; var keys = Set<String>()
        for row in rows {
            guard let key = row["key"] as? String, keys.insert(key).inserted else { throw TelemetryFailure.invalidJSON }
            let v = row["value"] as? [String: Any] ?? [:]
            guard v.count == 1 else { continue }
            output[key] = v["stringValue"] ?? v["intValue"] ?? v["doubleValue"]
        }
        return output
    }
    static func sanitize(_ data: Data, receivedAt: Date = Date()) throws -> ClaudeTelemetryBatch {
        guard data.count <= 16 * 1024 * 1024, (try? StrictJSON.parse(data)) != nil,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root.isEmpty || root["resourceLogs"] is [[String: Any]] else { throw TelemetryFailure.invalidJSON }
        var result = ClaudeTelemetryBatch(); var count = 0
        for resource in root["resourceLogs"] as? [[String: Any]] ?? [] {
            guard resource["scopeLogs"] == nil || resource["scopeLogs"] is [[String: Any]],
                  resource["resource"] == nil || resource["resource"] is [String: Any] else { throw TelemetryFailure.invalidJSON }
            let resourceAttrs = try attributes((resource["resource"] as? [String: Any])?["attributes"])
            for scope in resource["scopeLogs"] as? [[String: Any]] ?? [] {
                guard scope["logRecords"] == nil || scope["logRecords"] is [[String: Any]] else { throw TelemetryFailure.invalidJSON }
                for record in scope["logRecords"] as? [[String: Any]] ?? [] {
                    count += 1; guard count <= maxEvents else { throw TelemetryFailure.limit }
                    do {
                        let a = try attributes(record["attributes"])
                        let body = (record["body"] as? [String: Any])?["stringValue"] as? String
                        let name = a["event.name"] as? String ?? body
                        let kind: ClaudeTelemetryEvent.Kind?
                        switch name { case "api_request", "claude_code.api_request": kind = .apiRequest
                        case "api_error", "claude_code.api_error": kind = .apiError
                        default: kind = nil }
                        guard let kind else { result.ignored += 1; continue }
                        guard let sid = session(a["session.id"] ?? a["session_id"] ?? resourceAttrs["session.id"]) else { result.unmatched += 1; continue }
                        var event = ClaudeTelemetryEvent(sessionID: sid, kind: kind, receivedAt: receivedAt)
                        event.requestID = identifier(a["request_id"])
                        event.clientRequestID = identifier(a["client_request_id"])
                        event.model = model(a["model"])
                        event.sequence = integer(a["event.sequence"])
                        event.input = integer(a["input_tokens"]); event.output = integer(a["output_tokens"])
                        event.cacheRead = integer(a["cache_read_tokens"]); event.cacheWrite = integer(a["cache_creation_tokens"])
                        event.costUSD = decimal(a["cost_usd"]); event.costMicros = integer(a["cost_usd_micros"])
                        if let text = decimal(a["duration_ms"]) { event.durationMS = Double(text) }
                        // Invalid present numeric values reject the event; missing values stay missing.
                        for (key, valid) in [("event.sequence", event.sequence != nil), ("input_tokens", event.input != nil), ("output_tokens", event.output != nil), ("cache_read_tokens", event.cacheRead != nil), ("cache_creation_tokens", event.cacheWrite != nil), ("cost_usd", event.costUSD != nil), ("cost_usd_micros", event.costMicros != nil), ("duration_ms", event.durationMS != nil)] {
                            if a[key] != nil && !valid { throw TelemetryFailure.invalidJSON }
                        }
                        var sum: Int64 = 0
                        for value in [event.input, event.output, event.cacheRead, event.cacheWrite].compactMap({ $0 }) {
                            let added = sum.addingReportingOverflow(value); guard !added.overflow else { throw TelemetryFailure.limit }; sum = added.partialValue
                        }
                        if let nanos = integer(record["timeUnixNano"]), nanos > 0 {
                            event.timestampNanos = String(nanos); event.timestamp = Date(timeIntervalSince1970: Double(nanos) / 1e9)
                        } else if let text = a["event.timestamp"] as? String, text.count <= 40 {
                            event.timestamp = TelemetryJSON.date(text)
                        }
                        let version = a["app.version"] ?? a["service.version"] ?? resourceAttrs["service.version"]
                        if let version = version as? String, version.range(of: #"^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,6}$"#, options: .regularExpression) != nil { event.claudeVersion = version }
                        event.source = (a["query_source"] as? String).map { .init(rawValue: $0) ?? .other }
                        event.speed = (a["speed"] as? String).flatMap { .init(rawValue: $0) }
                        if kind == .apiError {
                            event.statusCode = integer(a["status_code"]); event.attempt = integer(a["attempt"])
                            if a["status_code"] != nil && !(100...599).contains(event.statusCode ?? 0) { throw TelemetryFailure.invalidJSON }
                            if a["attempt"] != nil && event.attempt == nil { throw TelemetryFailure.invalidJSON }
                            switch event.statusCode ?? 0 {
                            case 401, 403: event.errorCategory = .authentication
                            case 429: event.errorCategory = .rateLimit
                            case 500...599: event.errorCategory = .server
                            case 400...499: event.errorCategory = .request
                            default: event.errorCategory = .unknown
                            }
                            // Errors cannot contribute a successful call's price or tokens.
                            event.costUSD = nil; event.costMicros = nil
                            event.input = nil; event.output = nil; event.cacheRead = nil; event.cacheWrite = nil
                        }
                        result.events.append(event)
                    } catch { result.rejected += 1 }
                }
            }
        }
        return result
    }
}
