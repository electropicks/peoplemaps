import XCTest
import CoreLocation

final class RoutePickerUITests: PeoplemapsUITestCase {
    @MainActor func testSearchEmptyCancelAndSelection() {
        let app = launch()
        let before = app.buttons["choose-origin"].label
        XCTAssertTrue(before.contains("Current location"), before)
        app.buttons["choose-origin"].tap()
        let field = placeSearch(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("unfindableXYZ")
        XCTAssertTrue(app.descendants(matching: .any)["search-empty"].waitForExistence(timeout: 5))
        capture("14d-picker-no-matches", app: app)
        app.buttons["cancel-search"].tap()
        XCTAssertEqual(app.buttons["choose-origin"].label, before)
        app.buttons["choose-origin"].tap()
        pick(app, "Fremont Branch", id: "way/37058377")
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Fremont"))
    }
    @MainActor func testSamePlaceErrorAndRecovery() {
        let app = launch()
        app.buttons["choose-origin"].tap()
        pick(app, "Gas Works", id: "relation/1047789")
        XCTAssertTrue(app.staticTexts["Choose two different places to compare routes."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        app.buttons["retry-route"].tap()
        XCTAssertTrue(app.staticTexts["Choose two different places to compare routes."].waitForExistence(timeout: 10))
        app.buttons["choose-destination"].tap()
        pick(app, "Kerry Park", id: "node/693337509")
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
    }
    /// Current location far outside the routing bounds: Directions says the start is outside and offers to pick another.
    @MainActor func testStartOutsideCoverageSaysSoAndLetsYouPickAStart() {
        let app = launchHome(location: "47.4000,-122.2000")
        openPlace(app, "Gas Works", id: "relation/1047789")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["start-outside-coverage"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your start is outside the area we cover"].exists)
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        XCTAssertFalse(app.buttons["retry-route"].exists, "not a generic failure")
        capture("10b-start-outside", app: app)
        app.buttons["Choose start"].tap()
        XCTAssertTrue(placeSearch(app).waitForExistence(timeout: 5))
    }
    /// The bars explain the rating in words and scores; a route with nothing calmer has one bar and says what was found.
    @MainActor func testCalmBarInRouteDetails() {
        var app = launchHome(location: Self.atBallardLibrary)
        showGasWorksRoutes(app)
        XCTAssertTrue(app.buttons["route-calmer"].waitForExistence(timeout: 10))
        // The calmer card reads fastest to calmer.
        XCTAssertTrue(app.buttons["route-calmer"].label.contains(" to "), app.buttons["route-calmer"].label)
        app.buttons["route-details"].tap()
        var bar = app.descendants(matching: .any)["calm-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.label.hasPrefix("Calm estimate"), bar.label)
        XCTAssertTrue(bar.label.contains("Fastest: "), bar.label)
        XCTAssertTrue(bar.label.contains("Calmer: "), bar.label)
        XCTAssertTrue(bar.label.contains(" out of 100"), bar.label)
        XCTAssertFalse(bar.label.localizedCaseInsensitiveContains("safe"), bar.label)
        capture("18-calm-bar", app: app)
        app.terminate()
        app = launchHome(location: Self.atKerryPark)
        showGasWorksRoutes(app)
        // With extra time at None nothing else is searched, in any region.
        setExtraTime(app, "None")
        XCTAssertTrue(app.descendants(matching: .any)["no-alternative"].waitForExistence(timeout: 10))
        app.buttons["route-details"].tap()
        bar = app.descendants(matching: .any)["calm-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.label.contains("This route: "), bar.label)
        XCTAssertFalse(bar.label.contains("Calmer: "), bar.label)
        capture("19-calm-bar-one-route", app: app)
    }
    /// Picker distances run from where the user is, not from the place being replaced, and are absent when that is unknown.
    @MainActor func testPickerDistanceIsFromTheUser() {
        let app = launch()
        app.buttons["choose-origin"].tap()
        pick(app, "Fremont Branch", id: "way/37058377")
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        app.buttons["choose-origin"].tap()
        let gasWorks = app.buttons["place-recent-relation/1047789"]
        XCTAssertTrue(gasWorks.waitForExistence(timeout: 5))
        // The user is at Kerry Park, 1.6 mi from Gas Works; the start place (Fremont) is under a mile away.
        let measured = NSPredicate { _, _ in gasWorks.label.contains("1.6 miles") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: measured, object: nil)], timeout: 10), .completed, gasWorks.label)
        capture("14b-picker-distance", app: app)
        app.buttons["cancel-search"].tap()
        // The destination picker doesn't know where the user is, so it shows no distances.
        app.buttons["choose-destination"].tap()
        let recent = app.buttons["place-recent-relation/1047789"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        XCTAssertFalse(recent.label.contains("mile") || recent.label.contains("feet"), recent.label)
        capture("14c-picker-destination", app: app)
        let field = placeSearch(app)
        field.tap(); field.typeText("Kerry")
        XCTAssertTrue(app.buttons["place-node/693337509"].waitForExistence(timeout: 5))
        capture("14e-picker-matches", app: app)
    }
}
