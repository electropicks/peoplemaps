import XCTest
@testable import PeoplemapsCore

final class DriveLogTests: XCTestCase {
    private var dir: URL!
    private var log: DriveLog!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("drive-log")
        log = DriveLog(folder: dir)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    private func header(_ start: Date? = nil, routes: [DriveLog.RouteRecord] = []) -> DriveLog.Header {
        DriveLog.Header(start: start ?? t0, mode: .drive, appVersion: "0.1.0", appBuild: "7", dataVersion: "osm-test",
                        request: .init(originName: "Start", originLat: 47.6, originLon: -122.3, destinationName: "End", destinationID: "node/1",
                                       destinationLat: 47.61, destinationLon: -122.31, extraMinutes: 5, preferences: ["unprotectedLefts": "avoid"]),
                        startedWith: "calmer", calmerOffered: true, routes: routes)
    }
    private func lines(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
    private func fix(_ n: Int) -> DriveLog.Fix {
        DriveLog.Fix(t: t0.addingTimeInterval(Double(n)), lat: 47.6295 + Double(n) * 0.0001, lon: -122.3599, accuracy: 4.8, speed: 11.2, speedAccuracy: 0.4,
                     course: 90, courseAccuracy: 5)
    }

    // MARK: Switch

    func testOffCreatesNothing() throws {
        XCTAssertNil(try log.startTrip(header(), enabled: false))
        log.appendUse("search", ["query": .string("x")], enabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "Not even the folder")
        XCTAssertEqual(log.summary(), .init(trips: 0, bytes: 0))
    }

    // MARK: Format

    func testTripIsJSONLinesWrittenAsItGoes() throws {
        let trip = try XCTUnwrap(try log.startTrip(header(), enabled: true))
        trip.fix(fix(0)); trip.fix(fix(1))
        trip.event("maneuver", at: t0.addingTimeInterval(1.5), ["stepIndex": .number(0), "instruction": .string("Turn left onto Pine St")])
        // Nothing is buffered: a crash here still leaves the lines on disk.
        var rows = try lines(trip.url)
        XCTAssertEqual(rows.map { $0["kind"] as? String }, ["header", "fix", "fix", "event"])
        XCTAssertEqual(rows[0]["mode"] as? String, "drive")
        XCTAssertEqual(rows[0]["startedWith"] as? String, "calmer")
        XCTAssertEqual(rows[1]["t"] as? Double, 1_700_000_000)
        XCTAssertEqual(rows[1]["speed"] as? Double, 11.2)
        XCTAssertNil(rows[1]["altitude"], "Absent, not null, when the source gives none")
        XCTAssertEqual((rows[3]["data"] as? [String: Any])?["instruction"] as? String, "Turn left onto Pine St")
        trip.finish(reason: "arrived", at: t0.addingTimeInterval(600))
        rows = try lines(trip.url)
        XCTAssertEqual(rows.last?["name"] as? String, "end")
        XCTAssertEqual((rows.last?["data"] as? [String: Any])?["reason"] as? String, "arrived")
        XCTAssertEqual((rows.last?["data"] as? [String: Any])?["fixes"] as? Double, 2)
        let decoded = try JSONDecoder().decode(DriveLog.Header.self, from: Data(String(contentsOf: trip.url, encoding: .utf8).split(separator: "\n")[0].utf8))
        XCTAssertEqual(decoded, header())
    }

    func testFileNamesSortOldestFirstAndNameTheDay() {
        let a = DriveLog.tripFileName(start: t0, mode: .drive), b = DriveLog.tripFileName(start: t0.addingTimeInterval(1), mode: .walk)
        XCTAssertEqual(a, "trip-20231114T221320Z-drive.jsonl")
        XCTAssertLessThan(a, b)
        let utc = TimeZone(identifier: "UTC")!, seattle = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(DriveLog.useFileName(day: t0, timeZone: utc), "use-2023-11-14.jsonl")
        XCTAssertEqual(DriveLog.useFileName(day: t0.addingTimeInterval(3 * 3600), timeZone: utc), "use-2023-11-15.jsonl")
        XCTAssertEqual(DriveLog.useFileName(day: t0.addingTimeInterval(3 * 3600), timeZone: seattle), "use-2023-11-14.jsonl")
    }

    func testUseEventsGoToOneFilePerDay() throws {
        let utc = TimeZone(identifier: "UTC")!
        log.appendUse("search", ["query": .string("gas works")], at: t0, enabled: true, timeZone: utc)
        log.appendUse("place_card", ["id": .string("relation/1")], at: t0.addingTimeInterval(5), enabled: true, timeZone: utc)
        log.appendUse("search", at: t0.addingTimeInterval(86_400), enabled: true, timeZone: utc)
        let names = log.allFiles().map(\.lastPathComponent)
        XCTAssertEqual(names, ["use-2023-11-14.jsonl", "use-2023-11-15.jsonl"])
        XCTAssertEqual(try lines(log.allFiles()[0]).map { $0["name"] as? String }, ["search", "place_card"])
        XCTAssertEqual(log.summary().trips, 0, "Daily files are not trips")
    }

    // MARK: Length rule

    func testMinimumIsThreeMinutes() { XCTAssertEqual(DriveLog.minimumTripSeconds, 180) }

    func testTripUnderThreeMinutesIsDeletedWhenItEnds() throws {
        let trip = try XCTUnwrap(try log.startTrip(header(), enabled: true))
        trip.fix(fix(0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trip.url.path), "Kept while it runs")
        XCTAssertFalse(trip.finish(reason: "ended_early", at: t0.addingTimeInterval(179.9)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trip.url.path))
        XCTAssertEqual(log.summary().trips, 0)
    }

    func testTripOfThreeMinutesIsKept() throws {
        let trip = try XCTUnwrap(try log.startTrip(header(), enabled: true))
        XCTAssertTrue(trip.finish(reason: "arrived", at: t0.addingTimeInterval(180)))
        XCTAssertEqual(log.summary().trips, 1)
        XCTAssertTrue(trip.finish(reason: "again"), "Finishing twice changes nothing")
        XCTAssertEqual(try lines(trip.url).filter { $0["name"] as? String == "end" }.count, 1)
    }

    // MARK: Cap

    func testCapDropsOldestTripsAndKeepsTheOneBeingWritten() throws {
        var urls: [URL] = []
        for n in 0..<5 {
            let trip = try XCTUnwrap(try log.startTrip(header(t0.addingTimeInterval(Double(n) * 1000)), enabled: true))
            for i in 0..<20 { trip.fix(fix(i)) }
            trip.finish(reason: "arrived", at: t0.addingTimeInterval(Double(n) * 1000 + 600))
            urls.append(trip.url)
        }
        log.appendUse("search", at: t0, enabled: true)
        let size = try XCTUnwrap(try urls[0].resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let before = log.summary()
        XCTAssertEqual(before.trips, 5)
        // Room for about two trips and the small daily file.
        let dropped = log.enforceCap(maxBytes: size * 2 + 400, keeping: urls[4])
        XCTAssertEqual(dropped, 3)
        XCTAssertEqual(log.allFiles().filter { $0.lastPathComponent.hasPrefix("trip-") }.map(\.lastPathComponent),
                       urls.suffix(2).map(\.lastPathComponent), "The newest stay")
        XCTAssertLessThanOrEqual(log.summary().bytes, size * 2 + 400)
        XCTAssertEqual(log.allFiles().filter { $0.lastPathComponent.hasPrefix("use-") }.count, 1, "Daily files are not dropped")
        // A cap below even the newest trip never deletes the one being written.
        log.enforceCap(maxBytes: 1, keeping: urls[4])
        XCTAssertEqual(log.allFiles().filter { $0.lastPathComponent.hasPrefix("trip-") }.map(\.lastPathComponent), [urls[4].lastPathComponent])
    }

    func testDefaultCapIs500MB() { XCTAssertEqual(DriveLog.capBytes, 500 * 1024 * 1024) }

    func testClearRemovesEverything() throws {
        _ = try log.startTrip(header(), enabled: true)
        log.clear()
        XCTAssertEqual(log.summary(), .init(trips: 0, bytes: 0))
    }

    // MARK: Size

    /// A one-hour drive at 1 Hz, fixes and a maneuver event every 30 s.
    func testOneHourAtOneHertzStaysSmall() throws {
        let trip = try XCTUnwrap(try log.startTrip(header(), enabled: true))
        for n in 0..<3600 {
            trip.fix(DriveLog.Fix(t: t0.addingTimeInterval(Double(n)), lat: 47.629512345 + Double(n) * 0.00009, lon: -122.359912345 + Double(n) * 0.00007,
                                  accuracy: 4.8123, speed: 11.234567, speedAccuracy: 0.41, course: 87.4, courseAccuracy: 6, altitude: 55.37))
            if n % 30 == 0 { trip.event("maneuver", at: t0.addingTimeInterval(Double(n)), ["stepIndex": .number(Double(n / 30)), "upcoming": .number(Double(n / 30 + 1))]) }
        }
        trip.finish(reason: "arrived", at: t0.addingTimeInterval(3600))
        let bytes = try XCTUnwrap(try trip.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        print("drive log: one hour at 1 Hz = \(bytes) bytes")
        XCTAssertLessThan(bytes, 1_000_000)
    }

    // MARK: Routes

    private func edge(_ id: Int, _ a: (Double, Double), _ b: (Double, Double), name: String) -> GraphEdge {
        func c(_ x: Double, _ y: Double) -> Coordinate { Coordinate(lat: 47.6 + y / 111_195, lon: -122.3 + x / (111_195 * cos(47.6 * .pi / 180))) }
        return GraphEdge(id: id, from: id, to: id + 1, wayID: Int64(100 + id), coordinates: [c(a.0, a.1), c(b.0, b.1)],
                         meters: hypot(b.0 - a.0, b.1 - a.1), modes: TravelMode.allCases, highway: "residential", name: name)
    }

    func testRouteRecordCarriesEdgesTimesAndManeuvers() throws {
        let edges = [edge(0, (0, 0), (0, 100), name: "Main Street"), edge(1, (0, 100), (-100, 100), name: "Oak Avenue")]
        var metrics = RouteMetrics(); metrics.meters = 200; metrics.seconds = 30
        let route = Route(edgeIDs: [0, 1], edgeMeters: [100, 100], coordinates: edges.flatMap(\.coordinates), metrics: metrics, streetNames: [],
                          junctionFactors: [[], [.unsignalledLeft]], edges: edges)
        let record = DriveLog.RouteRecord(label: "calmer", route: route, plan: route.navigationPlan(mode: .drive), calm: CalmScore(value: 71))
        XCTAssertEqual(record.edgeIDs, [0, 1])
        XCTAssertEqual(record.wayIDs, [100, 101])
        XCTAssertEqual(record.edgeNames, ["Main Street", "Oak Avenue"])
        XCTAssertEqual(record.edgeSeconds.count, 2)
        XCTAssertEqual(record.edgeStart, [0, 2])
        XCTAssertEqual(record.coordinates.count, 4)
        XCTAssertEqual(record.calmScore, 71)
        XCTAssertEqual(record.calmLevel, "Chill")
        XCTAssertEqual(record.maneuvers.map(\.kind), ["depart", "left", "arrive"])
        XCTAssertEqual(record.maneuvers[1].street, "Oak Ave")
        XCTAssertNotNil(record.maneuvers[1].lat)
        XCTAssertEqual(try XCTUnwrap(record.junctionSeconds), 30 - record.edgeSeconds.reduce(0, +), accuracy: 0.11)
        // And it survives a round trip through the file.
        let data = try! DriveLog.encoder.encode(record)
        XCTAssertEqual(try! JSONDecoder().decode(DriveLog.RouteRecord.self, from: data), record)
    }

    func testRequestRecordKeepsOnlyChangedPreferences() {
        let a = Place(id: "a", name: "A", lat: 47.6, lon: -122.3, category: "gps"), b = Place(id: "node/9", name: "B", lat: 47.61, lon: -122.31, category: "park")
        let request = RouteRequest(origin: a, destination: b, mode: .drive, extraMinutes: 8,
                                   preferences: RoutePreferences([.unprotectedLefts: .avoid, .hills: .normal]))
        let record = DriveLog.RequestRecord(request)
        XCTAssertEqual(record.preferences, ["unprotectedLefts": "avoid"])
        XCTAssertEqual(record.extraMinutes, 8)
        XCTAssertEqual(record.destinationID, "node/9")
    }
}
