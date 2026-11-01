import XCTest
@testable import PeoplemapsCore

final class RerouteGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ x: Double, _ y: Double) -> Coordinate {
        Coordinate(lat: 47.6 + y / 111_195, lon: -122.3 + x / (111_195 * cos(47.6 * .pi / 180)))
    }
    private func fix(_ off: Double, accuracy: Double = 10, speed: Double? = 13, x: Double = 0, seconds: Double = 0) -> RerouteGate.Fix {
        RerouteGate.Fix(coordinate: at(x, 0), metersOffRoute: off, accuracy: accuracy, speed: speed, time: t0.addingTimeInterval(seconds))
    }
    /// A gate whose route was installed long ago and that has seen the user on it.
    private func settled(_ mode: TravelMode = .drive) -> RerouteGate {
        var gate = RerouteGate(mode: mode)
        gate.routeInstalled(at: t0.addingTimeInterval(-60))
        gate.onRoute()
        return gate
    }

    func testThresholdAddsErrorRadiusAndOneSecondOfTravel() {
        let drive = RerouteGate(mode: .drive), walk = RerouteGate(mode: .walk)
        XCTAssertEqual(drive.threshold(accuracy: 0, speed: 0), 50)
        XCTAssertEqual(drive.threshold(accuracy: 10, speed: 13), 73)
        XCTAssertEqual(drive.threshold(accuracy: 25, speed: nil), 75)
        XCTAssertEqual(walk.threshold(accuracy: 5, speed: 1.4), 36.4, accuracy: 0.001)
        XCTAssertEqual(RerouteGate(mode: .bike).baseMeters, 30)
    }

    func testOneWideFixIsNotARerouteButARunIs() {
        var gate = settled()
        XCTAssertFalse(gate.shouldReroute(fix(120)))
        XCTAssertFalse(gate.shouldReroute(fix(120, seconds: 1)))
        XCTAssertTrue(gate.shouldReroute(fix(120, seconds: 2)))
    }

    func testAnOnRouteFixBreaksTheRun() {
        var gate = settled()
        XCTAssertFalse(gate.shouldReroute(fix(120)))
        XCTAssertFalse(gate.shouldReroute(fix(120, seconds: 1)))
        gate.onRoute()
        XCTAssertFalse(gate.shouldReroute(fix(120, seconds: 2)))
        XCTAssertFalse(gate.shouldReroute(fix(120, seconds: 3)))
        XCTAssertTrue(gate.shouldReroute(fix(120, seconds: 4)))
    }

    func testFixesInsideTheThresholdNeverCount() {
        var gate = settled()
        // 60 m off with 10 m accuracy at 13 m/s is inside 73 m, however long it lasts.
        for s in 0..<20 { XCTAssertFalse(gate.shouldReroute(fix(60, seconds: Double(s)))) }
        // Standing still with a sharp fix, the same 60 m is over the 50 m base.
        var still = settled()
        for s in 0..<2 { XCTAssertFalse(still.shouldReroute(fix(60, accuracy: 0, speed: 0, seconds: Double(s)))) }
        XCTAssertTrue(still.shouldReroute(fix(60, accuracy: 0, speed: 0, seconds: 2)))
    }

    func testMinimumIntervalSinceTheLastRouteWasInstalled() {
        var gate = RerouteGate(mode: .drive)
        gate.routeInstalled(at: t0)
        gate.onRoute()
        for s in 0..<10 { XCTAssertFalse(gate.shouldReroute(fix(200, seconds: Double(s))), "second \(s)") }
        XCTAssertTrue(gate.shouldReroute(fix(200, seconds: 10)))
        // The run was already long enough; the interval alone was holding it back.
        var walk = RerouteGate(mode: .walk)
        walk.routeInstalled(at: t0); walk.onRoute()
        for s in 0..<3 { XCTAssertFalse(walk.shouldReroute(fix(100, speed: 1.4, seconds: Double(s) * 4))) }
        XCTAssertTrue(walk.shouldReroute(fix(100, speed: 1.4, seconds: 12)))
    }

    func testApproachingASnappedStartIsNotADeviation() {
        var gate = RerouteGate(mode: .drive)
        gate.routeInstalled(at: t0.addingTimeInterval(-60))
        // 150 m from the route's first step, closing at 13 m/s for twelve seconds, never on it yet.
        for s in 0..<12 {
            let off = 150 - 13 * Double(s)
            XCTAssertFalse(gate.shouldReroute(fix(off, x: 13 * Double(s), seconds: Double(s))), "second \(s)")
        }
    }

    func testDrivingAwayFromTheStartReroutes() {
        var gate = RerouteGate(mode: .drive)
        gate.routeInstalled(at: t0.addingTimeInterval(-60))
        XCTAssertFalse(gate.shouldReroute(fix(150)))
        XCTAssertFalse(gate.shouldReroute(fix(200, x: 50, seconds: 4)))
        // 150 + 73 = 223 m is the gap that means the user is leaving, not arriving.
        XCTAssertTrue(gate.shouldReroute(fix(230, x: 80, seconds: 6)))
    }

    func testTravellingPastTheStartWithoutReachingItReroutes() {
        var gate = RerouteGate(mode: .drive)
        gate.routeInstalled(at: t0.addingTimeInterval(-60))
        // A parallel street: the gap stays 100 m while the user covers 2 × 100 + 73 m.
        var rerouted = false
        for s in 0..<30 where !rerouted { rerouted = gate.shouldReroute(fix(100, x: 13 * Double(s), seconds: Double(s))) }
        XCTAssertTrue(rerouted)
    }

    func testPoorAccuracyFixDoesNotEndTheApproach() {
        var gate = RerouteGate(mode: .drive)
        gate.routeInstalled(at: t0.addingTimeInterval(-60))
        gate.observe(distanceToRoute: 3, accuracy: 40)
        XCTAssertFalse(gate.hasReachedRoute)
        // Still approaching, so the later good fixes 143 m out are not a deviation.
        for s in 0..<5 { XCTAssertFalse(gate.shouldReroute(fix(143, seconds: Double(s) * 2))) }
    }

    func testGoodFixWithin25MetresEndsTheApproach() {
        var gate = RerouteGate(mode: .drive)
        gate.routeInstalled(at: t0)
        gate.observe(distanceToRoute: 25, accuracy: 25)
        XCTAssertTrue(gate.hasReachedRoute)
    }

    func testGoodFixFarFromTheRouteDoesNotEndTheApproach() {
        var gate = RerouteGate(mode: .drive)
        gate.routeInstalled(at: t0)
        gate.observe(distanceToRoute: 26, accuracy: 5)
        XCTAssertFalse(gate.hasReachedRoute)
        XCTAssertFalse(RerouteGate.isOnRoute(distanceToRoute: 100, accuracy: 5))
    }

    func testJitterWhileStandingStillIsNotTravel() {
        var gate = RerouteGate(mode: .walk)
        gate.routeInstalled(at: t0.addingTimeInterval(-60))
        // 100 m gap; overdue needs 2 x 100 + threshold of travel. Ten-metre wobbles at 15 m accuracy (Ferrostar never delivers worse than 25), speed 0.2.
        for s in 0..<200 {
            XCTAssertFalse(gate.shouldReroute(fix(100, accuracy: 15, speed: 0.2, x: s % 2 == 0 ? 0 : 10, seconds: Double(s))), "second \(s)")
        }
    }

    func testSlowWalkerPastTheStartWithoutReachingItEventuallyReroutes() {
        var gate = RerouteGate(mode: .walk)
        gate.routeInstalled(at: t0.addingTimeInterval(-60))
        // 100 m gap held constant while walking 1.2 m/s with fixes about 1 m apart: overdue after 2 x 100 + 30 + 10 + 1.2 m.
        var first: Int?
        for s in 0..<400 {
            if gate.shouldReroute(fix(100, accuracy: 10, speed: 1.2, x: Double(s) * 1.2, seconds: Double(s))) { first = s; break }
        }
        let s = try! XCTUnwrap(first)
        XCTAssertGreaterThan(s, 150)
        XCTAssertLessThan(s, 215)
    }

    func testNilSpeedUsesStepsLargerThanAccuracyAsTravel() {
        var gate = RerouteGate(mode: .walk)
        gate.routeInstalled(at: t0.addingTimeInterval(-60))
        // Without a speed, steps under the accuracy are jitter and never accrue; steps over it do.
        for s in 0..<200 { XCTAssertFalse(gate.shouldReroute(fix(100, accuracy: 10, speed: nil, x: s % 2 == 0 ? 0 : 5, seconds: Double(s))), "jitter \(s)") }
        var rerouted = false
        for s in 0..<100 where gate.shouldReroute(fix(100, accuracy: 10, speed: nil, x: 20 + Double(s) * 12, seconds: 200 + Double(s))) { rerouted = true; break }
        XCTAssertTrue(rerouted)
    }

    func testDistanceToSegmentAndPolyline() {
        let a = at(0, 0), b = at(100, 0)
        XCTAssertEqual(at(50, 30).distance(toSegment: a, b), 30, accuracy: 0.1)
        XCTAssertEqual(at(-40, 0).distance(toSegment: a, b), 40, accuracy: 0.1)
        XCTAssertEqual(at(130, 40).distance(toSegment: a, b), 50, accuracy: 0.1)
        XCTAssertEqual(at(50, 0).distance(toSegment: a, a), 50, accuracy: 0.1)
        let line = [at(0, 0), at(100, 0), at(100, 100)]
        XCTAssertEqual(at(120, 50).distance(toPolyline: line), 20, accuracy: 0.1)
        XCTAssertEqual(at(60, -10).distance(toPolyline: line), 10, accuracy: 0.1)
        XCTAssertEqual(at(60, -10).distance(toPolyline: [at(0, 0)]), 60.8, accuracy: 0.1)
        XCTAssertEqual(at(0, 0).distance(toPolyline: []), .infinity)
    }
}
