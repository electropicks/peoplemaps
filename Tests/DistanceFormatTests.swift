import XCTest
@testable import PeoplemapsCore

final class DistanceFormatTests: XCTestCase {
    private func feet(_ f: Double) -> Double { f / DistanceFormat.feetPerMeter }
    private func miles(_ m: Double) -> Double { m * DistanceFormat.metersPerMile }

    func testShortDistancesAreFeet() {
        XCTAssertEqual(DistanceFormat.distance(0), "10 ft")
        XCTAssertEqual(DistanceFormat.distance(-5), "10 ft")
        XCTAssertEqual(DistanceFormat.distance(feet(94)), "90 ft")
        XCTAssertEqual(DistanceFormat.distance(feet(100)), "100 ft")
        XCTAssertEqual(DistanceFormat.distance(feet(312)), "300 ft")
        XCTAssertEqual(DistanceFormat.distance(feet(500), spoken: true), "500 feet")
    }

    func testFeetRunIntoMilesWithoutGoingBackwards() {
        XCTAssertEqual(DistanceFormat.distance(feet(527)), "550 ft")
        XCTAssertEqual(DistanceFormat.distance(feet(528)), "550 ft")
        XCTAssertEqual(DistanceFormat.distance(feet(800)), "800 ft")
        XCTAssertEqual(DistanceFormat.distance(miles(0.19)), "1000 ft")
        XCTAssertEqual(DistanceFormat.distance(miles(0.2)), "0.2 mi")
    }

    func testMiles() {
        XCTAssertEqual(DistanceFormat.distance(miles(0.4)), "0.4 mi")
        XCTAssertEqual(DistanceFormat.distance(miles(9.94)), "9.9 mi")
        XCTAssertEqual(DistanceFormat.distance(miles(12.4)), "12 mi")
        XCTAssertEqual(DistanceFormat.distance(miles(2)), "2.0 mi")
    }

    func testSpokenReadsNaturally() {
        XCTAssertEqual(DistanceFormat.distance(miles(1), spoken: true), "1 mile")
        XCTAssertEqual(DistanceFormat.distance(miles(2), spoken: true), "2 miles")
        XCTAssertEqual(DistanceFormat.distance(miles(1.5), spoken: true), "1.5 miles")
        XCTAssertEqual(DistanceFormat.distance(miles(12), spoken: true), "12 miles")
    }

    func testClimb() {
        XCTAssertEqual(DistanceFormat.climb(0), "0 ft")
        XCTAssertEqual(DistanceFormat.climb(5), "16 ft")
        XCTAssertEqual(DistanceFormat.climb(30), "98 ft")
    }

    func testFactorTextHasNoMetricUnits() {
        XCTAssertEqual(Factor.residential.describe(1000), "0.6 mi on residential streets")
        XCTAssertEqual(Factor.residential.change(1000, more: true), "0.6 mi more on residential streets")
        XCTAssertEqual(Factor.residential.change(100, more: false), "350 ft less on residential streets")
        XCTAssertEqual(Factor.climb.describe(10), "33 ft of climbing")
        XCTAssertEqual(Factor.climb.change(10, more: false), "33 ft less climbing")
    }
}
