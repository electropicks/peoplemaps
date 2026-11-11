import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Send to PeopleMaps for the trip logs (Docs/REPORTS.md 4.8): one tap seals each log file to the owner's key and puts it on the
// Worker with `PUT /v1/logs/<batch>/<name>.enc`, under the same App Attest download token as a region download. Nothing runs on a timer.

/// How a sent log is sealed (`SealedBox`): to the owner's public key, so the server holds bytes it cannot read.
public enum LogSeal {
    public static let info = "peoplemaps log v1"
    /// The public half of the owner's log key, base64 (`peoplemaps-logkey public`). The private half is in the owner's Keychain.
    public static let publicKey = "BPzN1yhSYect8IpQIOSecqeMNwGLjRhVeSSdqJkUN1I="
    public typealias Seal = @Sendable (_ plain: Data, _ name: String) throws -> Data

    #if canImport(CryptoKit)
    public static let toOwner: Seal = { plain, name in
        try SealedBox.seal(plain, to: Data(base64Encoded: publicKey) ?? Data(), info: info, context: name)
    }
    #endif
}

/// One tap of Send: its batch on the server and the secret that deletes it. Kept on the phone until deleted or expired.
public struct SentLogBatch: Codable, Equatable, Sendable {
    public var id: String
    /// 32 random bytes, hex. The server holds only its SHA-256.
    public var secret: String
    public var sentAt: Date
    public init(id: String = UUID().uuidString.lowercased(), secret: String = SentLogBatch.newSecret(), sentAt: Date = Date()) {
        self.id = id; self.secret = secret; self.sentAt = sentAt
    }
    public static func newSecret() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &g)) }.joined()
    }
    var secretHash: String { Sha256.hexOf(Data(secret.utf8)) }
}

/// A file to send and its fingerprint, worked out before the confirmation names the count and size.
public struct LogFile: Equatable, Sendable {
    public var url: URL
    public var bytes: Int
    public var sha256: String
    public var name: String { url.lastPathComponent }

    public init(url: URL, bytes: Int, sha256: String) { self.url = url; self.bytes = bytes; self.sha256 = sha256 }

    /// The files in `urls` whose contents are not in `sent` (SHA-256s of what was sent before). By contents, not name: the usage
    /// log's file is named for the day it is shared, and a trip file that grew since is sent again. Empty files are left out.
    public static func unsent(_ urls: [URL], sent: Set<String>) -> [LogFile] {
        urls.compactMap { url in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, let hash = try? Sha256.hex(of: url) else { return nil }
            return sent.contains(hash) ? nil : LogFile(url: url, bytes: size, sha256: hash)
        }
    }
}

public enum LogUploadError: Error, Equatable, Sendable {
    case noConnection
    /// Larger than the server takes (`LogUploader.maxBytes`): Share still works.
    case tooLarge(String)
    /// The day's ceiling or the rate limit; `retryAfter` in seconds when the server gave one.
    case busy(retryAfter: Int?)
    /// Not deployed, failing, or turned the token away twice.
    case unavailable
    /// This device can't prove it is a genuine copy of the app (a simulator, or App Attest off).
    case cannotAttest
}

public struct LogUploader: Sendable {
    /// The Worker's `MAX_LOG_BYTES`, less room for the seal.
    public static let maxBytes = 25 * 1024 * 1024 - 1024

    private let base: URL
    private let authorizer: DownloadAuthorizer
    private let transport: ReportsClient.Transport
    private let seal: LogSeal.Seal

    public init(base: URL = WorkerSource.defaultBase, authorizer: DownloadAuthorizer, seal: @escaping LogSeal.Seal, transport: ReportsClient.Transport? = nil) {
        self.base = base; self.authorizer = authorizer; self.seal = seal
        self.transport = transport ?? ReportsClient.urlSession(URLSession(configuration: .ephemeral))
    }

    #if canImport(DeviceCheck) && canImport(Security) && canImport(CryptoKit)
    public init(base: URL = WorkerSource.defaultBase) {
        self.init(base: base, authorizer: DownloadAuthorizer(client: AttestClient(baseURL: base, service: DeviceCheckAttestService()), store: KeychainDownloadTokenStore()), seal: LogSeal.toOwner)
    }
    #endif

    /// Seals and sends `files` one at a time under `batch`, calling `sent` after each so a later failure keeps what got through.
    /// A file over `maxBytes` stops the run before anything is sent. The caller keeps `batch` to delete it later.
    public func send(_ files: [LogFile], batch: SentLogBatch, sent: @Sendable (LogFile) async -> Void) async throws {
        if let big = files.first(where: { $0.bytes > Self.maxBytes }) { throw LogUploadError.tooLarge(big.name) }
        for file in files {
            guard let plain = try? Data(contentsOf: file.url), Sha256.hexOf(plain) == file.sha256 else { continue }   // changed since: next tap
            guard let box = try? seal(plain, file.name) else { throw LogUploadError.unavailable }
            try await call("PUT", "v1/logs/\(batch.id)/\(file.name).enc", body: box, headers: [
                "Content-Type": "application/octet-stream", "X-Content-SHA256": Sha256.hexOf(box), "X-Delete-SHA256": batch.secretHash,
            ], expect: [200, 201], retried: false)
            await sent(file)
        }
    }

    /// `DELETE /v1/logs/<batch>`: removes what is still on the server of one Send. Also succeeds when nothing is left.
    public func delete(_ batch: SentLogBatch) async throws {
        try await call("DELETE", "v1/logs/\(batch.id)", body: nil, headers: ["X-Delete-Secret": batch.secret], expect: [204], retried: false)
    }

    private func call(_ method: String, _ path: String, body: Data?, headers: [String: String], expect: Set<Int>, retried: Bool) async throws {
        let token: String
        do { token = try await authorizer.token() } catch let e as RegionError {
            switch e {
            case .deviceCannotAttest, .attestUnavailable: throw LogUploadError.cannotAttest
            case .serverBusy: throw LogUploadError.busy(retryAfter: nil)
            default: throw LogUploadError.unavailable
            }
        } catch let e as URLError { throw ReportsClient.map(e) == .noConnection ? LogUploadError.noConnection : LogUploadError.unavailable }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response: ReportsHTTPResponse
        do { response = try await transport(request) } catch let e as URLError {
            throw ReportsClient.map(e) == .noConnection ? LogUploadError.noConnection : LogUploadError.unavailable
        }
        switch response.status {
        case _ where expect.contains(response.status): return
        case 401 where !retried:
            await authorizer.rejected(token)
            try await call(method, path, body: body, headers: headers, expect: expect, retried: true)
        case 413: throw LogUploadError.tooLarge(String((path as NSString).lastPathComponent.dropLast(4)))
        case 429: throw LogUploadError.busy(retryAfter: response.retryAfter.flatMap { Int($0) })
        default: throw LogUploadError.unavailable
        }
    }
}

extension Sha256 {
    /// Hex SHA-256 of bytes in memory, as `hex(of:)` gives for a file.
    public static func hexOf(_ data: Data) -> String { digest(data).map { String(format: "%02x", $0) }.joined() }
}
