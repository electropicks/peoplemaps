import XCTest
@testable import PeoplemapsCore

final class RouteLineTests: XCTestCase {
    /// Three legs heading north then east, each roughly 111 m (0.001 degrees of latitude).
    private let line = [Coordinate(lat: 47.600, lon: -122.300), Coordinate(lat: 47.601, lon: -122.300),
                        Coordinate(lat: 47.602, lon: -122.300), Coordinate(lat: 47.602, lon: -122.299)]
    private var leg: Double { line[0].distance(to: line[1]) }

    func testLengthSumsTheLegs() {
        XCTAssertEqual(RouteLine.length(line), line[0].distance(to: line[1]) + line[1].distance(to: line[2]) + line[2].distance(to: line[3]), accuracy: 0.001)
        XCTAssertEqual(RouteLine.length([]), 0)
        XCTAssertEqual(RouteLine.length([line[0]]), 0)
    }

    func testSplitMidLegSharesTheCutPoint() {
        let (passed, ahead) = RouteLine.split(line, atMeters: leg * 1.5)
        XCTAssertEqual(passed.count, 3)
        XCTAssertEqual(ahead.count, 3)
        XCTAssertEqual(passed.last, ahead.first)
        XCTAssertEqual(passed.last!.lat, 47.6015, accuracy: 0.000_01)
        XCTAssertEqual(passed.first, line.first)
        XCTAssertEqual(ahead.last, line.last)
        XCTAssertEqual(RouteLine.length(passed) + RouteLine.length(ahead), RouteLine.length(line), accuracy: 0.01)
        XCTAssertEqual(RouteLine.length(passed), leg * 1.5, accuracy: 0.05)
    }

    func testSplitOnAVertexDropsNothing() {
        let (passed, ahead) = RouteLine.split(line, atMeters: leg)
        XCTAssertEqual(passed, [line[0], line[1]])
        XCTAssertEqual(ahead, Array(line[1...]))
    }

    func testSplitBeforeTheStartIsAllAhead() {
        for meters in [0.0, -5, .nan] {
            let (passed, ahead) = RouteLine.split(line, atMeters: meters)
            XCTAssertTrue(passed.isEmpty)
            XCTAssertEqual(ahead, line)
        }
    }

    func testSplitPastTheEndIsAllPassed() {
        let (passed, ahead) = RouteLine.split(line, atMeters: RouteLine.length(line) + 50)
        XCTAssertEqual(passed, line)
        XCTAssertTrue(ahead.isEmpty)
        let exact = RouteLine.split(line, atMeters: RouteLine.length(line))
        XCTAssertTrue(exact.ahead.isEmpty)
        XCTAssertEqual(RouteLine.length(exact.passed), RouteLine.length(line), accuracy: 0.01)
    }

    func testDegenerateLinesAreAllAhead() {
        XCTAssertTrue(RouteLine.split([], atMeters: 10).ahead.isEmpty)
        XCTAssertEqual(RouteLine.split([line[0]], atMeters: 10).ahead, [line[0]])
        // Repeated coordinates (zero-length legs) must not divide by zero.
        let repeated = [line[0], line[0], line[1]]
        let (passed, ahead) = RouteLine.split(repeated, atMeters: 10)
        XCTAssertEqual(RouteLine.length(passed), 10, accuracy: 0.05)
        XCTAssertEqual(RouteLine.length(ahead), leg - 10, accuracy: 0.05)
    }

    func testAFreshRouteReplacesTheSplit() {
        // A reroute is a different line with progress back at zero: nothing carries over.
        let other = [Coordinate(lat: 47.61, lon: -122.31), Coordinate(lat: 47.611, lon: -122.31)]
        let (passed, ahead) = RouteLine.split(other, atMeters: 0)
        XCTAssertTrue(passed.isEmpty)
        XCTAssertEqual(ahead, other)
    }
}
