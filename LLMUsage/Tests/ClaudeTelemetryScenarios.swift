import Foundation
import Darwin
import zlib
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#endif

private struct TelemetryCheckFailure: Error, CustomStringConvertible { var description: String }

enum ClaudeTelemetryScenarios {
    static let sid = "11111111-2222-4333-8444-555555555555"
    static let other = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    static let currentEventTime = Date().ISO8601Format(.init(includingFractionalSeconds: true))
    static let secret = "CANARY_PRIVATE_PROMPT_AUTH_HOST_PATH_TOOL_731"
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw TelemetryCheckFailure(description: message) }
    }
    static func temporary() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("telemetry-tests-" + UUID().uuidString)
        try TelemetryFiles.createDirectory(url); return url
    }
    static func payload(_ rows: [[String: Any]]) throws -> Data {
        let records = rows.map { row in
            ["attributes": row.map { key, value in ["key": key, "value": [value is String ? "stringValue" : "doubleValue": value]] },
             "body": ["stringValue": secret]] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: ["resourceLogs": [["resource": ["attributes": [["key": "host.name", "value": ["stringValue": secret]]]], "scopeLogs": [["logRecords": records]]]]])
    }
    static func row(session: String? = sid, request: String = "req-one", kind: String = "api_request") -> [String: Any] {
        var row: [String: Any] = ["event.name": kind, "event.timestamp": currentEventTime, "event.sequence": "1", "request_id": request,
            "client_request_id": "client-one", "model": "corporate-model", "duration_ms": "120.5", "input_tokens": "2", "output_tokens": "5",
            "cache_read_tokens": "10", "cache_creation_tokens": "3", "cost_usd": "0.0000715", "cost_usd_micros": "71", "query_source": "repl_main_thread", "app.version": "2.1.280"]
        if let session { row["session.id"] = session }
        return row
    }
    static func batch(_ rows: [[String: Any]], now: Date = Date()) throws -> ClaudeTelemetryBatch { try ClaudeTelemetrySanitizer.sanitize(payload(rows), receivedAt: now) }
    static func pricedFixture() throws -> (SessionTranscript, ClaudeTelemetryBatch) {
        let fixture = try ClaudeAccountingScenarios.fixtures().last!
        var rows = fixture["records"] as! [[String: Any]]
        for index in rows.indices { rows[index]["sessionId"] = sid }
        var transcript = try ClaudeAccountingScenarios.decode(rows)
        for index in transcript.requests.indices {
            let u = transcript.requests[index].usage
            transcript.requests[index].usage.cost = Double(u.input) * 2e-6 + Double(u.output) * 1e-5 + Double(u.cacheRead) * 2e-7 + Double(u.cacheCreate) * 2.5e-6
            transcript.requests[index].usage.costIsIncomplete = false; transcript.requests[index].priced = true
        }
        transcript.telemetryRates = ["anthropic/claude-sonnet-5.5": ["inputCostPerToken": 2e-6, "outputCostPerToken": 1e-5, "cacheReadInputTokenCost": 2e-7, "cacheCreationInputTokenCost": 2.5e-6]]
        var api: [[String: Any]] = []
        for (index, request) in transcript.requests.filter({ !$0.isSupplemental }).enumerated() {
            var value = row(request: request.telemetryIdentity!.requestID!)
            value["model"] = request.model; value["event.sequence"] = String(index + 1)
            value["input_tokens"] = String(request.usage.input); value["output_tokens"] = String(request.usage.output)
            value["cache_read_tokens"] = String(request.usage.cacheRead); value["cache_creation_tokens"] = String(request.usage.cacheCreate)
            let price = Decimal(request.usage.input) * Decimal(string: "0.000002")! + Decimal(request.usage.output) * Decimal(string: "0.00001")!
                + Decimal(request.usage.cacheRead) * Decimal(string: "0.0000002")! + Decimal(request.usage.cacheCreate) * Decimal(string: "0.0000025")!
            value["cost_usd"] = NSDecimalNumber(decimal: price).stringValue
            value["cost_usd_micros"] = String(NSDecimalNumber(decimal: price * 1_000_000).int64Value)
            api.append(value)
        }
        for (index, input, output, source, cost): (Int, Int, Int, String, String) in [(24, 1735, 47, "generate_session_title", "0.00394"), (25, 735, 143, "rename_generate_name", "0.0029")] {
            var value = row(request: "service-\(index)")
            value["event.sequence"] = String(index); value["input_tokens"] = String(input); value["output_tokens"] = String(output)
            value["cache_read_tokens"] = "0"; value["cache_creation_tokens"] = "0"; value["query_source"] = source
            value["cost_usd"] = cost; value.removeValue(forKey: "cost_usd_micros"); value["model"] = "anthropic/claude-sonnet-5.5"
            api.append(value)
        }
        return (transcript, try batch(api))
    }

    static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw TelemetryFailure.transport }
        defer { deflateEnd(&stream) }
        var output = Data()
        try data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress; stream.avail_out = uInt(buffer.count)
                    return deflate(&stream, Z_FINISH)
                }
                output.append(contentsOf: chunk.prefix(chunk.count - Int(stream.avail_out)))
                if status == Z_STREAM_END { break }
                guard status == Z_OK else { throw TelemetryFailure.transport }
            }
        }
        return output
    }

    static func run(check: (String, () async throws -> Void) async -> Void) async {
        await check("Telemetry settings: exact bytes, backup, metadata, no-op and no preview writes") {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("settings.json")
            let original = Data("{\r\n  \"permissions\": {\"allow\": [\"Bash(*)\"]}, \"hooks\":{},\r\n  \"proxy\": \"secret\\/value\", \"n\": 1.2300e+02,\r\n  \"env\": {\"EXISTING\": \"\\u0061\", \"OTEL_LOGS_EXPORTER\": \"otlp\"}\r\n}\r\n".utf8)
            try original.write(to: url); chmod(url.path, 0o640)
            let x = Data("test-xattr".utf8)
            _ = x.withUnsafeBytes { setxattr(url.path, "com.llmusage.test", $0.baseAddress, $0.count, 0, 0) }
            let editor = ClaudeSettingsEnvEditor()
            let preview = try await editor.inspect(url: url, port: 4318)
            try require(preview.additions.count == 13 && preview.matches == ["OTEL_LOGS_EXPORTER"], "Wrong preview")
            try require(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1, "Preview wrote files")
            let receipt = try await editor.apply(preview)!
            try require(try Data(contentsOf: URL(fileURLWithPath: receipt.backup!)) == original, "Backup changed bytes")
            let result = try Data(contentsOf: url)
            let old = try StrictJSON.parse(original), new = try StrictJSON.parse(result)
            for key in ["permissions", "hooks", "proxy", "n"] { try require(original[old[key]!.range] == result[new[key]!.range], "Existing subtree changed") }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640, "Permissions not preserved")
            var buffer = [UInt8](repeating: 0, count: 100)
            let size = getxattr(url.path, "com.llmusage.test", &buffer, buffer.count, 0, 0)
            try require(size == x.count && Data(buffer.prefix(max(0, size))) == x, "xattr not preserved")
            let noOp = try await editor.inspect(url: url, port: 4318)
            let count = try FileManager.default.contentsOfDirectory(atPath: root.path).count
            try require(noOp.isNoOp, "Not idempotent")
            let second = try await editor.apply(noOp)
            try require(second == nil && (try FileManager.default.contentsOfDirectory(atPath: root.path)).count == count, "No-op wrote backup")
            try require((try FileManager.default.attributesOfItem(atPath: receipt.backup!)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Backup not private")
        }
        await check("Telemetry settings: missing env, empty object and exclusive new file") {
            for original in [Data("{ \"hooks\":{} }".utf8), Data("{}".utf8), nil] as [Data?] {
                let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
                let url = root.appendingPathComponent(".claude/settings.json")
                if let original { try TelemetryFiles.createDirectory(url.deletingLastPathComponent()); try original.write(to: url) }
                let editor = ClaudeSettingsEnvEditor(); let preview = try await editor.inspect(url: url, port: 4320)
                if original == nil { try require(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "Preview created directory") }
                let receipt = try await editor.apply(preview)!
                try require(receipt.addedKeys.count == 14 && (receipt.backup == nil) == (original == nil), "Wrong create/backup")
                let result = try StrictJSON.parse(Data(contentsOf: url))
                try require(result["env"]?["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"]?.string == "http://127.0.0.1:4320/v1/logs", "Wrong endpoint")
            }
        }
        await check("Telemetry settings: invalid JSON, null, duplicates, symlink and read-only fail closed") {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("settings.json")
            for text in ["", "[]", "{\"env\":null}", "{\"env\":[]}", "{\"a\":1,\"\\u0061\":2}", "{\"env\":{\"A\":1,\"A\":1}}", "{\"a\":NaN}", "{\"a\":01}", "{\"a\":1,}", "// comment\n{}"] {
                let data = Data(text.utf8); try data.write(to: url)
                do { _ = try await ClaudeSettingsEnvEditor().inspect(url: url, port: 4318); throw TelemetryCheckFailure(description: "Invalid config accepted") }
                catch is TelemetryFailure { }
                try require(try Data(contentsOf: url) == data, "Invalid file modified")
            }
            try Data("{}".utf8).write(to: url); chmod(url.path, 0o400)
            do { _ = try await ClaudeSettingsEnvEditor().inspect(url: url, port: 4318); throw TelemetryCheckFailure(description: "Readonly accepted") } catch is TelemetryFailure { }
            chmod(url.path, 0o600)
            let link = root.appendingPathComponent("link.json"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            do { _ = try await ClaudeSettingsEnvEditor().inspect(url: link, port: 4318); throw TelemetryCheckFailure(description: "Symlink accepted") } catch is TelemetryFailure { }
        }
        await check("Telemetry settings: key and corporate routing conflicts block every addition") {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }; let url = root.appendingPathComponent("settings.json")
            for value in ["{\"env\":{\"OTEL_LOGS_EXPORTER\":\"console\"}}", "{\"env\":{\"OTEL_EXPORTER_OTLP_ENDPOINT\":\"secret\"}}", "{\"env\":{\"OTEL_EXPORTER_OTLP_HEADERS\":\"secret\"}}", "{\"otelHeadersHelper\":\"secret\"}", "{\"env\":{\"BETA_TRACING_ENDPOINT\":\"secret\"}}"] {
                let original = Data(value.utf8); try original.write(to: url)
                let editor = ClaudeSettingsEnvEditor(); let preview = try await editor.inspect(url: url, port: 4318)
                try require(!preview.canApply && !preview.conflicts.isEmpty, "Conflict missing")
                do { _ = try await editor.apply(preview); throw TelemetryCheckFailure(description: "Conflict applied") } catch is TelemetryFailure { }
                try require(try Data(contentsOf: url) == original, "Conflict changed file")
                try require(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1, "Conflict wrote backup")
            }
        }
        await check("Telemetry settings: stale preview, before-replace writer and exclusive-create race") {
            for missing in [false, true] {
                let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }; let url = root.appendingPathComponent("settings.json")
                if !missing { try Data("{}".utf8).write(to: url) }
                let external = Data("{\"external\":true}".utf8)
                let editor = ClaudeSettingsEnvEditor { stage in if stage == .beforeReplace { try external.write(to: url, options: .atomic) } }
                let preview = try await editor.inspect(url: url, port: 4318)
                do { _ = try await editor.apply(preview); throw TelemetryCheckFailure(description: "Concurrent writer overwritten") } catch is TelemetryFailure { }
                try require(try Data(contentsOf: url) == external, "External changes lost")
                let plain = ClaudeSettingsEnvEditor(); let stale = try await plain.inspect(url: url, port: 4318)
                try Data("{\"external\":2}".utf8).write(to: url, options: .atomic)
                do { _ = try await plain.apply(stale); throw TelemetryCheckFailure(description: "Stale preview applied") } catch is TelemetryFailure { }
            }
        }
        await check("Telemetry settings: backup/write/fsync/rename/postcheck faults never truncate or roll back blindly") {
            for stage in [ClaudeSettingsEnvEditor.Stage.backup, .write, .sync, .replace, .postcheck] {
                let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }; let url = root.appendingPathComponent("settings.json")
                let original = Data("{\"preserve\":1}".utf8); try original.write(to: url)
                let editor = ClaudeSettingsEnvEditor { value in if value == stage { throw TelemetryFailure.write } }
                let preview = try await editor.inspect(url: url, port: 4318)
                do { _ = try await editor.apply(preview); throw TelemetryCheckFailure(description: "Injected failure not reached") } catch is TelemetryFailure { }
                let data = try Data(contentsOf: url); let parsed = try StrictJSON.parse(data)
                try require(parsed["preserve"] != nil, "Original JSON truncated")
                if stage != .postcheck { try require(data == original, "Premature mutation") }
                else { try require(parsed["env"] != nil, "Postcheck did blind rollback") }
                try require(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasSuffix(".tmp") }, "Temporary file leaked")
            }
        }
        await check("Telemetry sanitizer: allowlist drops secret text, tools, headers and custom names before disk") {
            var value = row()
            for key in ["prompt", "response", "error", "tool_input", "Authorization", "account.id", "project.path", "unknown", "agent.name"] { value[key] = secret }
            value["query_source"] = secret
            let result = try batch([value, row(kind: "tool_result"), row(session: nil), row(session: "../../evil")])
            try require(result.events.count == 1 && result.ignored == 1 && result.unmatched == 2 && result.events[0].source == .other, "Allowlist/session rules")
            let encoded = try TelemetryJSON.encode(result.events)
            try require(!String(decoding: encoded, as: UTF8.self).contains(secret), "Secret survived sanitizer")
            try require(result.events[0].cost == Decimal(string: "0.0000715"), "Double counted micros")
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let store = ClaudeTelemetryStore(directory: root.appendingPathComponent("Telemetry")); try await store.setCollecting(true)
            _ = try await store.accept(result)
            for file in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!.allObjects as! [URL] {
                if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true { try require(!(try String(contentsOf: file)).contains(secret), "Secret on disk") }
            }
        }
        await check("Telemetry sanitizer: finite numbers, Int64 overflow, missing versus zero and safe error enums") {
            var missing = row(); missing.removeValue(forKey: "input_tokens"); missing.removeValue(forKey: "cost_usd")
            let event = try batch([missing]).events[0]; try require(event.input == nil && event.cost == Decimal(71) / 1_000_000, "Missing coerced to zero")
            for invalid: Any in ["-1", "NaN", "Infinity", "1.5", "9223372036854775808", true] {
                var value = row(); value["input_tokens"] = invalid
                try require(try batch([value]).rejected == 1, "Invalid integer accepted")
            }
            var overflow = row(); overflow["input_tokens"] = String(Int64.max)
            try require(try batch([overflow]).rejected == 1, "Counter sum overflow")
            var error = row(kind: "api_error"); error["error"] = secret; error["status_code"] = "429"; error["attempt"] = "2"
            let failed = try batch([error]).events[0]
            try require(failed.errorCategory == .rateLimit && failed.cost == nil && failed.input == nil && failed.attempt == 2, "Error counted as paid call")
        }
        await check("Telemetry transport: segmented Content-Length, chunked, gzip, limits and browser rejection") {
            let body = try payload([row()])
            let head = Data("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            var parser = TelemetryHTTPParser(); var result: Data?
            for byte in head + body { if let value = try parser.append(Data([byte])) { result = value } }
            try require(result == body, "Segmented body changed")
            var chunks = TelemetryHTTPParser()
            let framed = Data("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n\(String(body.count, radix: 16))\r\n".utf8) + body + Data("\r\n0\r\n\r\n".utf8)
            var decoded: Data?
            for i in stride(from: 0, to: framed.count, by: 17) { if let value = try chunks.append(framed.subdata(in: i..<min(i + 17, framed.count))) { decoded = value } }
            try require(decoded == body, "Chunked body changed")
            let gzip = Data(base64Encoded: "H4sIAAAAAAACA6uuBQBDv6ajAgAAAA==")!
            try require(try TelemetryHTTPParser.gunzip(gzip) == Data("{}".utf8), "gzip failed")
            for raw in ["POST /v1/logs HTTP/1.1\r\nOrigin: null\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}", "POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}", "POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 999999999999\r\n\r\n", String(repeating: "x", count: 16385)] {
                var invalid = TelemetryHTTPParser()
                do { _ = try invalid.append(Data(raw.utf8)); throw TelemetryCheckFailure(description: "Bad HTTP accepted") } catch is TelemetryHTTPParser.Failure { }
            }
        }
        await check("Telemetry protocol: event bound, invalid envelope, gzip expansion limit and fractional identity") {
            let tooMany = try payload(Array(repeating: ["event.name": "tool_result"], count: 10001))
            do { _ = try ClaudeTelemetrySanitizer.sanitize(tooMany); throw TelemetryCheckFailure(description: "Unbounded event array") } catch is TelemetryFailure { }
            for text in ["{\"resourceLogs\":[{\"scopeLogs\":\"bad\"}]}", "{\"resourceLogs\":[{\"scopeLogs\":[{\"logRecords\":42}]}]}"] {
                do { _ = try ClaudeTelemetrySanitizer.sanitize(Data(text.utf8)); throw TelemetryCheckFailure(description: "Malformed envelope ACKed") } catch is TelemetryFailure { }
            }
            let bomb = try gzip(Data(repeating: 65, count: TelemetryHTTPParser.bodyLimit + 1))
            do { _ = try TelemetryHTTPParser.gunzip(bomb); throw TelemetryCheckFailure(description: "Unbounded gzip expansion") } catch is TelemetryHTTPParser.Failure { }
            var first = row(); first["event.timestamp"] = "2026-10-07T12:00:00.123Z"
            var second = row(); second["event.timestamp"] = "2026-10-07T12:00:00.124Z"
            let events = try batch([first, second]).events
            try require(events[0].fingerprint != events[1].fingerprint, "Fractional timestamp lost in fingerprint")
            let encoded = try TelemetryJSON.encode(events[0])
            let restored = try TelemetryJSON.decode(ClaudeTelemetryEvent.self, encoded)
            try require(restored.fingerprint == events[0].fingerprint, "Fingerprint changed across restart")
            var precise = row(); precise["event.timestamp"] = "2026-10-07T23:59:59.999999Z"
            let fine = try batch([precise]).events[0]
            let reloaded = try TelemetryJSON.decode(ClaudeTelemetryEvent.self, TelemetryJSON.encode(fine))
            try require(fine.fingerprint == reloaded.fingerprint && reloaded.date < TelemetryJSON.date("2026-10-08T00:00:00Z")!, "Fractional time crossed day boundary")
        }
        await check("Telemetry HTTP: gzip and partial-success response contain only controlled metadata") {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let store = ClaudeTelemetryStore(directory: root); try await store.setCollecting(true)
            let receiver = try ClaudeTelemetryReceiver(port: 0, store: store); let port = try await receiver.start(); defer { receiver.stop() }
            var bad = row(request: "bad"); bad["input_tokens"] = "-1"; bad["error"] = secret
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/logs")!)
            request.httpMethod = "POST"; request.httpBody = try gzip(payload([row(), bad, row(session: nil)]))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            request.setValue(secret, forHTTPHeaderField: "Authorization")
            let (reply, response) = try await URLSession.shared.data(for: request)
            let text = String(decoding: reply, as: UTF8.self)
            try require((response as! HTTPURLResponse).statusCode == 200 && text.contains("rejectedLogRecords") && text.contains("2") && !text.contains(secret), "Incorrect partial success")
            let snapshot = try await store.snapshot()
            try require(snapshot.sessions[sid]?.count == 1 && snapshot.coverage.unmatched == 1 && snapshot.coverage.rejected == 1, "Partial batch not durably saved")
        }
        await check("Telemetry store: dedup survives restart/resume and reset sequence; sessions and conflicts isolated") {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let store = ClaudeTelemetryStore(directory: root); try await store.setCollecting(true)
            let first = try batch([row(), row(session: other)])
            _ = try await store.accept(first); _ = try await store.accept(first)
            try await store.setCollecting(false)
            let restarted = ClaudeTelemetryStore(directory: root); try await restarted.setCollecting(true)
            _ = try await restarted.accept(first)
            var next = row(request: "req-two"); next["event.sequence"] = "0"
            var conflict = row(); conflict["input_tokens"] = "40"
            _ = try await restarted.accept(batch([next, conflict]))
            let data = try await restarted.snapshot()
            try require(data.sessions[sid]?.count == 3 && data.sessions[other]?.count == 1, "Dedup/resume/parallel sessions")
            try require(data.summaries.first { $0.id == sid }?.conflicts == 1, "Conflict not marked")
        }
        await check("Telemetry store: truncated JSONL and corrupt index rebuild without losing earlier events") {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let store = ClaudeTelemetryStore(directory: root); try await store.setCollecting(true); _ = try await store.accept(batch([row()])); try await store.setCollecting(false)
            let url = root.appendingPathComponent(sid + "/events.jsonl")
            let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); try handle.write(contentsOf: Data("{torn".utf8)); try handle.close()
            try Data("broken".utf8).write(to: root.appendingPathComponent("index.json"))
            try Data("broken".utf8).write(to: root.appendingPathComponent("coverage.json"))
            let restored = ClaudeTelemetryStore(directory: root); let value = try await restored.snapshot()
            try require(value.sessions[sid]?.count == 1 && value.coverage.corrupted == 1, "Recovery lost valid line")
            try require((try Data(contentsOf: url)).last == 10, "Torn tail retained")
            try require(value.coverage.lastAPIEvent != nil && value.coverage.lastWrite != nil && value.coverage.reasons.contains("activity_recovered_from_events"), "Committed activity lost after metadata failure")
        }
        await check("Telemetry store: retention, quota gaps, snapshot consistency and disable gate") {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let now = Date(); let store = ClaudeTelemetryStore(directory: root, retentionDays: 7, quota: 4_000)
            try await store.setCollecting(true)
            var recent = row(); recent.removeValue(forKey: "event.timestamp")
            _ = try await store.accept(batch([recent], now: now), now: now)
            let frozen = try await store.snapshot()
            try await store.delete()
            let deleted = try await store.snapshot()
            try require(frozen.sessions[sid]?.count == 1 && deleted.sessions.isEmpty, "Export snapshot changed under deletion")
            _ = try await store.accept(batch([recent], now: now.addingTimeInterval(-9 * 86400)), now: now)
            try require((try await store.snapshot()).sessions.isEmpty, "Retention kept expired receive-time event")
            let values = (0..<30).map { i -> [String: Any] in var r = recent; r["request_id"] = "req-\(i)"; return r }
            _ = try await store.accept(batch(values), now: now)
            let after = try await store.snapshot()
            try require(after.coverage.reasons.contains("quota_removed_events"), "Quota silently truncated")
            // Cross the real single-file threshold, not only a tiny test quota.
            // An incoming packet must reach oldest-first cleanup instead of failing
            // permanently at the pre-cleanup size check.
            let large = ClaudeTelemetryStore(directory: root.appendingPathComponent("large"), quota: 16 * 1024 * 1024)
            try await large.setCollecting(true)
            var template = try batch([recent]).events[0]
            template.model = String(repeating: "m", count: 160)
            template.clientRequestID = String(repeating: "c", count: 128)
            template.requestID = String(repeating: "r", count: 128)
            let eventBytes = try TelemetryJSON.encode(template).count + 1
            let total = (16 * 1024 * 1024) / eventBytes + 100
            var newest = ""
            for start in stride(from: 0, to: total, by: 10000) {
                let events = (start..<min(start + 10000, total)).map { index -> ClaudeTelemetryEvent in
                    var event = template
                    let suffix = String(index)
                    event.requestID = String(repeating: "r", count: 128 - suffix.count) + suffix
                    event.receivedAt = now.addingTimeInterval(Double(index) / 1000)
                    return event
                }
                newest = events.last!.requestID!
                _ = try await large.accept(.init(events: events), now: now)
            }
            let trimmed = try await large.snapshot()
            try require(trimmed.bytes <= 16 * 1024 * 1024 && trimmed.coverage.removed > 0 && trimmed.sessions[sid]?.last?.requestID == newest,
                        "Quota crossing failed to retain the newest delivery")
            store.gate.set(false)
            do { _ = try await store.accept(batch([recent])); throw TelemetryCheckFailure(description: "Disabled gate wrote") } catch is TelemetryFailure { }
        }
        await check("Telemetry receiver: loopback ACK follows durable write; ignored packets do not indicate API activity") {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let store = ClaudeTelemetryStore(directory: root); try await store.setCollecting(true)
            let receiver = try ClaudeTelemetryReceiver(port: 0, store: store); let port = try await receiver.start(); defer { receiver.stop() }
            func send(_ data: Data) async throws -> Int {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/logs")!); request.httpMethod = "POST"; request.httpBody = data; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (_, response) = try await URLSession.shared.data(for: request); return (response as! HTTPURLResponse).statusCode
            }
            try require(try await send(payload([row(kind: "tool_result")])) == 200, "Ignored packet failed")
            let empty = try await store.snapshot(); try require(empty.coverage.lastPacket != nil && empty.coverage.lastAPIEvent == nil, "Ignored packet lit indicator")
            try require(try await send(payload([row()])) == 200, "API ACK failed")
            let saved = try await store.snapshot(); try require(saved.sessions[sid]?.count == 1 && saved.coverage.lastAPIEvent != nil && saved.coverage.lastWrite != nil, "ACK before persistence")
            let repeatStatus = try await send(payload([row()]))
            let repeated = try await store.snapshot()
            try require(repeatStatus == 200 && repeated.sessions[sid]?.count == 1, "HTTP retry duplicated")
            try await store.setCollecting(false)
            try require(try await send(payload([row(request: "new")])) == 503, "Disabled write ACKed")
        }
        await check("Telemetry receiver: occupied saved port and disk failures fail visibly without false success") {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let store = ClaudeTelemetryStore(directory: root, failWrite: { throw TelemetryFailure.storage }); try await store.setCollecting(true)
            let receiver = try ClaudeTelemetryReceiver(port: 0, store: store); let port = try await receiver.start(); defer { receiver.stop() }
            let second = try ClaudeTelemetryReceiver(port: port, store: store); defer { second.stop() }
            do { _ = try await second.start(); throw TelemetryCheckFailure(description: "Port stolen") } catch is TelemetryFailure { }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/logs")!); request.httpMethod = "POST"; request.httpBody = try payload([row()]); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.data(for: request)
            try require((response as! HTTPURLResponse).statusCode == 503, "Disk failure ACKed")
            try require((try await store.snapshot()).coverage.lastAPIEvent == nil, "Disk failure lit indicator")
        }
        await check("Telemetry reconciliation: captured 24+2 calls, exact decimal costs and no double billing") {
            let (transcript, batch) = try pricedFixture()
            let before = transcript.requests.reduce(0) { $0 + $1.usage.cost }
            let result = ClaudeTelemetryReconciler.reconcile(sessionID: sid, events: batch.events, transcript: transcript)
            try require(result.matched == 24 && result.mainRequests == 24 && result.rows.filter { $0.match == .service }.count == 2, "Captured coverage")
            try require(result.claudeMatchedCost == Decimal(string: "1.3015691") && result.sessionClaudeCost == Decimal(string: "1.3084091"), "Captured decimal totals")
            try require(abs(before - 1.3084091) < 1e-9 && transcript.requests.reduce(0) { $0 + $1.usage.cost } == before, "Double billing")
            var doubled = transcript
            for i in doubled.requests.indices { doubled.requests[i].usage.cost *= 2 }
            let changed = ClaudeTelemetryReconciler.reconcile(sessionID: sid, events: batch.events, transcript: doubled)
            try require(abs(changed.appMatchedCost! - 2.6031382) < 1e-9 && changed.reasons.contains("rates_or_pricing_version_differ"), "Tariffs replaced by Claude price")
        }
        await check("Telemetry reconciliation: missing IDs, wrong session/model/counters and partial capture never guess links") {
            let (transcript, batch) = try pricedFixture()
            var events = Array(batch.events.prefix(3))
            events[0].requestID = nil; events[0].clientRequestID = nil
            events[1].model = "different-model"; events[2].input = 999
            let result = ClaudeTelemetryReconciler.reconcile(sessionID: sid, events: events, transcript: transcript)
            try require(result.matched == 0 && result.rows.map(\.match) == [.unlinked, .modelDiffers, .countersDiffer], "Heuristic link inferred")
            let otherSession = ClaudeTelemetryReconciler.reconcile(sessionID: other, events: batch.events, transcript: transcript)
            try require(otherSession.rows.isEmpty, "Cross-session linking")
            var zeroOverhead = transcript
            zeroOverhead.requests.removeAll(where: \.isSupplemental)
            zeroOverhead.claudeSnapshotValidated = true
            let full = ClaudeTelemetryReconciler.reconcile(sessionID: sid, events: Array(batch.events.prefix(24)), transcript: zeroOverhead)
            try require(full.snapshotCountersMatch == true, "Validated zero-overhead snapshot ignored")
            let partial = ClaudeTelemetryReconciler.reconcile(sessionID: sid, events: Array(batch.events.prefix(12)), transcript: transcript)
            try require(partial.matched == 12 && partial.snapshotCountersMatch == false && partial.sessionClaudeCost == nil, "Partial collection declared full")
        }
        await check("Telemetry dates: event-time selection, receive fallback, midnight and DST") {
            var event = try batch([row()]).events[0]
            event.timestamp = ISO8601DateFormatter().date(from: "2026-03-08T06:30:00Z")!
            event.receivedAt = event.timestamp!.addingTimeInterval(86400)
            let day = UsageDay(date: event.timestamp!, timezone: "America/New_York")
            let selection = TelemetryExportSelection(start: day.date, end: day.end, timezone: day.timezone)
            try require(day.end.timeIntervalSince(day.date) == 23 * 3600 && selection.includes(event), "DST selection used receive time")
            event.timestamp = nil
            try require(!selection.includes(event) && event.usesReceiveTime, "Receive fallback not marked")
            let midnight = ISO8601DateFormatter().date(from: "2026-10-07T22:30:00Z")!
            try require(UsageDay(date: midnight, timezone: "Europe/Moscow").key == "20261008", "Local midnight")
        }
        await check("Telemetry export period: exclusive day end and cumulative session context") {
            let (transcript, fixture) = try pricedFixture()
            var events = fixture.events
            let day = UsageDay(date: events[0].date, timezone: "UTC")
            events[0].timestamp = day.end
            let snapshot = TelemetrySnapshot(sessions: [sid: events])
            let archive = try ClaudeTelemetryExporter.make(snapshot: snapshot, selection: .init(start: day.date, end: day.end, timezone: "UTC"),
                transcripts: [sid: transcript], appVersion: "1.5.5", helperVersion: nil, contract: 3)
            try require(archive.eventCount == 25 && archive.bytes.range(of: Data("cumulativeSessionContext\":true".utf8)) != nil,
                        "Period included exclusive end or lost cumulative context label")
        }
        await check("Telemetry export: fresh aliases, numeric rates, selected events, absent JSONL and no secrets in ZIP") {
            let (transcript, batch) = try pricedFixture()
            let snapshot = TelemetrySnapshot(sessions: [sid: batch.events, other: [try self.batch([row(session: other)]).events[0]]])
            let selection = TelemetryExportSelection(sessionIDs: [sid], timezone: "Europe/Moscow")
            let archive = try ClaudeTelemetryExporter.make(snapshot: snapshot, selection: selection, transcripts: [sid: transcript], appVersion: "1.5.5", helperVersion: "fixture", contract: 3)
            let again = try ClaudeTelemetryExporter.make(snapshot: snapshot, selection: selection, transcripts: [sid: transcript], appVersion: "1.5.5", helperVersion: "fixture", contract: 3)
            try require(archive.sessionCount == 1 && archive.eventCount == 26 && archive.bytes != again.bytes, "Selection/aliases")
            for forbidden in [sid, other, secret, "anthropic/claude-sonnet-5.5", "req-0", "Synthetic prompt", "permissions", "exportText"] {
                try require(archive.bytes.range(of: Data(forbidden.utf8)) == nil, "Direct identifier/content in ZIP: \(forbidden)")
            }
            try require(archive.bytes.range(of: Data("inputCostPerToken".utf8)) != nil, "Numeric rates missing")
            let noJSONL = try ClaudeTelemetryExporter.make(snapshot: snapshot, selection: .init(sessionIDs: [other], timezone: "UTC"), transcripts: [:], appVersion: "1.5.5", helperVersion: nil, contract: nil)
            try require(noJSONL.bytes.range(of: Data("transcript_unavailable".utf8)) != nil && noJSONL.eventCount == 1, "No-JSONL session omitted")
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("archive.zip"); try ClaudeTelemetryExporter.save(archive, to: url)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = ["-t", url.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try process.run(); process.waitUntilExit()
            try require(process.terminationStatus == 0, "ZIP CRC/central directory invalid")
        }
    }
}
