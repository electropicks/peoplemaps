import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(DeviceCheck)
import DeviceCheck
#endif
#if canImport(Security)
import Security
#endif

// The app's half of Docs/REPORTS.md 4.5 and 4.7: prove this is a genuine copy of the app with App Attest, get a 24 hour download token,
// and hand it to `WorkerSource`. Nothing here runs unless a region download starts.

/// What `DCAppAttestService` gives us, so tests can stand in for the device.
public protocol AppAttestService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    /// `clientDataHash` is SHA-256 of the challenge bytes.
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
}

#if canImport(DeviceCheck)
public struct DeviceCheckAttestService: AppAttestService, @unchecked Sendable {
    public init() {}
    public var isSupported: Bool { DCAppAttestService.shared.isSupported }
    public func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }
    public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }
}
#endif

/// The `pmd_` token of 4.7 and when the server stops accepting it.
public struct DownloadToken: Codable, Equatable, Sendable {
    public var value: String
    public var expiresAt: Date
    public init(value: String, expiresAt: Date) { self.value = value; self.expiresAt = expiresAt }
    /// Still good for at least `margin` seconds.
    public func isValid(at now: Date = Date(), margin: TimeInterval = 60) -> Bool { expiresAt.timeIntervalSince(now) > margin }
}

/// Where the token lives: the Keychain in the app, memory in tests. Never UserDefaults.
public protocol DownloadTokenStore: Sendable {
    func load() -> DownloadToken?
    func save(_ token: DownloadToken)
    func wipe()
}

#if canImport(Security)
public struct KeychainDownloadTokenStore: DownloadTokenStore {
    private let service: String
    private let account = "download-token"
    public init(service: String = "electrocorp.peoplemaps.downloads") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> DownloadToken? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(DownloadToken.self, from: data)
    }

    public func save(_ token: DownloadToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    public func wipe() { SecItemDelete(query as CFDictionary) }
}
#endif

/// `POST /v1/attest/challenge` and `POST /v1/attest`.
public struct AttestClient: Sendable {
    public var baseURL: URL
    private let service: any AppAttestService
    private let transport: ReportsClient.Transport
    private let now: @Sendable () -> Date

    public init(baseURL: URL, service: any AppAttestService, transport: ReportsClient.Transport? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL; self.service = service; self.now = now
        self.transport = transport ?? ReportsClient.urlSession(URLSession(configuration: .ephemeral))
    }

    /// One full exchange: a fresh key (the server accepts each key once, 4.5), its attestation of a fresh challenge, and the token.
    public func fetchToken() async throws -> DownloadToken {
        guard service.isSupported else { throw RegionError.deviceCannotAttest }
        let challenge = try await challenge()
        let keyID: String, attestation: Data
        do {
            keyID = try await service.generateKey()
            attestation = try await service.attestKey(keyID, clientDataHash: Data(Sha256.digest(challenge.bytes)))
        } catch { throw RegionError.attestUnavailable }
        return try await attest(keyID: keyID, attestation: attestation, challenge: challenge.encoded)
    }

    func challenge() async throws -> (bytes: Data, encoded: String) {
        struct Reply: Decodable { var challenge: String }
        let (_, body) = try await post("v1/attest/challenge", body: Data("{}".utf8), expect: [200, 201])
        guard let reply = try? JSONDecoder().decode(Reply.self, from: body), let bytes = Data(base64Encoded: reply.challenge) else { throw RegionError.attestFailed }
        return (bytes, reply.challenge)
    }

    func attest(keyID: String, attestation: Data, challenge: String) async throws -> DownloadToken {
        struct Reply: Decodable { var token: String; var expiresAt: String }
        let json = ReportJSON.object([("keyId", .string(keyID)), ("attestation", .string(attestation.base64EncodedString())), ("challenge", .string(challenge))])
        let (_, body) = try await post("v1/attest", body: Data(ReportEncoder.string(json).utf8), expect: [200])
        guard let reply = try? JSONDecoder().decode(Reply.self, from: body), let expires = Self.parse(reply.expiresAt) else { throw RegionError.attestFailed }
        return DownloadToken(value: reply.token, expiresAt: expires)
    }

    private static func parse(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: s) ?? fractional.date(from: s)
    }

    private func post(_ path: String, body: Data, expect: Set<Int>) async throws -> (Int, Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport(request)
        if expect.contains(response.status) { return (response.status, response.body) }
        switch response.status {
        case 429: throw RegionError.serverBusy
        default: throw RegionError.attestFailed
        }
    }
}

/// Hands out a valid download token: the cached one, or a new one from the attest exchange. One exchange at a time.
public actor DownloadAuthorizer {
    private let client: AttestClient
    private let store: any DownloadTokenStore
    private let now: @Sendable () -> Date
    private var inFlight: Task<DownloadToken, Error>?

    public init(client: AttestClient, store: any DownloadTokenStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.store = store; self.now = now
    }

    public func token() async throws -> String {
        if let saved = store.load(), saved.isValid(at: now()) { return saved.value }
        if let inFlight { return try await inFlight.value.value }
        let task = Task { try await client.fetchToken() }
        inFlight = task
        defer { inFlight = nil }
        let fresh = try await task.value
        store.save(fresh)
        return fresh.value
    }

    /// The server turned `token` away: forget it, unless a newer one has already replaced it.
    public func rejected(_ token: String) {
        if store.load()?.value == token { store.wipe() }
    }
}
