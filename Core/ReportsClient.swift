import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The reports API client, Docs/REPORTS.md 4 and 8.3. Every call is one tap: nothing here runs on a timer or at launch.

/// The install ID and bearer token of 4.1. The app keeps them in the Keychain.
public struct ReportCredentials: Codable, Equatable, Sendable {
    public var installID: String
    public var token: String
    /// A `DELETE /v1/installs/me` may have landed with its answer lost: only then does a 401 mean deleted (4.4).
    public var deleteAttempted: Bool
    public init(installID: String, token: String, deleteAttempted: Bool = false) {
        self.installID = installID; self.token = token; self.deleteAttempted = deleteAttempted
    }

    private enum CodingKeys: String, CodingKey { case installID, token, deleteAttempted }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(installID: try c.decode(String.self, forKey: .installID), token: try c.decode(String.self, forKey: .token),
                  deleteAttempted: try c.decodeIfPresent(Bool.self, forKey: .deleteAttempted) ?? false)
    }

    /// The shape the Worker issues: `pm_` and 43 base64url characters. Anything else cannot match an install.
    var tokenIsWellFormed: Bool {
        token.hasPrefix("pm_") && token.count == 46
            && token.dropFirst(3).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// How "Delete my reports" ended (4.4). Only `deleted` may say that reports were deleted.
public enum ReportDeleteResult: Equatable, Sendable {
    /// The server has deleted them: credentials wiped, so mark local copies `withdrawn`.
    case deleted
    /// The server does not know this ID, so nothing was deleted and reports may remain. Credentials kept.
    case notRecognized
}

/// How "Check status" ended (4.4).
public enum ReportStatusResult: Equatable, Sendable {
    case held([ReportReceipt])
    /// An earlier "Delete my reports" did land, its answer lost: credentials wiped, so mark local copies `withdrawn`.
    case deleted
    /// The server does not know this ID, which says nothing about whether reports remain. Credentials kept.
    case notRecognized
}

/// Where the credentials live: the Keychain in the app, memory in tests.
public protocol ReportCredentialStore: Sendable {
    func load() -> ReportCredentials?
    func save(_ credentials: ReportCredentials) throws
    func wipe()
}

/// The error envelope of 4.6 with its HTTP status and `Retry-After` seconds.
public struct ReportsServerError: Equatable, Sendable {
    public enum Code: String, Sendable {
        case unauthorized, notFound = "not_found", invalidReport = "invalid_report", tooLarge = "too_large"
        case conflict, rateLimited = "rate_limited", storageUnavailable = "storage_unavailable", `internal`
    }
    public var status: Int
    public var code: Code
    public var message: String
    /// Dotted path into the body, for `invalid_report`.
    public var field: String?
    public var retryAfter: Int?
}

public enum ReportsError: Error, Equatable, Sendable {
    case noConnection
    /// Any other transport failure, by `URLError` code.
    case transport(Int)
    case server(ReportsServerError)
    /// A status or body the API does not give.
    case unexpected(status: Int)
    /// Check status or Delete my reports with no report ID on the phone: nothing to ask about.
    case noReportID

    /// The code in words-ready form, kept as `lastError`: `invalid_report: note`, `no_connection` (8.3).
    public var summary: String {
        switch self {
        case .noConnection: "no_connection"
        case let .transport(code): "transport: \(code)"
        case let .server(e): e.field.map { "\(e.code.rawValue): \($0)" } ?? e.code.rawValue
        case let .unexpected(status): "http_\(status)"
        case .noReportID: "no_report_id"
        }
    }

    public var serverCode: ReportsServerError.Code? { if case let .server(e) = self { e.code } else { nil } }
}

/// One HTTP exchange, so tests can stand in for the network.
public struct ReportsHTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var retryAfter: String?
    public init(status: Int, body: Data = Data(), retryAfter: String? = nil) { self.status = status; self.body = body; self.retryAfter = retryAfter }
}

public struct ReportsClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> ReportsHTTPResponse

    public var baseURL: URL
    private let transport: Transport

    /// `transport` defaults to an ephemeral `URLSession`: no cache, no cookies (8.1).
    public init(baseURL: URL, transport: Transport? = nil) {
        self.baseURL = baseURL
        self.transport = transport ?? Self.urlSession(URLSession(configuration: .ephemeral))
    }

    public static func urlSession(_ session: URLSession) -> Transport {
        let box = SessionBox(session: session)
        return { request in
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<ReportsHTTPResponse, Error>) in
                box.session.dataTask(with: request) { data, response, error in
                    if let error { return done.resume(throwing: error) }
                    guard let http = response as? HTTPURLResponse else { return done.resume(throwing: URLError(.badServerResponse)) }
                    done.resume(returning: ReportsHTTPResponse(status: http.statusCode, body: data ?? Data(),
                                                               retryAfter: http.value(forHTTPHeaderField: "Retry-After")))
                }.resume()
            }
        }
    }

    // MARK: Endpoints

    /// `POST /v1/installs`, only from inside a Send (4.1).
    public func mintInstall(app: Report.App) async throws -> ReportCredentials {
        let body = ReportJSON.object([("schema", .int(1)), ("app", .object([("version", .string(app.version)), ("build", .string(app.build))]))])
        return try decode(ReportCredentials.self, try await call("POST", "v1/installs", body: Data(ReportEncoder.string(body).utf8), expect: [201]))
    }

    /// `POST /v1/reports`: 201 stored, 200 a retry of the same body.
    public func send(_ report: Report, token: String) async throws -> ReportReceipt {
        try decode(ReportReceipt.self, try await call("POST", "v1/reports", token: token, body: ReportEncoder.data(report), expect: [200, 201]))
    }

    /// `GET /v1/reports`.
    public func reports(token: String) async throws -> [ReportReceipt] {
        struct List: Decodable { var reports: [ReportReceipt] }
        return try decode(List.self, try await call("GET", "v1/reports", token: token, expect: [200])).reports
    }

    /// `GET /v1/reports/{id}`.
    public func report(id: String, token: String) async throws -> ReportReceipt {
        try decode(ReportReceipt.self, try await call("GET", "v1/reports/\(id)", token: token, expect: [200]))
    }

    /// `DELETE /v1/reports/{id}`.
    public func deleteReport(id: String, token: String) async throws {
        _ = try await call("DELETE", "v1/reports/\(id)", token: token, expect: [204])
    }

    /// `DELETE /v1/installs/me`.
    public func deleteInstall(token: String) async throws {
        _ = try await call("DELETE", "v1/installs/me", token: token, expect: [204])
    }

    // MARK: Taps (8.3)

    /// Send: mints on the first send; on a 401 calls `onReset`, wipes the credentials, mints and retries once. `onReset` is
    /// told whether an earlier delete landed (mark local copies `withdrawn`) or not ("Your report ID was reset").
    public func send(_ report: Report, credentials: ReportCredentialStore, onReset: @Sendable (_ deleteLanded: Bool) async -> Void = { _ in }) async throws -> ReportReceipt {
        if let saved = credentials.load() {
            do {
                let receipt = try await send(report, token: saved.token)
                clearDeleteAttempt(saved, in: credentials)
                return receipt
            } catch let e as ReportsError where e.serverCode == .unauthorized {
                await onReset(saved.deleteAttempted)
                credentials.wipe()
            }
        }
        return try await send(report, token: try await mint(app: report.app, into: credentials).token)
    }

    /// Check status: `GET /v1/reports`. Nothing mints (4.1). A 401 means deleted only after a delete whose answer was lost.
    public func checkStatus(credentials: ReportCredentialStore) async throws -> ReportStatusResult {
        guard let saved = credentials.load() else { throw ReportsError.noReportID }
        guard saved.tokenIsWellFormed else { return .notRecognized }
        do {
            let list = try await reports(token: saved.token)
            clearDeleteAttempt(saved, in: credentials)
            return .held(list)
        } catch let e as ReportsError where e.serverCode == .unauthorized {
            guard saved.deleteAttempted else { return .notRecognized }
            credentials.wipe()
            return .deleted
        }
    }

    /// Delete my reports: `DELETE /v1/installs/me`, then the credentials go ("start over", 4.4). The attempt is recorded first,
    /// so a retry after a lost 204 can tell its 401 from that of a token the server never knew, which deletes nothing and keeps
    /// the credentials. A malformed token makes no request. Any other failure keeps them to try again later.
    public func deleteMyReports(credentials: ReportCredentialStore) async throws -> ReportDeleteResult {
        guard var saved = credentials.load() else { throw ReportsError.noReportID }
        guard saved.tokenIsWellFormed else { return .notRecognized }
        let earlierAttempt = saved.deleteAttempted
        saved.deleteAttempted = true
        try credentials.save(saved)
        do {
            try await deleteInstall(token: saved.token)
        } catch let e as ReportsError {
            if case let .server(answer) = e, answer.code != .internal {
                // The Worker answered, so this attempt deleted nothing.
                saved.deleteAttempted = earlierAttempt
                try? credentials.save(saved)
                guard answer.code == .unauthorized else { throw e }
                if !earlierAttempt { return .notRecognized }
            } else {
                throw e
            }
        }
        credentials.wipe()
        return .deleted
    }

    /// The server still knows this token, so an earlier delete never landed.
    private func clearDeleteAttempt(_ saved: ReportCredentials, in credentials: ReportCredentialStore) {
        guard saved.deleteAttempted else { return }
        var cleared = saved
        cleared.deleteAttempted = false
        try? credentials.save(cleared)
    }

    private func mint(app: Report.App, into credentials: ReportCredentialStore) async throws -> ReportCredentials {
        let fresh = try await mintInstall(app: app)
        try credentials.save(fresh)
        return fresh
    }

    // MARK: HTTP

    private func call(_ method: String, _ path: String, token: String? = nil, body: Data? = nil, expect: Set<Int>) async throws -> (Int, Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let response: ReportsHTTPResponse
        do { response = try await transport(request) } catch let e as URLError { throw Self.map(e) }
        if expect.contains(response.status) { return (response.status, response.body) }
        throw Self.error(response)
    }

    static func map(_ e: URLError) -> ReportsError {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            .noConnection
        default: .transport(e.code.rawValue)
        }
    }

    static func error(_ r: ReportsHTTPResponse) -> ReportsError {
        struct Envelope: Decodable { var error: String; var message: String; var field: String? }
        guard let e = try? JSONDecoder().decode(Envelope.self, from: r.body), let code = ReportsServerError.Code(rawValue: e.error) else {
            return .unexpected(status: r.status)
        }
        return .server(.init(status: r.status, code: code, message: e.message, field: e.field, retryAfter: r.retryAfter.flatMap { Int($0) }))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: (status: Int, body: Data)) throws -> T {
        do { return try JSONDecoder().decode(type, from: response.body) } catch { throw ReportsError.unexpected(status: response.status) }
    }
}

/// `URLSession` is thread-safe; this lets the transport closure hold one on every platform.
private struct SessionBox: @unchecked Sendable { let session: URLSession }
