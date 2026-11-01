import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The reports API client, Docs/REPORTS.md 4 and 8.3. Every call is one tap: nothing here runs on a timer or at launch.

/// The install ID and bearer token of 4.1. The app keeps them in the Keychain.
public struct ReportCredentials: Codable, Equatable, Sendable {
    public var installID: String
    public var token: String
    public init(installID: String, token: String) { self.installID = installID; self.token = token }
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

    /// Send: mints on the first send; on a 401 calls `onReset` ("Your report ID was reset"), wipes the credentials,
    /// mints and retries once. The old install's rows went with it, so unsent reports keep their IDs.
    public func send(_ report: Report, credentials: ReportCredentialStore, onReset: @Sendable () async -> Void = {}) async throws -> ReportReceipt {
        if let saved = credentials.load() {
            do { return try await send(report, token: saved.token) } catch let e as ReportsError where e.serverCode == .unauthorized {
                await onReset()
                credentials.wipe()
            }
        }
        return try await send(report, token: try await mint(app: report.app, into: credentials).token)
    }

    /// Check status: `GET /v1/reports`. A 401 wipes the credentials and ends there; nothing mints (4.1).
    public func checkStatus(credentials: ReportCredentialStore) async throws -> [ReportReceipt] {
        guard let saved = credentials.load() else { throw ReportsError.noReportID }
        return try await wipingOn401(credentials) { try await reports(token: saved.token) }
    }

    /// Delete my reports: `DELETE /v1/installs/me`, then the credentials go ("start over", 4.4). A 401 from the Worker counts
    /// as deleted: the retry after a lost 204 looks just like it, and the token is no use either way. A 401 without the
    /// Worker's JSON is some other server (`.unexpected`) and, like any other failure, keeps them to try again later.
    public func deleteMyReports(credentials: ReportCredentialStore) async throws {
        guard let saved = credentials.load() else { throw ReportsError.noReportID }
        do { try await deleteInstall(token: saved.token) } catch let e as ReportsError where e.serverCode == .unauthorized {}
        credentials.wipe()
    }

    private func mint(app: Report.App, into credentials: ReportCredentialStore) async throws -> ReportCredentials {
        let fresh = try await mintInstall(app: app)
        try credentials.save(fresh)
        return fresh
    }

    private func wipingOn401<T>(_ credentials: ReportCredentialStore, _ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch let e as ReportsError where e.serverCode == .unauthorized {
            credentials.wipe()
            throw e
        }
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
