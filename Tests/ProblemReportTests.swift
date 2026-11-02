import XCTest
@testable import PeoplemapsCore

final class ProblemReportTests: XCTestCase {
    private func report(note: String = "", exact: Bool = false) -> ProblemReport {
        ProblemReport(id: "r1", createdAt: Date(timeIntervalSince1970: 1_793_500_000), note: note, includeExact: exact, screen: "preview",
                      mode: .drive, extraMinutes: 5,
                      origin: .init(snapped: .init(lat: 47.62951, lon: -122.35987), exact: .init(lat: 47.62955, lon: -122.35991)),
                      destination: .init(snapped: .init(lat: 47.64571, lon: -122.33454), exact: .init(lat: 47.6458, lon: -122.3346)),
                      routes: [.init(kind: .fastest, minutes: 12, seconds: 700, meters: 4_000, streets: ["Aurora Ave N"], edgeIDs: [1, 2])],
                      moment: .init(at: Date(timeIntervalSince1970: 1_793_500_100), stepIndex: 2, stepCount: 9, instruction: "Turn left onto N 45th St",
                                    remainingMeters: 900, remainingSeconds: 120, cell: "r30c10", location: .init(lat: 47.66, lon: -122.34)),
                      spoken: [.init(text: "Turn left", secondsBefore: 4)], rerouteCount: 1,
                      app: .init(version: "0.1.0", build: "1"), device: .init(model: "iPhone", os: "iOS 27.0"))
    }

    func testExactLocationsAreLeftOutByDefault() throws {
        let text = String(decoding: try report(note: "Wrong turn").fileData(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"exactLocations\" : false"))
        XCTAssertTrue(text.contains("47.62951"))
        XCTAssertFalse(text.contains("47.62955"))
        XCTAssertFalse(text.contains("47.66"))
        XCTAssertTrue(text.contains("r30c10"))
    }

    func testExactLocationsAreSharedWhenOn() throws {
        let text = String(decoding: try report(exact: true).fileData(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"exactLocations\" : true"))
        XCTAssertTrue(text.contains("47.62955"))
        XCTAssertTrue(text.contains("47.66"))
    }

    func testFileHasNoCategoryAndNoServerFields() throws {
        let text = String(decoding: try report().fileData(), as: UTF8.self)
        XCTAssertFalse(text.contains("category"))
        XCTAssertTrue(text.contains("\"schema\" : 2"))
    }

    func testFileNameHasDateAndShortDescription() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(report(note: "Wrong left on 45th! It said turn right, then went blank.").fileName(calendar: utc),
                       "peoplemaps-2026-11-01-wrong-left-on-45th-it-said.json")
        XCTAssertEqual(report().fileName(calendar: utc), "peoplemaps-2026-11-01-marked-moment.json")
        XCTAssertEqual(ProblemReport.slug("!!! é"), "e")
        XCTAssertEqual(ProblemReport.slug("???"), "report")
    }

    func testStoreKeepsNewestFirstReplacesByIDAndTrims() throws {
        var store = ProblemReports()
        for n in 0..<(ProblemReport.limit + 2) { var r = report(); r.id = "r\(n)"; store.save(r) }
        XCTAssertEqual(store.reports.count, ProblemReport.limit)
        XCTAssertEqual(store.reports.first?.id, "r\(ProblemReport.limit + 1)")
        var edited = store.reports[0]; edited.note = "More words"
        store.save(edited)
        XCTAssertEqual(store.reports.count, ProblemReport.limit)
        XCTAssertEqual(store.reports[0].note, "More words")
        store.remove(id: edited.id)
        XCTAssertNil(store[edited.id])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("r.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try store.save(to: url)
        XCTAssertEqual(ProblemReports.load(from: url), store)
    }
}
