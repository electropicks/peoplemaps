import XCTest
import CoreLocation

final class GuidanceFlowUITests: PeoplemapsUITestCase {
    @MainActor func testSimulatedGuidanceStartsAdvancesAndEnds() {
        let app = launch(simulateRoute: true)
        app.buttons["start-navigation"].tap()
        let instruction = app.staticTexts["guidance-instruction"]
        XCTAssertTrue(instruction.waitForExistence(timeout: 10))
        let first = instruction.label
        XCTAssertTrue(first.contains("Turn") || first.contains("Head"), first)
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        XCTAssertTrue(app.staticTexts["guidance-distance"].exists)
        XCTAssertTrue(app.staticTexts["trip-minutes"].exists)
        XCTAssertTrue(app.staticTexts["trip-arrival"].exists)
        XCTAssertTrue(app.buttons["guidance-camera"].exists)
        capture("06-guidance", app: app)
        let changed = NSPredicate { _, _ in instruction.exists && instruction.label != first }
        let expectation = XCTNSPredicateExpectation(predicate: changed, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 60), .completed, "Step text stayed '\(first)'")
        capture("07-guidance-next-step", app: app)
        app.buttons["end-navigation"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
    }
    private static let travel = "location.north.line.fill", compassSymbol = "safari", route = "map"

    /// One button, three states in a fixed order, each with its own symbol and label: travel direction (the default), compass
    /// direction, the whole route, and round again.
    @MainActor func testCameraButtonCyclesThroughThreeStates() {
        let app = launch(simulateRoute: true)
        startSimulatedGuidance(app)
        let camera = app.buttons["guidance-camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["guidance-compass"].exists, "The separate compass button is gone")
        XCTAssertFalse(app.buttons["guidance-overview"].exists, "The separate overview button is gone")
        XCTAssertEqual(camera.label, "Travel direction up", "Travel direction is the default while guiding")
        XCTAssertEqual(camera.value as? String, Self.travel)
        XCTAssertFalse(app.buttons["guidance-recenter"].exists, "Following shows no Re-centre")
        capture("12-camera-travel", app: app)
        camera.tap()
        XCTAssertEqual(camera.label, "Compass direction up")
        XCTAssertEqual(camera.value as? String, Self.compassSymbol)
        capture("13-camera-compass", app: app)
        camera.tap()
        XCTAssertEqual(camera.label, "Whole route")
        XCTAssertEqual(camera.value as? String, Self.route)
        XCTAssertFalse(app.buttons["guidance-recenter"].exists, "The overview is not a free look")
        capture("14-camera-route", app: app)
        camera.tap()
        XCTAssertEqual(camera.label, "Travel direction up")
        XCTAssertEqual(camera.value as? String, Self.travel)
        XCTAssertTrue(app.buttons["guidance-mute"].exists && app.buttons["mark-moment"].exists, "Mute and the flag stay in their cluster")
    }
    /// The camera button sits alone in a corner, below the banner and clear of the mute and flag cluster and the trip bar.
    @MainActor func testCameraButtonIsAloneInABottomCorner() {
        let app = launch(simulateRoute: true)
        startSimulatedGuidance(app)
        let camera = app.buttons["guidance-camera"], mute = app.buttons["guidance-mute"], tripBar = app.otherElements["trip-bar"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        XCTAssertTrue(camera.isHittable)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(camera.frame.midX, window.midX, "Trailing corner")
        XCTAssertGreaterThan(camera.frame.minY, mute.frame.maxY, "Below the mute and flag cluster")
        XCTAssertLessThanOrEqual(camera.frame.maxY, tripBar.frame.minY + 1, "Above the trip bar")
        XCTAssertFalse(camera.frame.intersects(app.staticTexts["guidance-instruction"].frame))
    }
    @MainActor func testPanningTheMapShowsRecentreWhichFollowsAgain() {
        let app = launch(simulateRoute: true)
        startSimulatedGuidance(app)
        let recenter = app.buttons["guidance-recenter"], camera = app.buttons["guidance-camera"]
        XCTAssertFalse(recenter.exists)
        camera.tap()
        XCTAssertEqual(camera.label, "Compass direction up")
        panMap(app)
        XCTAssertTrue(recenter.waitForExistence(timeout: 5), "A pan should stop following and offer Re-centre")
        XCTAssertEqual(recenter.label, "Re-centre")
        XCTAssertEqual(camera.label, "Compass direction up", "A free look keeps the state to return to")
        capture("09-guidance-free-look", app: app)
        camera.tap()
        XCTAssertTrue(waitUntilGone(recenter), "The camera button returns to the state before the pan")
        XCTAssertEqual(camera.label, "Compass direction up")
        XCTAssertTrue(app.staticTexts["guidance-instruction"].exists)
        // Re-centre does the same.
        panMap(app)
        XCTAssertTrue(recenter.waitForExistence(timeout: 5))
        recenter.tap()
        XCTAssertTrue(waitUntilGone(recenter))
        XCTAssertEqual(camera.label, "Compass direction up")
        // And from the cycle's next step on.
        camera.tap()
        XCTAssertEqual(camera.label, "Whole route")
    }
    /// A stopped fix, the start of a trip before any course exists, still shows which way the person faces: the compass
    /// (here `--fake-heading`) gives the marker its point.
    @MainActor func testStoppedFixWithAHeadingShowsThePoint() {
        let app = launch(simulateRoute: true, extra: ["--fake-heading", "70", "--hold-simulation"])
        startSimulatedGuidance(app)
        let point = NSPredicate { _, _ in self.probe(app, "debug-marker") == "point 70" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: point, object: nil)], timeout: 10), .completed,
                       "Marker without a course: \(probe(app, "debug-marker"))")
        capture("15-stopped-heading-point", app: app)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(probe(app, "debug-marker"), "point 70", "The device never moved, so the compass still decides")
    }
    @MainActor func testSimulatedGuidanceArrivesAndDoneReturnsHome() {
        let app = launch(simulateRoute: true, fast: true)
        app.buttons["start-navigation"].tap()
        XCTAssertTrue(app.staticTexts["guidance-instruction"].waitForExistence(timeout: 10))
        let arrived = app.staticTexts["guidance-arrived"]
        XCTAssertTrue(arrived.waitForExistence(timeout: 150), "Never arrived")
        XCTAssertTrue(arrived.label.contains("You\u{2019}ve arrived at"), arrived.label)
        XCTAssertTrue(app.staticTexts["arrival-summary"].exists)
        XCTAssertFalse(app.buttons["end-navigation"].exists)
        capture("08-arrived", app: app)
        app.buttons["done-navigation"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 10))
    }
}
