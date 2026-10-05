import Foundation
import Network

/// A short-lived loopback handoff of one verified archive to Sparkle's downloader.
/// Sparkle independently checks its EdDSA signature again before extraction.
final class UpdateArchiveServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LLMUsage.update-archive")
    private let listener: NWListener
    private let bytes: Data
    private let route = "/" + UUID().uuidString + "/update.zip"
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(file: URL, archive: UpdateArchive) throws {
        try archive.verify(file)
        bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, let reply = self.startContinuation else { return }
                switch state {
                case .ready:
                    self.startContinuation = nil
                    guard let port = self.listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(self.route)") else {
                        reply.resume(throwing: URLError(.cannotConnectToHost)); return
                    }
                    reply.resume(returning: url)
                case .failed(let error): self.startContinuation = nil; reply.resume(throwing: error)
                case .cancelled: self.startContinuation = nil; reply.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.connections.count < 4 else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
                self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finish(connection) }
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            let request = accumulated + (data ?? Data())
            guard request.count <= 16_384, error == nil else { self.finish(connection); return }
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if done { self.finish(connection) } else { self.receive(connection, accumulated: request) }
                return
            }
            guard text.hasPrefix("GET \(self.route) HTTP/1.") else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in self.finish(connection) })
                return
            }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: \(self.bytes.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                if error != nil { self.finish(connection) } else { self.send(connection, offset: 0) }
            })
        }
    }
    private func send(_ connection: NWConnection, offset: Int) {
        guard offset < bytes.count else { finish(connection); return }
        let end = min(offset + 256 * 1_024, bytes.count)
        connection.send(content: bytes.subdata(in: offset..<end), completion: .contentProcessed { error in
            if error != nil { self.finish(connection) } else { self.send(connection, offset: end) }
        })
    }
    private func finish(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }
    func stop() {
        listener.cancel()
        queue.async { [self] in
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }
    deinit { listener.cancel() }
}
