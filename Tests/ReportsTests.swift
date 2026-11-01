import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PeoplemapsCore

/// Docs/REPORTS.md 2, 3 and 8. The parity fixtures are shared with the Worker (`Backend/test/validate.test.ts`): a report
/// in, the public body and exact part out, plus the exact bytes the Worker reads and stores.
final class ReportsTests: XCTestCase {
    struct ParityCase: Decodable {
        var report: Report
        var `public`: Report
        var reportJSON: String
        var publicJSON: String
        var exactJSON: String?
    }

    static let parityDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Backend/test/fixtures/parity")

    static func parity(_ name: String) throws -> ParityCase {
        try JSONDecoder().decode(ParityCase.self, from: Data(contentsOf: parityDir.appendingPathComponent(name)))
    }

    // MARK: Parity with the Worker

    func testParityFixturesMatchTheWorkerByteForByte() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.parityDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map(\.lastPathComponent).sorted()
        XCTAssertGreaterThanOrEqual(files.count, 4)
        for name in files {
            let c = try Self.parity(name)
            XCTAssertEqual(String(decoding: ReportEncoder.data(c.report), as: UTF8.self), c.reportJSON, name)
            let (pub, exact) = c.report.splitExact()
            XCTAssertEqual(ReportEncoder.string(pub.json), c.publicJSON, name)
            XCTAssertEqual(exact.map { ReportEncoder.string($0.json) }, c.exactJSON, name)
            XCTAssertEqual(pub, c.public, name)
            XCTAssertFalse(c.publicJSON.contains("\"exact\"") || c.publicJSON.contains("\"snapped\""), name)
        }
    }

    /// The snapshot of the `exact.json` moment builds exactly the body the Worker splits, and with exact locations off,
    /// exactly the public body it would store (apart from the flag itself).
    func testSnapshotBuildsTheFixtureBodies() throws {
        let c = try Self.parity("exact.json")
        var s = snapshot()
        s.category = .calmerBadChoice
        s.exactLocations = true
        XCTAssertEqual(String(decoding: ReportEncoder.data(try s.report()), as: UTF8.self), c.reportJSON)
        s.exactLocations = false
        XCTAssertEqual(String(decoding: ReportEncoder.data(try s.report()), as: UTF8.self),
                       c.publicJSON.replacingOccurrences(of: "\"exactLocations\":true", with: "\"exactLocations\":false"))
    }

    // MARK: Coarsening

    func testFlaggedAtIsSentAsTheHourInUTC() {
        XCTAssertEqual(Report.hour(date("2026-10-31T19:59:59Z").addingTimeInterval(0.999)), "2026-10-31T19:00:00Z")
        XCTAssertEqual(Report.hour(date("2026-10-31T19:00:00Z")), "2026-10-31T19:00:00Z")
        XCTAssertEqual(Report.hour(date("2026-11-01T00:30:00Z")), "2026-11-01T00:00:00Z")
    }

    func testCoordinatesKeepFiveDecimals() {
        let e = ReportEndpoint(lat: 47.6295049, lon: -122.3598951, snapped: .init(lat: 47.629804, lon: -122.359306, osmNode: 1))
        XCTAssertEqual(e.lat, 47.6295); XCTAssertEqual(e.lon, -122.3599)
        XCTAssertEqual(e.snapped?.lat, 47.6298); XCTAssertEqual(e.snapped?.lon, -122.35931)
        let l = Report.Location(lat: 47.637123, lon: -122.355876, accuracy: 8, course: 71)
        XCTAssertEqual(l.lat, 47.63712); XCTAssertEqual(l.lon, -122.35588)
    }

    func testOnlyPublicNamedPlacesKeepTheirID() {
        func id(_ id: String, _ category: String, _ kind: Place.Kind = .place) -> String? {
            ReportEndpoint.publicPlaceID(Place(id: id, name: "x", lat: 47.63, lon: -122.35, category: category, kind: kind))
        }
        XCTAssertEqual(id("way/37056567", "park"), "way/37056567")
        XCTAssertEqual(id("relation/1047789", "cafe"), "relation/1047789")
        XCTAssertNil(id("way/1", "address", .address))
        XCTAssertNil(id("node/1", "address"))
        XCTAssertNil(id("pin/47.63000,-122.35000", "dropped pin"))
        XCTAssertNil(id("current-location", "current location"))
        XCTAssertNil(id("current-location", "gps"))     // the reroute origin of OwnRouteProvider
        XCTAssertNil(id("way/", "park"))
        XCTAssertNil(id("way/12345678901234567890", "park"))
    }

    func testExactFieldsDropOutWhenExactLocationsIsOff() throws {
        var s = snapshot()
        s.category = .mapData
        let report = try s.report()
        XCTAssertNil(report.location)
        XCTAssertEqual(report.request.origin, .intersection(.init(lat: 47.6298, lon: -122.35931, osmNode: 53070456)))
        let text = String(decoding: ReportEncoder.data(report), as: UTF8.self)
        XCTAssertTrue(text.contains("\"location\":null"))
        XCTAssertFalse(text.contains("\"exact\"") || text.contains("snapped") || text.contains("47.6295") || text.contains("47.63712") || text.contains("placeID"))
    }

    func testRemovedOrUnsnappedEndpointsAreNull() throws {
        var s = snapshot()
        s.category = .calmerBadChoice
        s.exactLocations = true
        s.originRemoved = true
        s.request.destination?.snapped = nil
        let report = try s.report()
        XCTAssertNil(report.request.origin)
        XCTAssertNil(report.request.destination)
        XCTAssertNotNil(report.location)
        s.exactLocations = false
        XCTAssertNil(try s.report().request.destination)
    }

    func testNoteAndCategoryRules() throws {
        var s = snapshot()
        XCTAssertThrowsError(try s.report()) { XCTAssertEqual($0 as? ReportSnapshot.BuildError, .noCategory) }
        s.category = .other
        s.note = ""
        XCTAssertNil(try s.report().note)
        s.note = String(repeating: "é", count: 280)
        XCTAssertEqual(try s.report().note?.count, 280)
        s.note = String(repeating: "é", count: 281)
        XCTAssertThrowsError(try s.report()) { XCTAssertEqual($0 as? ReportSnapshot.BuildError, .noteTooLong) }
    }

    func testSpokenKeepsTheLastThreeAndHidesTheDestination() {
        let flag = date("2026-10-31T19:42:00Z")
        let said: [(text: String, at: Date)] = [
            ("Head north on Dexter Avenue North", flag.addingTimeInterval(-300)),
            ("In a quarter mile, turn left onto Fremont Avenue North", flag.addingTimeInterval(-90)),
            ("Arrive at Fremont Avenue Market", flag.addingTimeInterval(-41.4)),
            ("You've arrived at Fremont Ave Market", flag.addingTimeInterval(-5.6)),
        ]
        let spoken = ReportSnapshot.spoken(said, flaggedAt: flag, destinationName: "Fremont Ave Market")
        XCTAssertEqual(spoken, [
            .init(text: "In a quarter mile, turn left onto Fremont Avenue North", secondsBefore: 90),
            .init(text: "Arrive at your destination", secondsBefore: 41),
            .init(text: "You've arrived at your destination", secondsBefore: 6),
        ])
    }

    func testCellMatchesTheWorkerGrid() {
        XCTAssertEqual(ReportCell.of(lat: 47.63712, lon: -122.35588), "r29c11")
        XCTAssertEqual(ReportCell.of(lat: 47.6298, lon: -122.35931), "r27c10")
        XCTAssertEqual(ReportCell.of(lat: 47.49, lon: -122.44), "r0c0")
        XCTAssertEqual(ReportCell.of(lat: 47.74, lon: -122.24), "r49c26")
        XCTAssertEqual(ReportCell.of(lat: 47.40, lon: -122.50), "r0c0")
        XCTAssertEqual(ReportCell.of(lat: 47.80, lon: -122.20), "r49c26")
    }

    // MARK: Encoder

    func testNumbersAreWrittenAsJavaScriptWritesThem() {
        let cases: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (402, "402"), (5230.4, "5230.4"), (-122.35931, "-122.35931"), (0.1, "0.1"),
            (0.000001, "0.000001"), (1.5e-7, "1.5e-7"), (1.23e-18, "1.23e-18"), (1e20, "100000000000000000000"),
            (1e21, "1e+21"), (9007199254740992, "9007199254740992"), (1.7976931348623157e308, "1.7976931348623157e+308"),
        ]
        for (v, text) in cases { XCTAssertEqual(ReportEncoder.number(v), text, "\(v)") }
    }

    func testPrettyPrintsLikeStringifyWithTwoSpaces() {
        let v = ReportJSON.object([("a", .array([])), ("b", .object([("c", .int(1)), ("d", .array([.null, .string("/")]))]))])
        XCTAssertEqual(ReportEncoder.pretty(v), "{\n  \"a\": [],\n  \"b\": {\n    \"c\": 1,\n    \"d\": [\n      null,\n      \"/\"\n    ]\n  }\n}")
        XCTAssertEqual(ReportEncoder.string(v), "{\"a\":[],\"b\":{\"c\":1,\"d\":[null,\"/\"]}}")
    }

    // MARK: Storage

    func testAFlagWithinFiveSecondsUpdatesTheFirst() {
        var store = ReportStore()
        let first = snapshot(at: 0)
        XCTAssertEqual(store.add(first), .added)
        var second = snapshot(at: 4.9)
        second.position.stepIndex = 4
        XCTAssertEqual(store.add(second), .updated)
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.snapshots[0].id, first.id)
        XCTAssertEqual(store.snapshots[0].position.stepIndex, 4)
        XCTAssertEqual(store.add(snapshot(at: 9.9)), .added)
        XCTAssertEqual(store.snapshots.count, 2)
    }

    func testTheLimitDropsTheOldestSentThenTheOldestUnsent() throws {
        var store = ReportStore()
        for n in 0..<50 { XCTAssertEqual(store.add(snapshot(at: Double(n) * 10)), .added) }
        let sending = store.snapshots[0].id, sentLater = store.snapshots[5].id, sentFirst = store.snapshots[3].id
        _ = try store.beginSend(id: sending, category: .other, note: nil, exactLocations: false)
        for id in [sentFirst, sentLater] {
            _ = try store.beginSend(id: id, category: .other, note: nil, exactLocations: false)
            store.sent(id: id, receipt: receipt(id), installID: "id-1", at: Date())
        }
        store.withdraw(id: sentLater)

        XCTAssertEqual(store.add(snapshot(at: 1000)), .added)
        XCTAssertEqual(store.snapshots.count, 50)
        XCTAssertNil(store[sentFirst])
        XCTAssertEqual(store.add(snapshot(at: 1010)), .added)
        XCTAssertNil(store[sentLater])

        let oldestFlagged = store.snapshots.first { $0.status == .flagged }!.id
        XCTAssertEqual(store.add(snapshot(at: 1020)), .addedRemovingUnsent)
        XCTAssertEqual(store.snapshots.count, 50)
        XCTAssertNil(store[oldestFlagged])
        XCTAssertNotNil(store[sending], "a send in flight is never dropped")
    }

    func testSendLifecycle() throws {
        var store = ReportStore()
        let s = snapshot()
        _ = store.add(s)
        let report = try store.beginSend(id: s.id, category: .wrongInstruction, note: "Said left", exactLocations: false)
        XCTAssertEqual(report.id, s.id)
        XCTAssertEqual(store[s.id]?.status, .sending)
        XCTAssertThrowsError(try store.beginSend(id: s.id, category: .wrongInstruction, note: nil, exactLocations: false))

        store.sendFailed(id: s.id, error: ReportsError.noConnection.summary)
        XCTAssertEqual(store[s.id]?.status, .flagged)
        XCTAssertEqual(store[s.id]?.lastError, "no_connection")
        XCTAssertEqual(store[s.id]?.note, "Said left")
        XCTAssertEqual(try store.beginSend(id: s.id, category: .wrongInstruction, note: "Said left", exactLocations: false).id, s.id,
                       "an unchanged retry keeps its idempotency key")
        store.sendFailed(id: s.id, error: "no_connection")

        let edited = try store.beginSend(id: s.id, category: .wrongInstruction, note: "Said left twice", exactLocations: false)
        XCTAssertNotEqual(edited.id, s.id, "an edit after a send attempt is a new report")
        XCTAssertEqual(store.snapshots.count, 1)

        store.sent(id: edited.id, receipt: receipt(edited.id), installID: "id-1", at: date("2026-10-31T21:05:00Z"))
        XCTAssertEqual(store[edited.id]?.status, .sent)
        XCTAssertEqual(store[edited.id]?.expiresAt, "2027-01-29T21:00:00Z")
        XCTAssertEqual(store.sentCount(installID: "id-1"), 1)
        XCTAssertEqual(store[edited.id]?.sentInstallID, "id-1")
        XCTAssertEqual(store.unsentCount, 0)

        store.apply([ReportReceipt(id: edited.id, receivedAt: "2026-10-31T21:00:00Z", expiresAt: "2027-02-01T00:00:00Z"),
                     ReportReceipt(id: "someone-else", receivedAt: "2026-10-31T21:00:00Z", expiresAt: "2027-03-01T00:00:00Z")])
        XCTAssertEqual(store[edited.id]?.expiresAt, "2027-02-01T00:00:00Z")

        XCTAssertEqual(store.withdrawAllSent(installID: "id-1"), 1)
        XCTAssertEqual(store[edited.id]?.status, .withdrawn)
        XCTAssertEqual(store.sentCount(installID: "id-1"), 0)
    }

    func testADamagedKeyThenAResetDoesNotWithdrawTheOldCopy() async throws {
        let creds = MemoryCredentials(.init(installID: "id-1", token: "pm_1"))
        var store = ReportStore()
        let old = snapshot(), new = snapshot(at: 60)
        _ = store.add(old); _ = store.add(new)
        _ = try store.beginSend(id: old.id, category: .other, note: nil, exactLocations: false)
        store.sent(id: old.id, receipt: receipt(old.id), installID: "id-1", at: Date())

        let lost = try await client(FakeServer([Self.unauthorized])).deleteMyReports(credentials: creds)
        XCTAssertEqual(lost, .notRecognized)
        XCTAssertEqual(creds.load()?.installID, "id-1")

        let fake = FakeServer([Self.unauthorized, .init(status: 201, body: #"{"installID":"id-2","token":"pm_2"}"#), .init(status: 201, body: Self.receiptJSON)])
        let report = try store.beginSend(id: new.id, category: .other, note: nil, exactLocations: false)
        let got = try await client(fake).send(report, credentials: creds)
        store.sent(id: new.id, receipt: got, installID: creds.load()!.installID, at: Date())
        XCTAssertEqual(store.sentCount(installID: "id-2"), 1, "the confirmation counts only the new ID")
        XCTAssertEqual(store.sentUnderEarlierID(than: "id-2"), 1)

        let deleted = try await client(FakeServer([.init(status: 204)])).deleteMyReports(credentials: creds)
        XCTAssertEqual(deleted, .deleted)
        XCTAssertEqual(store.withdrawAllSent(installID: "id-2"), 1)
        XCTAssertEqual(store[old.id]?.status, .sent, "still on the server under id-1 for up to 90 days")
        XCTAssertEqual(store[new.id]?.status, .withdrawn)
        XCTAssertEqual(store.sentCount(installID: "id-2"), 0)
        XCTAssertEqual(store.sentUnderEarlierID(than: "id-2"), 1)
    }

    func testACopyStoredBeforeTheIDWasRecordedIsNeverUnderTheCurrentID() throws {
        var store = ReportStore()
        let s = snapshot()
        _ = store.add(s)
        _ = try store.beginSend(id: s.id, category: .other, note: nil, exactLocations: false)
        store.sent(id: s.id, receipt: receipt(s.id), installID: "id-1", at: Date())
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as! [[String: Any]]
        json[0].removeValue(forKey: "sentInstallID")
        var loaded = try JSONDecoder().decode(ReportStore.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded[s.id]?.status, .sent)
        XCTAssertNil(loaded[s.id]?.sentInstallID)
        XCTAssertEqual(loaded.sentCount(installID: "id-1"), 0)
        XCTAssertEqual(loaded.withdrawAllSent(installID: "id-1"), 0)
        XCTAssertEqual(loaded[s.id]?.status, .sent)
    }

    func testSavesAnArrayAndAnInterruptedSendLoadsAsFailed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("reports/snapshots.json")
        var store = ReportStore()
        let s = snapshot()
        _ = store.add(s)
        _ = store.add(snapshot(at: 60))
        _ = try store.beginSend(id: s.id, category: .other, note: nil, exactLocations: true)
        try store.save(to: url)

        XCTAssertTrue(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) is [Any])
        let loaded = ReportStore.load(from: url)
        XCTAssertEqual(loaded.snapshots.count, 2)
        XCTAssertEqual(loaded[s.id]?.status, .flagged)
        XCTAssertEqual(loaded[s.id]?.lastError, "interrupted")
        XCTAssertEqual(loaded[s.id]?.request.origin, s.request.origin, "exact fields stay on the phone")
        XCTAssertEqual(ReportStore.load(from: dir.appendingPathComponent("missing.json")).snapshots, [])
        #if canImport(Darwin)
        XCTAssertEqual(try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        #endif
    }

    // MARK: Client

    func testFirstSendMintsThenSends() async throws {
        let fake = FakeServer([
            .init(status: 201, body: #"{"installID":"8C2F0000-0000-4000-8000-000000000000","token":"pm_new"}"#),
            .init(status: 201, body: Self.receiptJSON),
        ])
        let creds = MemoryCredentials()
        let report = try reportToSend()
        let got = try await client(fake).send(report, credentials: creds)
        XCTAssertEqual(got.expiresAt, "2027-01-29T21:00:00Z")
        XCTAssertEqual(fake.requests.map(\.line), ["POST /v1/installs", "POST /v1/reports"])
        XCTAssertEqual(fake.requests[0].body, #"{"schema":1,"app":{"version":"0.1.0","build":"1"}}"#)
        XCTAssertNil(fake.requests[0].auth)
        XCTAssertEqual(fake.requests[1].auth, "Bearer pm_new")
        XCTAssertEqual(fake.requests[1].body, String(decoding: ReportEncoder.data(report), as: UTF8.self))
        XCTAssertEqual(creds.load()?.token, "pm_new")
    }

    func testA401OnSendResetsMintsAndRetriesOnce() async throws {
        let fake = FakeServer([
            .init(status: 401, body: #"{"error":"unauthorized","message":"This report ID does not exist on the server."}"#),
            .init(status: 201, body: #"{"installID":"id-2","token":"pm_2"}"#),
            .init(status: 401, body: #"{"error":"unauthorized","message":"again"}"#),
        ])
        let creds = MemoryCredentials(.init(installID: "id-1", token: "pm_1"))
        let resets = Counter()
        do {
            _ = try await client(fake).send(try reportToSend(), credentials: creds) { resets.bump() }
            XCTFail("expected a 401")
        } catch let e as ReportsError {
            XCTAssertEqual(e.serverCode, .unauthorized)
        }
        XCTAssertEqual(resets.value, 1)
        XCTAssertEqual(fake.requests.map(\.line), ["POST /v1/reports", "POST /v1/installs", "POST /v1/reports"])
        XCTAssertEqual(fake.requests.map(\.auth), ["Bearer pm_1", nil, "Bearer pm_2"])
        XCTAssertEqual(creds.load()?.installID, "id-2")
    }

    private static let unauthorized = ReportsHTTPResponse(status: 401, body: #"{"error":"unauthorized","message":"This report ID does not exist on the server."}"#)
    private static var credentials: MemoryCredentials { MemoryCredentials(.init(installID: "id-1", token: "pm_1")) }

    func testA401OnCheckStatusKeepsTheIDAndNeverMints() async throws {
        let fake = FakeServer([Self.unauthorized])
        let creds = Self.credentials
        do { _ = try await client(fake).checkStatus(credentials: creds); XCTFail("expected a 401") } catch { XCTAssertEqual((error as? ReportsError)?.serverCode, .unauthorized) }
        XCTAssertEqual(creds.load()?.token, "pm_1")
        XCTAssertEqual(fake.requests.map(\.line), ["GET /v1/reports"])
    }

    func testCheckStatusReadsTheList() async throws {
        let fake = FakeServer([.init(status: 200, body: #"{"reports":[{"id":"A","receivedAt":"2026-10-31T21:00:00Z","expiresAt":"2027-01-29T21:00:00Z","category":"map_data"}]}"#)])
        let list = try await client(fake).checkStatus(credentials: Self.credentials)
        XCTAssertEqual(list, [.init(id: "A", receivedAt: "2026-10-31T21:00:00Z", expiresAt: "2027-01-29T21:00:00Z", category: .mapData)])
    }

    func testDeleteMyReportsDeletes() async throws {
        let creds = Self.credentials
        let result = try await client(FakeServer([.init(status: 204)])).deleteMyReports(credentials: creds)
        XCTAssertEqual(result, .deleted)
        XCTAssertNil(creds.load())
    }

    func testALostDeleteDoesNotClaimItWorked() async throws {
        let creds = Self.credentials
        do {
            _ = try await client(FakeServer([], error: URLError(.networkConnectionLost))).deleteMyReports(credentials: creds)
            XCTFail("expected no connection")
        } catch { XCTAssertEqual(error as? ReportsError, .noConnection) }
        let retry = try await client(FakeServer([Self.unauthorized])).deleteMyReports(credentials: creds)
        XCTAssertEqual(retry, .notRecognized)
        XCTAssertEqual(creds.load()?.token, "pm_1")
    }

    func testAfterNotRecognizedTheNextSendGetsANewID() async throws {
        let creds = Self.credentials
        let result = try await client(FakeServer([Self.unauthorized])).deleteMyReports(credentials: creds)
        XCTAssertEqual(result, .notRecognized)
        let fake = FakeServer([Self.unauthorized, .init(status: 201, body: #"{"installID":"id-2","token":"pm_2"}"#), .init(status: 201, body: Self.receiptJSON)])
        _ = try await client(fake).send(try reportToSend(), credentials: creds)
        XCTAssertEqual(creds.load()?.installID, "id-2")
    }

    func testDeleteMyReportsKeepsTheIDOnA401ThatIsNotTheWorkers() async throws {
        let fake = FakeServer([.init(status: 401, body: "<html>Sign in to this network</html>")])
        let creds = Self.credentials
        do { _ = try await client(fake).deleteMyReports(credentials: creds); XCTFail("expected a failure") } catch {
            guard case ReportsError.unexpected = error else { return XCTFail("\(error)") }
        }
        XCTAssertNotNil(creds.load())
    }

    func testDeleteMyReportsKeepsTheIDWhenTheServerIsFull() async throws {
        let fake = FakeServer([
            .init(status: 503, body: #"{"error":"storage_unavailable","message":"The report server is full for today."}"#),
            .init(status: 204),
        ])
        let creds = Self.credentials
        do {
            _ = try await client(fake).deleteMyReports(credentials: creds)
            XCTFail("expected 503")
        } catch let ReportsError.server(e) {
            XCTAssertEqual(e.status, 503)
            XCTAssertEqual(e.code, .storageUnavailable)
        }
        XCTAssertNotNil(creds.load(), "the reports can still be deleted later")
        let result = try await client(fake).deleteMyReports(credentials: creds)
        XCTAssertEqual(result, .deleted)
        XCTAssertNil(creds.load())
        XCTAssertEqual(fake.requests.map(\.line), ["DELETE /v1/installs/me", "DELETE /v1/installs/me"])
    }

    func testErrorMapping() async throws {
        let cases: [(ReportsHTTPResponse, ReportsError, String)] = [
            (.init(status: 400, body: Data(#"{"error":"invalid_report","message":"Invalid value.","field":"note"}"#.utf8)),
             .server(.init(status: 400, code: .invalidReport, message: "Invalid value.", field: "note")), "invalid_report: note"),
            (.init(status: 429, body: Data(#"{"error":"rate_limited","message":"Too many reports today."}"#.utf8), retryAfter: "3600"),
             .server(.init(status: 429, code: .rateLimited, message: "Too many reports today.", retryAfter: 3600)), "rate_limited"),
            (.init(status: 503, body: Data(#"{"error":"storage_unavailable","message":"Full."}"#.utf8), retryAfter: "7200"),
             .server(.init(status: 503, code: .storageUnavailable, message: "Full.", retryAfter: 7200)), "storage_unavailable"),
            (.init(status: 409, body: Data(#"{"error":"conflict","message":"Report X was already sent with different content."}"#.utf8)),
             .server(.init(status: 409, code: .conflict, message: "Report X was already sent with different content.")), "conflict"),
            (.init(status: 413, body: Data(#"{"error":"too_large","message":"The body is over 64 KB."}"#.utf8)),
             .server(.init(status: 413, code: .tooLarge, message: "The body is over 64 KB.")), "too_large"),
            (.init(status: 502, body: Data("<html>Bad gateway</html>".utf8)), .unexpected(status: 502), "http_502"),
            (.init(status: 200, body: Data("{}".utf8)), .unexpected(status: 200), "http_200"),
        ]
        for (response, expected, summary) in cases {
            let fake = FakeServer([response])
            do {
                _ = try await client(fake).send(try reportToSend(), token: "pm_1")
                XCTFail("expected \(expected)")
            } catch let e as ReportsError {
                XCTAssertEqual(e, expected)
                XCTAssertEqual(e.summary, summary)
            }
        }
    }

    func testTransportErrors() async throws {
        let offline = FakeServer([], error: URLError(.notConnectedToInternet))
        await assertError(.noConnection) { _ = try await self.client(offline).reports(token: "pm_1") }
        let tls = FakeServer([], error: URLError(.secureConnectionFailed))
        await assertError(.transport(URLError.Code.secureConnectionFailed.rawValue)) { _ = try await self.client(tls).reports(token: "pm_1") }
        XCTAssertEqual(ReportsError.noConnection.summary, "no_connection")
    }

    func testBaseURLIsConfigurable() async throws {
        let fake = FakeServer([.init(status: 204), .init(status: 204)])
        try await ReportsClient(baseURL: URL(string: "https://reports.example.test/api")!, transport: fake.transport).deleteReport(id: "A", token: "pm_1")
        try await ReportsClient(baseURL: URL(string: "http://127.0.0.1:8787")!, transport: fake.transport).deleteInstall(token: "pm_1")
        XCTAssertEqual(fake.requests.map(\.url), ["https://reports.example.test/api/v1/reports/A", "http://127.0.0.1:8787/v1/installs/me"])
    }

    // MARK: Helpers

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// The moment of `exact.json`: exact endpoints, their snaps and the GPS fix, as the phone keeps them.
    private func snapshot(at offset: TimeInterval = 0) -> ReportSnapshot {
        let origin = Place(id: "way/37056567", name: "Kerry Park", lat: 47.629501, lon: -122.359899, category: "park")
        let destination = Place(id: "node/99", name: "123 Main St", lat: 47.645334, lon: -122.335118, category: "address", kind: .address)
        return ReportSnapshot(
            id: offset == 0 ? "0B7A4C2E-9D1F-4E3A-8B6C-5D4E3F2A1B0C" : UUID().uuidString,
            flaggedAt: date("2026-10-31T19:42:13Z").addingTimeInterval(offset),
            request: .init(mode: .drive, extraMinutes: 5,
                           origin: ReportEndpoint(place: origin, snapped: .init(lat: 47.6298, lon: -122.35931, osmNode: 53070456)),
                           destination: ReportEndpoint(place: destination, snapped: .init(lat: 47.64521, lon: -122.33498, osmNode: 53077201)),
                           rerouted: false),
            chosen: .calmer,
            route: .init(dataVersion: "a1b2c3d4e5f6", edgeIDs: [41822, 41823, 9120, 9121, 9122, 30018, 30019, 30020],
                         wayIDs: [6392710, 6392711, 428156930, 6410023],
                         hash: "cf1a9c409d0a8ca747e439107aaa6193dec61dcaf5335b234234cc71fa53dec8", meters: 5230.4, seconds: 744.2, stress: 318.5,
                         alternativeHash: "99963c16902f033f95e42ab58ca1e33ce9de06c663657007faf4d6b8a7f6b05d"),
            position: .init(stepIndex: 3, shownStepIndex: 4, distanceToManeuver: 86.5, remainingMeters: 2890.1, remainingSeconds: 402, cell: "r29c11"),
            location: .init(lat: 47.63712, lon: -122.35588, accuracy: 8, course: 71),
            spoken: [.init(text: "In a quarter mile, turn left onto Dexter Avenue North", secondsBefore: 41),
                     .init(text: "Turn left onto Dexter Avenue North", secondsBefore: 6)],
            nav: .init(state: .guiding, rerouteCount: 0, muted: false, voiceQuality: .enhanced, units: .mi),
            app: .init(version: "0.1.0", build: "1"), device: .init(model: "iPhone16,2", os: "iOS 27.1"))
    }

    private func reportToSend() throws -> Report {
        var s = snapshot()
        s.category = .wrongInstruction
        return try s.report()
    }

    static let receiptJSON = #"{"id":"0B7A4C2E-9D1F-4E3A-8B6C-5D4E3F2A1B0C","receivedAt":"2026-10-31T21:00:00Z","expiresAt":"2027-01-29T21:00:00Z"}"#

    private func receipt(_ id: String) -> ReportReceipt {
        ReportReceipt(id: id, receivedAt: "2026-10-31T21:00:00Z", expiresAt: "2027-01-29T21:00:00Z")
    }

    private func client(_ fake: FakeServer) -> ReportsClient { ReportsClient(baseURL: URL(string: "http://127.0.0.1:8787")!, transport: fake.transport) }

    private func assertError(_ expected: ReportsError, _ work: () async throws -> Void, line: UInt = #line) async {
        do { try await work(); XCTFail("expected \(expected)", line: line) } catch { XCTAssertEqual(error as? ReportsError, expected, line: line) }
    }
}

extension ReportsHTTPResponse {
    init(status: Int, body: String) { self.init(status: status, body: Data(body.utf8)) }
}

/// Answers requests in order and records them.
private final class FakeServer: @unchecked Sendable {
    struct Seen { var line: String; var url: String; var auth: String?; var body: String? }
    private let lock = NSLock()
    private var responses: [ReportsHTTPResponse]
    private let error: URLError?
    private var seen: [Seen] = []

    init(_ responses: [ReportsHTTPResponse], error: URLError? = nil) { self.responses = responses; self.error = error }

    var requests: [Seen] { lock.locked { seen } }

    var transport: ReportsClient.Transport {
        { [self] request in
            try lock.locked {
                seen.append(Seen(line: "\(request.httpMethod ?? "") \(request.url!.path)", url: request.url!.absoluteString,
                                 auth: request.value(forHTTPHeaderField: "Authorization"),
                                 body: request.httpBody.map { String(decoding: $0, as: UTF8.self) }))
                if let error { throw error }
                return responses.removeFirst()
            }
        }
    }
}

private final class MemoryCredentials: ReportCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: ReportCredentials?
    init(_ saved: ReportCredentials? = nil) { self.saved = saved }
    func load() -> ReportCredentials? { lock.locked { saved } }
    func save(_ credentials: ReportCredentials) throws { lock.locked { saved = credentials } }
    func wipe() { lock.locked { saved = nil } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.locked { n } }
    func bump() { lock.locked { n += 1 } }
}

private extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
