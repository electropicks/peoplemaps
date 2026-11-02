import XCTest
@testable import PeoplemapsCore

final class AppEventsTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_793_500_000)
    }

    private func buffer(capacity: Int = 200, window: TimeInterval = 600, clock: Clock = Clock()) -> (AppEvents, Clock) {
        (AppEvents(capacity: capacity, window: window, clock: { clock.now }), clock)
    }

    func testKeepsOnlyTheLastTwoHundredEventsOldestFirst() {
        let (events, clock) = buffer()
        for n in 0..<250 { clock.now += 0.1; events.log(.map, "camera move", ["count": Double(n)]) }
        let kept = events.snapshot()
        XCTAssertEqual(kept.count, 200)
        XCTAssertEqual(kept.first?.fields["count"], 50)
        XCTAssertEqual(kept.last?.fields["count"], 249)
        XCTAssertEqual(kept.map(\.at), kept.map(\.at).sorted())
    }

    func testDropsEventsOlderThanTenMinutes() {
        let (events, clock) = buffer()
        events.log(.route, "route compare started")
        clock.now += 301
        events.log(.route, "route compare finished")
        clock.now += 301
        XCTAssertEqual(events.snapshot().map(\.message), ["route compare finished"])
        clock.now += 600
        XCTAssertTrue(events.snapshot().isEmpty)
    }

    func testTheShorterLimitWins() {
        let (events, clock) = buffer(capacity: 3, window: 600)
        for _ in 0..<5 { clock.now += 1; events.log(.data, "app launched") }
        XCTAssertEqual(events.snapshot().count, 3)
        let (short, shortClock) = buffer(capacity: 200, window: 10)
        for _ in 0..<5 { shortClock.now += 4; short.log(.data, "app launched") }
        XCTAssertEqual(short.snapshot().count, 3, "only the events from the last 10 seconds")
    }

    func testSnapshotIsACopy() {
        let (events, _) = buffer()
        events.log(.map, "map idle")
        let before = events.snapshot()
        events.log(.map, "map idle")
        events.reset()
        XCTAssertEqual(before.count, 1)
        XCTAssertTrue(events.snapshot().isEmpty)
    }

    func testManyThreadsLoseNothingAndStayWithinTheLimit() {
        let (events, _) = buffer(capacity: 5_000)
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for n in 0..<500 { events.log(.search, "search", ["count": Double(t * 500 + n)]); if n % 50 == 0 { _ = events.snapshot() } }
        }
        let kept = events.snapshot()
        XCTAssertEqual(kept.count, 4_000)
        XCTAssertEqual(Set(kept.compactMap { $0.fields["count"] }).count, 4_000)
        let (small, _) = buffer(capacity: 200)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in for _ in 0..<500 { small.log(.map, "camera move") } }
        XCTAssertEqual(small.snapshot().count, 200)
    }

    func testBurstsOfTheSameEventShareOneLineWithACount() {
        let (events, clock) = buffer()
        for _ in 0..<5 { clock.now += 1; events.log(.map, "camera move", coalesce: true, ["ms": 1000]) }
        clock.now += 5
        events.log(.map, "camera move", coalesce: true, ["ms": 500])
        let kept = events.snapshot()
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept[0].fields["count"], 5)
        XCTAssertNil(kept[1].fields["count"])
    }

    // MARK: Privacy

    private struct Fail: Error {}

    func testEventsCarryOnlyNamedNumbersAndTypeNames() {
        let (events, _) = buffer()
        events.log(.map, "camera move", ["lat": 47.62951, "lon": -122.35987, "ms": 480.04, "zoom": 14.26, "animated": 1, "count": .nan])
        events.log(.error, "route compare failed", error: Fail(), ["ms": 12])
        events.log(.route, "route compare started", mode: .walk)
        events.log(.navigation, "guidance started", state: "calmer")
        let kept = events.snapshot()
        XCTAssertEqual(kept[0].fields, ["ms": 480, "zoom": 14.3, "animated": 1], "no coordinates; numbers rounded to one decimal")
        XCTAssertTrue(Set(kept.flatMap { $0.fields.keys }).isSubset(of: AppEvents.fieldNames))
        XCTAssertEqual(kept[2].detail, "walk")
        XCTAssertEqual(kept[3].detail, "calmer")
        let name = try! XCTUnwrap(kept[1].detail)
        XCTAssertTrue(name.hasSuffix("Fail"), name)
        XCTAssertTrue(name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") })
    }

    func testAnErrorsTextIsNotRecorded() throws {
        struct Street: LocalizedError { var errorDescription: String? { "No route near 47.62951, -122.35987 on N 45th St: Gas Works Park" } }
        let (events, _) = buffer()
        events.log(.error, "route compare failed", error: Street())
        let json = String(decoding: try JSONEncoder().encode(events.snapshot()), as: UTF8.self)
        for secret in ["47.6", "122.3", "45th", "Gas Works", "No route"] { XCTAssertFalse(json.contains(secret), secret) }
    }

    func testReportFileHoldsEventsButNothingTypedOrLocated() throws {
        let (events, _) = buffer()
        events.log(.search, "search", ["ms": 3.2, "results": 7])
        events.log(.route, "route compare finished", mode: .bike, ["ms": 88, "candidates": 4])
        let report = ProblemReport(id: "r1", createdAt: Date(timeIntervalSince1970: 1_793_500_000), note: "Gas Works Park was wrong", screen: "home",
                                   mode: .bike, extraMinutes: 5, app: .init(version: "0.1.0", build: "1"), dataVersion: "osm-2026-10-29",
                                   device: .init(model: "iPhone", os: "iOS 27.0"), events: events.snapshot())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: try report.fileData()) as? [String: Any])
        XCTAssertEqual(root["schema"] as? Int, 3)
        let listed = try XCTUnwrap(root["events"] as? [[String: Any]])
        XCTAssertEqual(listed.count, 2)
        for event in listed {
            XCTAssertTrue(Set(event.keys).isSubset(of: ["at", "category", "message", "detail", "fields"]))
            XCTAssertTrue(Set((event["fields"] as? [String: Double] ?? [:]).keys).isSubset(of: AppEvents.fieldNames))
        }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: listed.map { $0["message"] ?? "" }), as: UTF8.self)
        XCTAssertFalse(text.contains("Gas Works"))
        let values = listed.flatMap { ($0["fields"] as? [String: Double] ?? [:]).values }
        XCTAssertTrue(values.allSatisfy { ($0 * 10).rounded() == $0 * 10 }, "numbers have one decimal at most, so no coordinate")
    }

    // MARK: Reports

    func testReportsSavedBeforeEventsStillDecode() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var store = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(ProblemReports())) as? [String: Any])
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(sampleReport())) as? [String: Any])
        XCTAssertNotNil(old.removeValue(forKey: "events"))
        store["reports"] = [old]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("old-reports-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: store).write(to: url)
        let loaded = ProblemReports.load(from: url)
        XCTAssertEqual(loaded.reports.count, 1)
        XCTAssertEqual(loaded.reports[0].events, [])
        XCTAssertEqual(loaded.reports[0].note, "n")
    }

    func testEventsSurviveSavingAndLoading() throws {
        let (events, clock) = buffer()
        clock.now = Date(timeIntervalSince1970: 1_793_500_000.123)
        events.log(.route, "route compare finished", mode: .drive, ["ms": 41.5, "candidates": 3])
        var report = sampleReport(); report.events = events.snapshot()
        var store = ProblemReports(); store.save(report)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try store.save(to: url)
        let loaded = ProblemReports.load(from: url)
        XCTAssertEqual(loaded.reports.first?.events, report.events)
        XCTAssertEqual(loaded.reports.first?.events.first?.at.timeIntervalSince1970 ?? 0, 1_793_500_000.123, accuracy: 0.001)
    }

    func testAReportFileThatCannotBeReadIsLoggedWithoutItsText() throws {
        AppEvents.shared.reset()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ not json".utf8).write(to: url)
        XCTAssertTrue(ProblemReports.load(from: url).reports.isEmpty)
        XCTAssertEqual(AppEvents.shared.snapshot().filter { $0.category == .error }.map(\.message), ["problem reports file did not decode"])
        AppEvents.shared.reset()
    }

    private func sampleReport() -> ProblemReport {
        ProblemReport(id: "r1", createdAt: Date(timeIntervalSince1970: 1_793_500_000), note: "n", screen: "home", mode: .walk, extraMinutes: 5,
                      app: .init(version: "0.1.0", build: "1"), dataVersion: "osm-2026-10-29", device: .init(model: "iPhone", os: "iOS 27.0"))
    }
}
