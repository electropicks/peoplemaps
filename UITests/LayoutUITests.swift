import XCTest
import CoreLocation

final class LayoutUITests: PeoplemapsUITestCase {
    /// AX3 text with long street names: the "Then:" row stays inside the banner, above the calm chip, and the current
    /// instruction is fully on screen.
    @MainActor func testGuidanceBannerHoldsLongNamesAtAX3() {
        let app = launch(simulateRoute: true, extra: ["--long-street-names", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        app.buttons["start-navigation"].tap()
        let instruction = app.staticTexts["guidance-instruction"]
        XCTAssertTrue(instruction.waitForExistence(timeout: 10))
        let then = app.descendants(matching: .any)["guidance-then"]
        XCTAssertTrue(then.waitForExistence(timeout: 5))
        let card = app.descendants(matching: .any)["guidance-card"].frame
        XCTAssertTrue(instruction.label.contains("Extension"), instruction.label)
        XCTAssertGreaterThanOrEqual(then.frame.minY, instruction.frame.maxY - 1, "Then row overprints the instruction")
        XCTAssertLessThanOrEqual(then.frame.maxY, card.maxY + 1, "Then row spills out of the banner")
        let chip = app.descendants(matching: .any)["guidance-calm-note"]
        if chip.exists { XCTAssertGreaterThanOrEqual(chip.frame.minY, card.maxY - 1, "Calm chip overlaps the banner") }
        capture("guidance-ax3-banner", app: app)
    }
    /// AX5 arrival: Done stays on screen, the summary shows in full and the rest scrolls.
    @MainActor func testArrivalCardFitsAtAX5() {
        let app = launch(simulateRoute: true, fast: true, extra: ["--long-street-names", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["start-navigation"].tap()
        let arrived = app.staticTexts["guidance-arrived"]
        XCTAssertTrue(arrived.waitForExistence(timeout: 150), "Never arrived")
        let window = app.windows.firstMatch.frame
        let done = app.buttons["done-navigation"]
        XCTAssertTrue(done.isHittable)
        XCTAssertLessThanOrEqual(done.frame.maxY, window.maxY)
        XCTAssertGreaterThanOrEqual(arrived.frame.minY, window.minY)
        let summary = app.staticTexts["arrival-summary"]
        XCTAssertTrue(summary.label.contains("route"), summary.label)
        XCTAssertLessThanOrEqual(summary.frame.maxY, window.maxY)
        capture("arrival-ax5", app: app)
        done.tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 10))
    }
    /// At AX3 the chrome still leaves the three map buttons, End and the map's own gestures reachable.
    @MainActor func testGuidanceAtAX3KeepsButtonsReachableAndMapPannable() {
        let app = launchHome(location: Self.atKerryPark, extra: ["--simulate-route", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        showGasWorksRoutes(app)
        startSimulatedGuidance(app)
        for id in ["guidance-mute", "guidance-compass", "guidance-overview", "end-navigation"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), id)
            XCTAssertTrue(app.buttons[id].isHittable, "\(id) is not hittable at AX3")
        }
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.35)))
        XCTAssertTrue(app.buttons["guidance-recenter"].waitForExistence(timeout: 5), "A pan should reach the map at AX3")
    }
    @MainActor func testLandscapeGuidanceKeepsEndAndMuteHittable() {
        let app = launch(simulateRoute: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        startSimulatedGuidance(app)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "The device did not rotate to landscape")
        XCTAssertTrue(app.buttons["end-navigation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["end-navigation"].isHittable, "End must be reachable in the landscape card")
        XCTAssertTrue(app.buttons["guidance-mute"].isHittable, "Mute must be reachable in the trailing capsule")
        capture("11-guidance-landscape", app: app)
    }
    @MainActor func testLandscapeKeepsComparison() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["choose-origin"].isHittable)
        XCTAssertTrue(app.buttons["start-navigation"].isHittable, "Start stays on screen in landscape")
        app.buttons["Cycle"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        app.buttons["recenter"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].exists)
    }
    @MainActor func testHomeInLandscapeShowsSearchField() {
        let app = launchHome()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["search-field"].isHittable)
        capture("06-home-landscape", app: app)
    }
    /// At the largest text everything still scrolls into reach, with Start pinned.
    @MainActor func testPreviewScrollsAndKeepsStartAtTheLargestText() {
        let app = launchHome(location: Self.atBallardLibrary, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openPlace(app, "Gas Works", id: "relation/1047789")
        waitForEstimate(app)
        XCTAssertTrue(app.buttons["directions"].isHittable)
        capture("20-place-largest-text", app: app)
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["start-navigation"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["start-navigation"].isHittable)
        capture("21-preview-largest-text", app: app)
        XCTAssertTrue(app.buttons["route-details"].isHittable, "Why this route is pinned with Start")
        let fastest = app.buttons["route-fastest"]
        for _ in 0..<8 where !fastest.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(fastest.isHittable, "The routes scroll into reach")
        XCTAssertTrue(app.buttons["start-navigation"].isHittable)
    }
    @MainActor func testFavouritesAndDroppedPinInLandscape() {
        let app = launchHome()
        openPlace(app, "Fremont Branch", id: "way/37058377")
        XCTAssertTrue(app.buttons["favourite"].waitForExistence(timeout: 5))
        app.buttons["favourite"].tap()
        app.buttons["close-place"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let row = app.buttons["favourite-way/37058377"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.isHittable)
        capture("15-home-favourites-landscape", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["place-subtitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["directions"].isHittable)
        capture("16-dropped-pin-landscape", app: app)
    }
}
