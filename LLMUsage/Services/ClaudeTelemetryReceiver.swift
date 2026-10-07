import Foundation
import Network
import zlib

/// Incremental bounded framing. Header/body bytes are never logged or persisted.
struct TelemetryHTTPParser {
    static let headerLimit = 16 * 1024
    static let bodyLimit = 16 * 1024 * 1024
    enum Failure: Int, Error { case badRequest = 400, forbidden = 403, missing = 404, tooLarge = 413, unsupported = 415, expectation = 417 }
    private var buffer = Data()
    private var body = Data()
    private var headersDone = false
    private var contentLength: Int?
    private var chunked = false
    private var compressed = false
    private var chunkRemaining: Int?
    private var ending = false
    private var wireBytes = 0
    private var completed = false
    mutating func append(_ data: Data) throws -> Data? {
        guard !completed else { throw Failure.badRequest }
        wireBytes += data.count
        guard wireBytes <= Self.bodyLimit + Self.headerLimit else { throw Failure.tooLarge }
        buffer.append(data)
        if !headersDone {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard buffer.count <= Self.headerLimit else { throw Failure.tooLarge }; return nil
            }
            guard end.upperBound <= Self.headerLimit, let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { throw Failure.badRequest }
            let lines = text.components(separatedBy: "\r\n")
            guard lines.first == "POST /v1/logs HTTP/1.1" || lines.first == "POST /v1/logs HTTP/1.0" else { throw Failure.missing }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw Failure.badRequest }
                let key = String(line[..<colon]).lowercased()
                guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[key] == nil else { throw Failure.badRequest }
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                guard !value.utf8.contains(where: { $0 < 32 && $0 != 9 }) else { throw Failure.badRequest }
                headers[key] = value
            }
            guard headers["origin"] == nil else { throw Failure.forbidden }
            guard headers["expect"] == nil else { throw Failure.expectation }
            guard headers["content-type"]?.lowercased().split(separator: ";").first == "application/json" else { throw Failure.unsupported }
            switch headers["content-encoding"]?.lowercased() ?? "identity" {
            case "identity": break
            case "gzip": compressed = true
            default: throw Failure.unsupported
            }
            if let transfer = headers["transfer-encoding"] {
                guard transfer.lowercased() == "chunked", headers["content-length"] == nil else { throw Failure.badRequest }
                chunked = true
            } else {
                guard let text = headers["content-length"], !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(text), length <= Self.bodyLimit else { throw Failure.tooLarge }
                contentLength = length
            }
            buffer = Data(buffer[end.upperBound...]); headersDone = true
        }
        if chunked {
            while true {
                if ending {
                    guard buffer.count >= 2 else { return nil }
                    // Trailer fields are deliberately unsupported, not silently ignored.
                    guard buffer == Data("\r\n".utf8) else { throw Failure.badRequest }
                    return try finish()
                }
                if chunkRemaining == nil {
                    guard let end = buffer.range(of: Data("\r\n".utf8)) else {
                        guard buffer.count <= 128 else { throw Failure.badRequest }; return nil
                    }
                    guard end.lowerBound <= 16, let text = String(data: buffer[..<end.lowerBound], encoding: .utf8), !text.isEmpty,
                          text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }), let size = Int(text, radix: 16), size <= Self.bodyLimit - body.count else { throw Failure.tooLarge }
                    buffer = Data(buffer[end.upperBound...])
                    if size == 0 { ending = true; continue }
                    chunkRemaining = size
                }
                let size = chunkRemaining!
                guard buffer.count >= size + 2 else { return nil }
                guard buffer[size] == 13, buffer[size + 1] == 10 else { throw Failure.badRequest }
                body.append(buffer.prefix(size)); buffer = Data(buffer.dropFirst(size + 2)); chunkRemaining = nil
            }
        } else {
            guard let length = contentLength, buffer.count <= length else { throw Failure.badRequest }
            guard buffer.count == length else { return nil }
            body = buffer; return try finish()
        }
    }
    private mutating func finish() throws -> Data {
        completed = true
        return compressed ? try Self.gunzip(body) : body
    }
    static func gunzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.unsupported }
        defer { inflateEnd(&stream) }
        var output = Data()
        try input.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(bytes.count)
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress; stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = chunk.count - Int(stream.avail_out)
                guard output.count + count <= bodyLimit else { throw Failure.tooLarge }
                output.append(contentsOf: chunk.prefix(count))
                if status == Z_STREAM_END { guard stream.avail_in == 0 else { throw Failure.badRequest }; break }
                guard status == Z_OK, count > 0 || stream.avail_in > 0 else { throw Failure.badRequest }
            }
        }
        return output
    }
}

private actor TelemetryDecoder {
    func decode(_ body: Data) throws -> ClaudeTelemetryBatch { try ClaudeTelemetrySanitizer.sanitize(body) }
}

final class ClaudeTelemetryReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LLMUsage.claude-telemetry", qos: .utility)
    private let listener: NWListener
    private let decoder = TelemetryDecoder()
    private let store: ClaudeTelemetryStore
    private let update: @Sendable (Set<String>, TelemetryFailure?) -> Void
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var workers: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var stopped = false
    private var requestTimes: [Date] = []

    init(port: UInt16, store: ClaudeTelemetryStore, update: @escaping @Sendable (Set<String>, TelemetryFailure?) -> Void = { _, _ in }) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = false
        listener = try NWListener(using: parameters)
        self.store = store; self.update = update
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !stopped else { continuation.resume(throwing: TelemetryFailure.disabled); return }
                self.continuation = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let reply = self.continuation { self.continuation = nil; reply.resume(returning: self.listener.port!.rawValue) }
                    case .failed:
                        if let reply = self.continuation { self.continuation = nil; reply.resume(throwing: TelemetryFailure.port) }
                        else { self.update([], .port) }
                    case .cancelled:
                        if let reply = self.continuation { self.continuation = nil; reply.resume(throwing: TelemetryFailure.disabled) }
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            }
        }
    }
    private func accept(_ connection: NWConnection) {
        requestTimes.removeAll { Date().timeIntervalSince($0) > 60 }
        guard !stopped, connections.count < 4, requestTimes.count < 120 else { connection.cancel(); return }
        requestTimes.append(Date())
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        receive(connection, parser: TelemetryHTTPParser())
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish(connection) }
    }
    private func receive(_ connection: NWConnection, parser: TelemetryHTTPParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self, !self.stopped, self.connections[ObjectIdentifier(connection)] != nil else { connection.cancel(); return }
            do {
                guard error == nil else { throw TelemetryFailure.transport }
                var parser = parser
                if let body = try parser.append(data ?? Data()) {
                    let key = ObjectIdentifier(connection)
                    self.workers[key] = Task { [weak self, store = self.store, decoder = self.decoder] in
                        do {
                            let batch = try await decoder.decode(body)
                            try Task.checkCancellation()
                            _ = try await store.accept(batch)
                            let rejected = batch.rejected + batch.unmatched
                            let response = rejected == 0 ? "{}" : "{\"partialSuccess\":{\"rejectedLogRecords\":\"\(rejected)\",\"errorMessage\":\"Unsupported or invalid API metadata\"}}"
                            self?.update(Set(batch.events.map(\.sessionID)), nil)
                            self?.respond(connection, code: 200, body: response)
                        } catch is CancellationError { self?.respond(connection, code: 503) }
                        catch let error as TelemetryFailure where [.invalidJSON, .limit].contains(error) {
                            try? await store.rejectPacket(); self?.update([], nil); self?.respond(connection, code: error == .limit ? 413 : 400)
                        } catch {
                            self?.update([], .storage); self?.respond(connection, code: 503)
                        }
                    }
                } else if done { self.respond(connection, code: 400) }
                else { self.receive(connection, parser: parser) }
            } catch {
                let code = (error as? TelemetryHTTPParser.Failure)?.rawValue ?? 400
                Task { try? await self.store.rejectPacket(); self.update([], nil) }
                self.respond(connection, code: code)
            }
        }
    }
    private func respond(_ connection: NWConnection, code: Int, body: String = "{\"code\":3,\"message\":\"Telemetry request failed\"}") {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.connections[ObjectIdentifier(connection)] != nil else { return }
            let data = Data(body.utf8)
            let header = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
            connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { [weak self] _ in self?.finish(connection) })
        }
    }
    private func finish(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connection.cancel(); connections.removeValue(forKey: key)
        workers.removeValue(forKey: key)?.cancel()
    }
    func stop() {
        store.gate.set(false)
        queue.async { [self] in
            stopped = true; listener.cancel()
            for connection in Array(connections.values) { finish(connection) }
        }
    }
    deinit { listener.cancel() }
}
