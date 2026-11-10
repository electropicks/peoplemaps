import XCTest
@testable import PeoplemapsCore

final class AppAttestTests: XCTestCase {
    private let base = URL(string: "https://worker.example.test")!
    private let challengeBytes = Data((0..<68).map { UInt8($0) })

    private func make(supported: Bool = true, lifetime: TimeInterval = 86_400, statuses: [String: [Int]] = [:]) -> (AttestFixture, DownloadAuthorizer) {
        let fixture = AttestFixture(challenge: challengeBytes, supported: supported, now: Date(timeIntervalSince1970: 1_800_000_000), lifetime: lifetime, statuses: statuses)
        let client = AttestClient(baseURL: base, service: fixture, transport: fixture.transport)
        return (fixture, DownloadAuthorizer(client: client, store: fixture, now: { fixture.now }))
    }

    func testChallengeThenAttestThenTokenIsCached() async throws {
        let (fixture, authorizer) = make()
        let first = try await authorizer.token()
        let second = try await authorizer.token()
        XCTAssertEqual(first, "pmd_1")
        XCTAssertEqual(second, "pmd_1", "the cached token is reused")
        XCTAssertEqual(fixture.paths, ["POST /v1/attest/challenge", "POST /v1/attest"])
        XCTAssertEqual(fixture.load()?.value, "pmd_1")

        let body = try XCTUnwrap(fixture.attestBodies.first)
        XCTAssertEqual(body["keyId"], "key-1")
        XCTAssertEqual(body["attestation"], Data("attestation-of-key-1".utf8).base64EncodedString())
        XCTAssertEqual(body["challenge"], challengeBytes.base64EncodedString(), "the challenge goes back as received")
        XCTAssertEqual(fixture.hashes, [Data(Sha256.digest(challengeBytes))], "clientDataHash is SHA-256 of the decoded challenge")
        XCTAssertEqual(fixture.keysMade, 1)
    }

    func testAnExpiredTokenIsReplacedAndAnAlmostExpiredOneToo() async throws {
        let (fixture, authorizer) = make(lifetime: 3_600)
        _ = try await authorizer.token()
        fixture.now = fixture.now.addingTimeInterval(3_600 - 30)   // 30 s left: inside the margin
        let second = try await authorizer.token()
        XCTAssertEqual(second, "pmd_2")
        fixture.now = fixture.now.addingTimeInterval(3_600 + 1)
        let third = try await authorizer.token()
        XCTAssertEqual(third, "pmd_3")
        XCTAssertEqual(fixture.keysMade, 3, "each attestation uses a fresh key: the server takes a key once")
    }

    func testAnUnexpiredTokenSurvivesRelaunch() async throws {
        let (fixture, first) = make()
        _ = try await first.token()
        let again = DownloadAuthorizer(client: AttestClient(baseURL: base, service: fixture, transport: fixture.transport), store: fixture, now: { fixture.now })
        let token = try await again.token()
        XCTAssertEqual(token, "pmd_1")
        XCTAssertEqual(fixture.keysMade, 1)
    }

    func testRejectedTokenIsForgottenOnceAndTheNextIsNew() async throws {
        let (fixture, authorizer) = make()
        let old = try await authorizer.token()
        await authorizer.rejected(old)
        XCTAssertNil(fixture.load())
        let fresh = try await authorizer.token()
        XCTAssertEqual(fresh, "pmd_2")
        await authorizer.rejected(old)   // a late 401 for the old token must not throw the new one away
        XCTAssertEqual(fixture.load()?.value, "pmd_2")
    }

    func testAnUnsupportedDeviceSaysSoAndSendsNothing() async throws {
        let (fixture, authorizer) = make(supported: false)
        do { _ = try await authorizer.token(); XCTFail("should not attest") } catch {
            XCTAssertEqual(error as? RegionError, .deviceCannotAttest)
            XCTAssertEqual(error.localizedDescription, "This device can\u{2019}t prove it\u{2019}s a genuine copy of the app, so map downloads aren\u{2019}t available.")
        }
        XCTAssertTrue(fixture.paths.isEmpty)
        XCTAssertEqual(fixture.keysMade, 0)
    }

    func testServerAnswersBecomePlainErrors() async throws {
        for (status, expected) in [(401, RegionError.attestFailed), (429, .serverBusy), (400, .attestFailed), (404, .sourceUnavailable), (500, .sourceUnavailable)] {
            let (_, authorizer) = make(statuses: ["POST /v1/attest": [status]])
            do { _ = try await authorizer.token(); XCTFail("\(status) should fail") } catch { XCTAssertEqual(error as? RegionError, expected, "\(status)") }
        }
        let (_, authorizer) = make(statuses: ["POST /v1/attest/challenge": [429]])
        do { _ = try await authorizer.token(); XCTFail() } catch { XCTAssertEqual(error as? RegionError, .serverBusy) }
    }

    func testAppleFailingIsNotBlamedOnThePerson() async throws {
        let (fixture, authorizer) = make()
        fixture.attestError = true
        do { _ = try await authorizer.token(); XCTFail() } catch {
            XCTAssertEqual(error as? RegionError, .attestUnavailable)
            XCTAssertTrue(error.localizedDescription.hasSuffix("Try again in a moment."))
        }
        XCTAssertNil(fixture.load())
    }

    func testWorkerSourceNamesFilesAndAddsBearer() async throws {
        let (_, authorizer) = make()
        let source = WorkerSource(base: base, authorizer: authorizer)
        let url = try await source.url(for: "expected/seattle-graph.bin", in: "king-county", release: "data-seattle-all-2026-11d")
        XCTAssertEqual(url.absoluteString, "https://worker.example.test/v1/regions/data-seattle-all-2026-11d/king-county--expected__seattle-graph.bin")
        let auth = try await source.authorization()
        XCTAssertEqual(auth, "Bearer pmd_1")
        await source.authorizationRejected(auth)
        let next = try await source.authorization()
        XCTAssertEqual(next, "Bearer pmd_2")
        XCTAssertEqual(WorkerSource.defaultBase.absoluteString, "https://peoplemaps-reports.peoplemaps.workers.dev")
    }
}

/// A device, a Worker and a token store in one, counting what happened.
final class AttestFixture: AppAttestService, DownloadTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    let challenge: Data
    let supported: Bool
    private var _now: Date
    var now: Date { get { lock.withLock { _now } } set { lock.withLock { _now = newValue } } }
    let lifetime: TimeInterval
    private var statuses: [String: [Int]]
    private var _paths: [String] = []
    private var _bodies: [[String: String]] = []
    private var _hashes: [Data] = []
    private var _keys = 0
    private var issued = 0
    private var saved: DownloadToken?
    private var _attestError = false
    var paths: [String] { lock.withLock { _paths } }
    var attestBodies: [[String: String]] { lock.withLock { _bodies } }
    var hashes: [Data] { lock.withLock { _hashes } }
    var keysMade: Int { lock.withLock { _keys } }
    var attestError: Bool { get { lock.withLock { _attestError } } set { lock.withLock { _attestError = newValue } } }

    init(challenge: Data, supported: Bool, now: Date, lifetime: TimeInterval, statuses: [String: [Int]]) {
        self.challenge = challenge; self.supported = supported; _now = now; self.lifetime = lifetime; self.statuses = statuses
    }

    var isSupported: Bool { supported }
    func generateKey() async throws -> String { lock.withLock { _keys += 1; return "key-\(_keys)" } }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            if _attestError { throw NSError(domain: "DCErrorDomain", code: 3) }
            _hashes.append(clientDataHash)
        }
        return Data("attestation-of-\(keyID)".utf8)
    }

    func load() -> DownloadToken? { lock.withLock { saved } }
    func save(_ token: DownloadToken) { lock.withLock { saved = token } }
    func wipe() { lock.withLock { saved = nil } }

    var transport: ReportsClient.Transport {
        { [self] request in
            let line = "\(request.httpMethod ?? "") \(request.url!.path)"
            return lock.withLock {
                _paths.append(line)
                if var queue = statuses[line], !queue.isEmpty {
                    let status = queue.removeFirst(); statuses[line] = queue
                    return ReportsHTTPResponse(status: status, body: Data(#"{"error":"unauthorized","message":"no"}"#.utf8))
                }
                if line == "POST /v1/attest/challenge" {
                    return ReportsHTTPResponse(status: 201, body: Data(#"{"challenge":"\#(challenge.base64EncodedString())","expiresAt":"2026-11-05T00:05:00Z"}"#.utf8))
                }
                let sent = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]) ?? [:]
                _bodies.append(sent)
                issued += 1
                let expires = ISO8601DateFormatter().string(from: _now.addingTimeInterval(lifetime))
                return ReportsHTTPResponse(status: 200, body: Data(#"{"token":"pmd_\#(issued)","expiresAt":"\#(expires)"}"#.utf8))
            }
        }
    }
}
