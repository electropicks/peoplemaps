import XCTest
@testable import PeoplemapsCore

final class LogUploadTests: XCTestCase {
    private let base = URL(string: "https://worker.example.test")!
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("log-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// The attest fixture for the token, and a Worker that records each PUT and answers from `statuses` first.
    private func make(statuses: [Int] = []) -> (LogUploader, Recorder) {
        let fixture = AttestFixture(challenge: Data(count: 68), supported: true, now: Date(), lifetime: 86_400, statuses: [:])
        let authorizer = DownloadAuthorizer(client: AttestClient(baseURL: base, service: fixture, transport: fixture.transport), store: fixture)
        let recorder = Recorder(statuses: statuses)
        return (LogUploader(base: base, authorizer: authorizer, transport: recorder.transport), recorder)
    }

    func testUnsentSkipsWhatWasSentAndEmptyFiles() throws {
        let a = try file("use-2026-11-10.jsonl", "{\"a\":1}\n")
        let b = try file("trip-20261110T221320Z-drive.jsonl", "{\"b\":2}\n")
        let empty = try file("use-2026-11-09.jsonl", "")
        let hashA = try Sha256.hex(of: a)
        let unsent = LogFile.unsent([a, b, empty], sent: [hashA])
        XCTAssertEqual(unsent.map(\.name), ["trip-20261110T221320Z-drive.jsonl"])
        XCTAssertEqual(unsent.first?.bytes, 8)
        XCTAssertEqual(LogFile.unsent([a], sent: ["old"]).map(\.name), ["use-2026-11-10.jsonl"], "a file that grew is sent again")
        XCTAssertEqual(Sha256.hexOf(Data("{\"a\":1}\n".utf8)), hashA)
    }

    func testSendsEachFileUnderOneBatchWithItsHashAndToken() async throws {
        let files = LogFile.unsent([try file("use-2026-11-10.jsonl", "x\n"), try file("rec-20261110T221320Z.jsonl", "y\n")], sent: [])
        let (uploader, worker) = make()
        let batch = UUID(uuidString: "0B6F7A52-3C1D-4E8F-9A2B-1C3D5E7F9A0B")!
        let done = Box()
        try await uploader.send(files, batch: batch) { done.add($0.name) }
        XCTAssertEqual(worker.requests.map(\.path), [
            "PUT /v1/logs/0b6f7a52-3c1d-4e8f-9a2b-1c3d5e7f9a0b/use-2026-11-10.jsonl",
            "PUT /v1/logs/0b6f7a52-3c1d-4e8f-9a2b-1c3d5e7f9a0b/rec-20261110T221320Z.jsonl",
        ])
        XCTAssertEqual(worker.requests.map(\.sha), files.map(\.sha256))
        XCTAssertEqual(worker.requests.map(\.auth), ["Bearer pmd_1", "Bearer pmd_1"])
        XCTAssertEqual(worker.requests.first?.body, Data("x\n".utf8))
        XCTAssertEqual(done.names, files.map(\.name))
    }

    func testA401GetsOneFreshTokenThenGivesUp() async throws {
        let files = LogFile.unsent([try file("use-2026-11-10.jsonl", "x\n")], sent: [])
        let (uploader, worker) = make(statuses: [401])
        try await uploader.send(files) { _ in }
        XCTAssertEqual(worker.requests.map(\.auth), ["Bearer pmd_1", "Bearer pmd_2"])

        let (again, _) = make(statuses: [401, 401])
        do { try await again.send(files) { _ in }; XCTFail("expected a failure") } catch { XCTAssertEqual(error as? LogUploadError, .unavailable) }
    }

    func testFailuresKeepWhatGotThrough() async throws {
        let files = LogFile.unsent([try file("use-2026-11-09.jsonl", "a\n"), try file("use-2026-11-10.jsonl", "b\n")], sent: [])
        let (uploader, _) = make(statuses: [201, 429])
        let done = Box()
        do { try await uploader.send(files) { done.add($0.name) }; XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? LogUploadError, .busy(retryAfter: 60))
        }
        XCTAssertEqual(done.names, ["use-2026-11-09.jsonl"])
    }

    func testAFileOverTheLimitStopsBeforeAnythingIsSent() async throws {
        let url = try file("trip-20261110T221320Z-drive.jsonl", "x\n")
        let (uploader, worker) = make()
        let big = LogFile(url: url, bytes: LogUploader.maxBytes + 1, sha256: "0")
        do { try await uploader.send([big]) { _ in }; XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? LogUploadError, .tooLarge("trip-20261110T221320Z-drive.jsonl"))
        }
        XCTAssertTrue(worker.requests.isEmpty)
    }

    func testAFileChangedSinceItWasCheckedWaitsForTheNextTap() async throws {
        let url = try file("use-2026-11-10.jsonl", "x\n")
        let files = LogFile.unsent([url], sent: [])
        try Data("x\ny\n".utf8).write(to: url)
        let (uploader, worker) = make()
        try await uploader.send(files) { _ in }
        XCTAssertTrue(worker.requests.isEmpty)
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []
    var names: [String] { lock.withLock { _names } }
    func add(_ name: String) { lock.withLock { _names.append(name) } }
}

private final class Recorder: @unchecked Sendable {
    struct Seen { var path: String; var sha: String?; var auth: String?; var body: Data? }
    private let lock = NSLock()
    private var statuses: [Int]
    private var _requests: [Seen] = []
    var requests: [Seen] { lock.withLock { _requests } }
    init(statuses: [Int]) { self.statuses = statuses }

    var transport: ReportsClient.Transport {
        { [self] request in
            lock.withLock {
                _requests.append(Seen(path: "\(request.httpMethod ?? "") \(request.url!.path)", sha: request.value(forHTTPHeaderField: "X-Content-SHA256"),
                                      auth: request.value(forHTTPHeaderField: "Authorization"), body: request.httpBody))
                let status = statuses.isEmpty ? 201 : statuses.removeFirst()
                return ReportsHTTPResponse(status: status, body: Data("{}".utf8), retryAfter: status == 429 ? "60" : nil)
            }
        }
    }
}
