import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Send to PeopleMaps for the trip logs (Docs/REPORTS.md 4.8): one tap puts each log file on the Worker with
// `PUT /v1/logs/<batch>/<name>`, under the same App Attest download token as a region download. Nothing runs on a timer.

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
    /// The Worker's `MAX_LOG_BYTES`.
    public static let maxBytes = 25 * 1024 * 1024

    private let base: URL
    private let authorizer: DownloadAuthorizer
    private let transport: ReportsClient.Transport

    public init(base: URL = WorkerSource.defaultBase, authorizer: DownloadAuthorizer, transport: ReportsClient.Transport? = nil) {
        self.base = base; self.authorizer = authorizer
        self.transport = transport ?? ReportsClient.urlSession(URLSession(configuration: .ephemeral))
    }

    #if canImport(DeviceCheck) && canImport(Security)
    public init(base: URL = WorkerSource.defaultBase) {
        self.init(base: base, authorizer: DownloadAuthorizer(client: AttestClient(baseURL: base, service: DeviceCheckAttestService()), store: KeychainDownloadTokenStore()))
    }
    #endif

    /// Sends `files` one at a time under one new batch, calling `sent` after each so a later failure keeps what got through.
    /// A file over `maxBytes` stops the run before anything is sent.
    public func send(_ files: [LogFile], batch: UUID = UUID(), sent: @Sendable (LogFile) async -> Void) async throws {
        if let big = files.first(where: { $0.bytes > Self.maxBytes }) { throw LogUploadError.tooLarge(big.name) }
        let folder = batch.uuidString.lowercased()
        for file in files {
            guard let body = try? Data(contentsOf: file.url), Sha256.hexOf(body) == file.sha256 else { continue }   // changed since: next tap
            try await put(body, path: "v1/logs/\(folder)/\(file.name)", sha256: file.sha256, retried: false)
            await sent(file)
        }
    }

    private func put(_ body: Data, path: String, sha256: String, retried: Bool) async throws {
        let token: String
        do { token = try await authorizer.token() } catch let e as RegionError {
            switch e {
            case .deviceCannotAttest, .attestUnavailable: throw LogUploadError.cannotAttest
            case .serverBusy: throw LogUploadError.busy(retryAfter: nil)
            default: throw LogUploadError.unavailable
            }
        } catch let e as URLError { throw ReportsClient.map(e) == .noConnection ? LogUploadError.noConnection : LogUploadError.unavailable }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue(sha256, forHTTPHeaderField: "X-Content-SHA256")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response: ReportsHTTPResponse
        do { response = try await transport(request) } catch let e as URLError {
            throw ReportsClient.map(e) == .noConnection ? LogUploadError.noConnection : LogUploadError.unavailable
        }
        switch response.status {
        case 200, 201: return
        case 401 where !retried:
            await authorizer.rejected(token)
            try await put(body, path: path, sha256: sha256, retried: true)
        case 413: throw LogUploadError.tooLarge((path as NSString).lastPathComponent)
        case 429: throw LogUploadError.busy(retryAfter: response.retryAfter.flatMap { Int($0) })
        default: throw LogUploadError.unavailable
        }
    }
}

extension Sha256 {
    /// Hex SHA-256 of bytes in memory, as `hex(of:)` gives for a file.
    public static func hexOf(_ data: Data) -> String { digest(data).map { String(format: "%02x", $0) }.joined() }
}
