import XCTest
import CoreLocation

final class RealLocationUITests: PeoplemapsUITestCase {
    @MainActor func testRealLocationPermissionAllowedStartsAndEndsGuidance() {
        let app = launchReal()
        startGuidanceReal(app)
        XCTAssertEqual(probe(app, "debug-nav-state"), "guiding")
        XCTAssertEqual(probe(app, "debug-idle-disabled"), "1")
        app.buttons["end-navigation"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        XCTAssertEqual(probe(app, "debug-idle-disabled"), "0")
    }
    @MainActor func testRealLocationPermissionDeniedKeepsPreview() {
        let app = launchAskingForLocation(answer: "Don\u{2019}t Allow")
        showGasWorksStartless(app)
        app.buttons["choose-origin"].tap()
        pick(app, "Kerry Park", id: "node/693337509")
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        // Start still checks: guidance needs location, so it explains how to turn it on.
        app.buttons["start-navigation"].tap()
        let alert = app.alerts["Location is off for PeopleMaps"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["Not Now"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["guidance-instruction"].exists)
        XCTAssertEqual(probe(app, "debug-idle-disabled"), "0")
    }
    @MainActor func testRealGPSAlongTheRouteAdvancesInstruction() {
        let app = launchReal()
        startGuidanceReal(app)
        let instruction = app.staticTexts["guidance-instruction"]
        let first = instruction.label
        let line = routePoints(app)
        XCTAssertGreaterThan(line.count, 3, "Route readout missing")
        var changed = false
        for (point, course) in Self.samples(line, step: 20, limit: 600) {
            setDevice(point, course: course)
            Thread.sleep(forTimeInterval: 0.4)
            if instruction.label != first { changed = true }
        }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(changed || instruction.label != first, "Instruction stayed '\(first)' after 600 m")
        let spoken = probe(app, "debug-last-spoken")
        XCTAssertFalse(spoken.isEmpty)
        // The probe reports the normalised text: no street-type or compass abbreviations are left to be misread.
        XCTAssertNil(spoken.range(of: #"\b(St|Ave|Pl|Blvd|Dr|Ct|Ln|N|S|E|W|NE|NW|SE|SW)\b"#, options: .regularExpression), "Abbreviation in spoken text: \(spoken)")
        XCTAssertEqual(probe(app, "debug-nav-state"), "guiding")
        capture("09-real-gps-guidance", app: app)
    }
    @MainActor func testForcedRerouteRecoversWithNewRoute() {
        let app = launchReal()
        startGuidanceReal(app)
        let line = routePoints(app)
        XCTAssertGreaterThan(line.count, 3, "Route readout missing")
        let before = probe(app, "debug-route")
        let walk = Self.samples(line, step: 20, limit: 300)
        for (point, course) in walk { setDevice(point, course: course); Thread.sleep(forTimeInterval: 0.3) }
        guard let (last, course) = walk.last else { return XCTFail("No samples") }
        // 150 m to the side of the road (perpendicular to the travel direction).
        let side = (course + 90) * .pi / 180
        let off = CLLocationCoordinate2D(latitude: last.latitude + cos(side) * 150 / 111_000,
                                         longitude: last.longitude + sin(side) * 150 / 75_500)
        // Keep the fixes coming until the route is replaced: a reroute needs a run of off-route fixes, and at
        // least ten seconds since the route was installed.
        var sawRerouting = false
        let deadline = Date().addingTimeInterval(25)
        var jitter = 0.0
        while Date() < deadline, probe(app, "debug-route") == before {
            jitter += 0.00002
            setDevice(CLLocationCoordinate2D(latitude: off.latitude + jitter, longitude: off.longitude), course: course)
            if probe(app, "debug-nav-state") == "rerouting" || app.otherElements["guidance-rerouting"].exists { sawRerouting = true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        capture("18-after-forced-reroute", app: app)
        let rerouted = probe(app, "debug-route") != before
        XCTAssertTrue(sawRerouting || rerouted, "Neither a rerouting state nor a new route appeared")
        let guiding = NSPredicate { _, _ in self.probe(app, "debug-nav-state") == "guiding" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: guiding, object: nil)], timeout: 20), .completed, "Guidance never resumed")
        XCTAssertTrue(rerouted, "Route was not replaced")
        XCTAssertGreaterThanOrEqual(Int(probe(app, "debug-reroute-count")) ?? 0, 1, "Reroute count did not move")
        XCTAssertEqual(probe(app, "debug-route-clears"), "0", "The followed route's line was emptied during the reroute")
        XCTAssertTrue(app.staticTexts["guidance-instruction"].exists)
        XCTAssertFalse(app.staticTexts["guidance-instruction"].label.isEmpty)
    }
    /// Routes start at a snapped node, so a trip can begin some way from where the line does: a dashed leader
    /// bridges the gap, heading for the start is not treated as leaving the route, and the leader goes once on it.
    @MainActor func testLeaderBridgesTheGapToASnappedStart() {
        let app = launchAskingForLocation(answer: "Allow While Using App", at: Self.seattleCenterLawn)
        showGasWorksRoutes(app)
        startGuidanceReal(app)
        let leader = NSPredicate { _, _ in (Int(self.probe(app, "debug-leader")) ?? 0) > 25 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: leader, object: nil)], timeout: 10), .completed,
                       "No leader at a start \(probe(app, "debug-leader")) m from the route")
        // Calmer is the selected route here, so its line and leader hold the dusk blue. (A fastest route is the palette's
        // grey, by design: grey is not an unstyled state.) Both layers must carry the colour of the route's kind.
        XCTAssertEqual(probe(app, "debug-line-style"), "calmer 4A6F97 leader 4A6F97", "Line or leader not styled for the calmer route")
        capture("19-leader-at-start", app: app)
        let line = routePoints(app)
        XCTAssertGreaterThan(line.count, 3, "Route readout missing")
        for (point, course) in Self.samples(line, step: 20, limit: 120) { setDevice(point, course: course); Thread.sleep(forTimeInterval: 0.3) }
        let gone = NSPredicate { _, _ in self.probe(app, "debug-leader") == "0" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 10), .completed, "Leader stayed once on the route")
        XCTAssertEqual(probe(app, "debug-reroute-count"), "0", "Heading for the start counted as a deviation")
        XCTAssertEqual(probe(app, "debug-nav-state"), "guiding")
    }
    /// A fix on the route's line but with a poor error radius proves nothing: the engine snaps it, but the gate does not
    /// count it as reaching the route, so the leader from the device's own position to the start stays.
    @MainActor func testPoorAccuracyFixOnTheLineKeepsTheLeader() {
        let app = launchAskingForLocation(answer: "Allow While Using App", at: Self.seattleCenterLawn)
        showGasWorksRoutes(app)
        startGuidanceReal(app)
        let leader = NSPredicate { _, _ in (Int(self.probe(app, "debug-leader")) ?? 0) > 25 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: leader, object: nil)], timeout: 10), .completed, "No leader at the start")
        let line = routePoints(app)
        XCTAssertGreaterThan(line.count, 3, "Route readout missing")
        guard let (point, course) = Self.samples(line, step: 60, limit: 200).first else { return XCTFail("Route too short") }
        for _ in 0..<5 { setDevice(point, course: course, accuracy: 40); Thread.sleep(forTimeInterval: 0.5) }
        let held = Int(probe(app, "debug-leader")) ?? 0
        XCTAssertGreaterThan(held, 25, "A poor fix on the line hid the leader")
        // A good fix at the same place is on the route: the leader goes.
        setDevice(point, course: course, accuracy: 5)
        let gone = NSPredicate { _, _ in self.probe(app, "debug-leader") == "0" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 10), .completed, "Leader stayed after a good fix on the route")
    }
    @MainActor func testBackgroundAndForegroundKeepsGuidance() {
        let app = launchReal()
        startGuidanceReal(app)
        let instruction = app.staticTexts["guidance-instruction"]
        let before = instruction.label
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(instruction.waitForExistence(timeout: 10))
        let guiding = NSPredicate { _, _ in self.probe(app, "debug-nav-state") == "guiding" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: guiding, object: nil)], timeout: 10), .completed)
        XCTAssertFalse(instruction.label.isEmpty)
        XCTAssertEqual(instruction.label, before)
        XCTAssertEqual(probe(app, "debug-idle-disabled"), "1")
    }
    /// Locate is always shown; when it can't centre, it says why instead of doing nothing.
    @MainActor func testLocateExplainsWhenItCannotCentre() {
        var app = launchHome()
        XCTAssertEqual(app.buttons["locate"].value as? String ?? "", "")
        app.buttons["locate"].tap()
        XCTAssertTrue(app.alerts["Location is off for PeopleMaps"].waitForExistence(timeout: 5))
        app.alerts.buttons["Not Now"].tap()
        app.terminate()
        app = launchHome(location: "47.4000,-122.2000")
        app.buttons["locate"].tap()
        XCTAssertTrue(app.alerts["You\u{2019}re outside the area we cover"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        app.terminate()
        app = launchHome(location: Self.atKerryPark)
        app.buttons["locate"].tap()
        let centred = NSPredicate { _, _ in app.buttons["locate"].value as? String == "Centred" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: centred, object: nil)], timeout: 5), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
