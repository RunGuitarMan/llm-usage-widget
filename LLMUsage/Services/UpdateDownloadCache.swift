import Foundation
import CryptoKit

struct UpdateArchive: Sendable {
    let url: URL
    let length: Int64
    let signature: Data
    let publicKey: Data
    var cacheKey: String { SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined() }
    static let maximumBytes: Int64 = 256 * 1_024 * 1_024
    static func permitsTransport(_ url: URL?) -> Bool {
        #if UPDATE_TESTING
        if url?.scheme == "http", url?.host == "127.0.0.1" { return true }
        #endif
        return url?.scheme == "https"
    }

    func verify(_ file: URL) throws {
        guard length > 0, length <= Self.maximumBytes,
              try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(length) else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard try key.isValidSignature(signature, for: Data(contentsOf: file, options: .mappedIfSafe)) else {
            throw URLError(.secureConnectionFailed)
        }
    }
}

/// Download-only never starts Sparkle's installer (which can otherwise install on quit).
actor UpdateDownloadCache {
    let directory: URL
    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent((Bundle.main.bundleIdentifier ?? "LLMUsage") + "/Updates", isDirectory: true)) {
        self.directory = directory
    }

    func download(_ archive: UpdateArchive, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard UpdateArchive.permitsTransport(archive.url), archive.length > 0, archive.length <= UpdateArchive.maximumBytes else {
            throw URLError(.badURL)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw URLError(.cannotWriteToFile)
        }
        let target = directory.appendingPathComponent(archive.cacheKey + ".zip")
        if FileManager.default.fileExists(atPath: target.path) {
            do { try archive.verify(target); progress(1); return target }
            catch { try FileManager.default.removeItem(at: target) }
        }
        let volume = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = volume.volumeAvailableCapacityForImportantUsage, available < archive.length * 3 {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let transfer = UpdateTransfer(limit: archive.length, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(for: URLRequest(url: archive.url))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try Task.checkCancellation()
        try archive.verify(temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        // Same-volume staging prevents exposing an incomplete cache entry.
        let staged = directory.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: temporary, to: staged)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: staged, to: target)
        // At most two completed archives; user data lives outside this directory.
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let obsolete = files.filter { $0.pathExtension == "zip" && $0 != target }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in obsolete.dropFirst() { try? FileManager.default.removeItem(at: file) }
        return target
    }
}

private final class UpdateTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    let progress: @Sendable (Double) -> Void
    init(limit: Int64, progress: @escaping @Sendable (Double) -> Void) { self.limit = limit; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
        else { progress(min(1, Double(totalBytesWritten) / Double(limit))) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(UpdateArchive.permitsTransport(request.url) ? request : nil)
    }
}
