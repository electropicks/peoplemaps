import XCTest
@testable import PeoplemapsCore

final class UsageLogTests: XCTestCase {
    private var dir: URL!
    private var log: UsageLog!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        log = UsageLog(url: dir.appendingPathComponent("usage.jsonl"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func trip(_ n: Int = 0, departures: [UsageLog.Point] = []) -> UsageLog.Trip {
        UsageLog.Trip(at: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)), mode: .drive, extraMinutes: 5, started: .calmer,
                      fastest: .init(minutes: 12, meters: 4_000), calmer: .init(minutes: 15, meters: 4_600), calmerOffered: true,
                      reroutes: departures.count, departures: departures, ended: .arrived)
    }

    func testOffWritesNothing() throws {
        try log.append(trip(), enabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url.path))
        XCTAssertEqual(log.count, 0)
    }

    func testAppendWritesOneJSONLinePerTrip() throws {
        try log.append(trip(1), enabled: true)
        try log.append(trip(2, departures: [.init(lat: 47.6, lon: -122.3)]), enabled: true)
        let text = String(decoding: log.data(), as: UTF8.self)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("\"ended\":\"arrived\""))
        XCTAssertTrue(text.contains("\"started\":\"calmer\""))
        XCTAssertEqual(log.trips(), [trip(1), trip(2, departures: [.init(lat: 47.6, lon: -122.3)])])
    }

    func testKeepsTheLast500() throws {
        for n in 0..<(UsageLog.limit + 3) { try log.append(trip(n), enabled: true) }
        let trips = log.trips()
        XCTAssertEqual(trips.count, UsageLog.limit)
        XCTAssertEqual(trips.first, trip(3))
        XCTAssertEqual(trips.last, trip(UsageLog.limit + 2))
    }

    func testRoundsToAbout100MetresUnlessExact() {
        let lat = 47.62951, lon = -122.35987
        let r = UsageLog.point(lat: lat, lon: lon, exact: false)
        XCTAssertNotEqual(r.lat, lat)
        XCTAssertLessThan(Coordinate(lat: lat, lon: lon).distance(to: Coordinate(lat: r.lat, lon: r.lon)), 100)
        // Nearby points share a cell, so the log cannot tell them apart.
        XCTAssertEqual(UsageLog.rounded(lat: lat + 0.0001, lon: lon + 0.0001), r)
        XCTAssertEqual(UsageLog.point(lat: lat, lon: lon, exact: true), .init(lat: lat, lon: lon))
    }

    func testClearRemovesTheFile() throws {
        try log.append(trip(), enabled: true)
        log.clear()
        XCTAssertEqual(log.count, 0)
        XCTAssertTrue(log.data().isEmpty)
    }
}
