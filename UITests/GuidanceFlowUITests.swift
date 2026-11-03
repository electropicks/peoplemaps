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
        XCTAssertTrue(app.buttons["guidance-overview"].exists)
        capture("06-guidance", app: app)
        let changed = NSPredicate { _, _ in instruction.exists && instruction.label != first }
        let expectation = XCTNSPredicateExpectation(predicate: changed, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 60), .completed, "Step text stayed '\(first)'")
        capture("07-guidance-next-step", app: app)
        app.buttons["end-navigation"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
    }
    @MainActor func testGuidanceStartsHeadingUpAndCompassFlipsToNorthUp() {
        let app = launch(simulateRoute: true)
        startSimulatedGuidance(app)
        let compass = app.buttons["guidance-compass"]
        XCTAssertTrue(compass.waitForExistence(timeout: 5))
        XCTAssertEqual(compass.label, "Heading up", "Heading-up is the default while guiding")
        XCTAssertFalse(app.buttons["guidance-recenter"].exists, "Following shows no Re-centre")
        compass.tap()
        XCTAssertEqual(compass.label, "North up")
        compass.tap()
        XCTAssertEqual(compass.label, "Heading up")
        XCTAssertFalse(app.buttons["guidance-recenter"].exists)
    }
    @MainActor func testPanningTheMapShowsRecentreWhichFollowsAgain() {
        let app = launch(simulateRoute: true)
        startSimulatedGuidance(app)
        let recenter = app.buttons["guidance-recenter"]
        XCTAssertFalse(recenter.exists)
        panMap(app)
        XCTAssertTrue(recenter.waitForExistence(timeout: 5), "A pan should stop following and offer Re-centre")
        XCTAssertEqual(recenter.label, "Re-centre")
        XCTAssertEqual(app.buttons["guidance-compass"].label, "Heading up", "A free look keeps the follow mode to return to")
        capture("09-guidance-free-look", app: app)
        recenter.tap()
        XCTAssertTrue(waitUntilGone(recenter), "Re-centre should go once following again")
        XCTAssertTrue(app.staticTexts["guidance-instruction"].exists)
        // The compass still toggles after a free look, and following stays on.
        app.buttons["guidance-compass"].tap()
        XCTAssertEqual(app.buttons["guidance-compass"].label, "North up")
        XCTAssertFalse(recenter.exists)
    }
    @MainActor func testOverviewTogglesAndReturnsToFollowing() {
        let app = launch(simulateRoute: true)
        startSimulatedGuidance(app)
        let overview = app.buttons["guidance-overview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertEqual(overview.label, "Route overview")
        overview.tap()
        XCTAssertEqual(overview.label, "Follow my position")
        XCTAssertFalse(app.buttons["guidance-recenter"].exists, "The overview is not a free look")
        capture("10-guidance-overview", app: app)
        overview.tap()
        XCTAssertEqual(overview.label, "Route overview")
        XCTAssertEqual(app.buttons["guidance-compass"].label, "Heading up")
    }
    @MainActor func testSimulatedGuidanceArrivesAndDoneReturnsHome() {
        let app = launch(simulateRoute: true, fast: true)
        app.buttons["start-navigation"].tap()
        XCTAssertTrue(app.staticTexts["guidance-instruction"].waitForExistence(timeout: 10))
        let arrived = app.staticTexts["guidance-arrived"]
        XCTAssertTrue(arrived.waitForExistence(timeout: 150), "Never arrived")
        XCTAssertTrue(arrived.label.contains("You've arrived at"), arrived.label)
        XCTAssertTrue(app.staticTexts["arrival-summary"].exists)
        XCTAssertFalse(app.buttons["end-navigation"].exists)
        capture("08-arrived", app: app)
        app.buttons["done-navigation"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 10))
    }
    /// A tap on the compass while in the overview only leaves it: the orientation it had stays.
    @MainActor func testCompassInOverviewOnlyLeavesTheOverview() {
        let app = launch(simulateRoute: true)
        startSimulatedGuidance(app)
        let compass = app.buttons["guidance-compass"], overview = app.buttons["guidance-overview"]
        XCTAssertTrue(compass.waitForExistence(timeout: 5))
        XCTAssertEqual(compass.label, "Heading up")
        overview.tap()
        XCTAssertEqual(overview.label, "Follow my position")
        compass.tap()
        XCTAssertEqual(overview.label, "Route overview", "The compass should leave the overview")
        XCTAssertEqual(compass.label, "Heading up", "Leaving the overview must not flip the orientation")
    }
}
