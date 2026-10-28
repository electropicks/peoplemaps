import XCTest

final class PeoplemapsUITests: XCTestCase {
    @MainActor private func launch(slow: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = slow ? ["--ui-testing", "--slow-routing"] : ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["featured-relation/1047789"].waitForExistence(timeout: 20))
        app.buttons["featured-relation/1047789"].tap()
        XCTAssertTrue(app.buttons["directions"].waitForExistence(timeout: 5))
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        return app
    }
    @MainActor private func launchHome() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 20))
        return app
    }
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testDrivingCyclingBudgetAndExplanation() {
        let app = launch()
        capture("01-driving-comparison", app: app)
        app.buttons["None"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["no-alternative"].waitForExistence(timeout: 10))
        app.buttons["5 min"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        app.buttons["Cycle"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        capture("02-cycling-comparison", app: app)
        app.buttons["route-details"].tap()
        XCTAssertTrue(app.navigationBars["Behind the routes"].waitForExistence(timeout: 5))
        let climbing = app.staticTexts["Climbing"]
        for _ in 0..<4 where !climbing.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(climbing.exists)
        capture("03-route-evidence", app: app)
        app.buttons["close-details"].tap()
        app.buttons["Drive"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
    }
    @MainActor func testSearchEmptyCancelAndSelection() {
        let app = launch()
        let before = app.buttons["choose-origin"].label
        app.buttons["choose-origin"].tap()
        let field = app.textFields["place-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("unfindableXYZ")
        XCTAssertTrue(app.descendants(matching: .any)["search-empty"].waitForExistence(timeout: 5))
        app.buttons["cancel-search"].tap()
        XCTAssertEqual(app.buttons["choose-origin"].label, before)
        app.buttons["choose-origin"].tap()
        XCTAssertTrue(app.buttons["place-way/37058377"].waitForExistence(timeout: 5))
        app.buttons["place-way/37058377"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Fremont"))
    }
    @MainActor func testSamePlaceErrorAndRecovery() {
        let app = launch()
        app.buttons["choose-destination"].tap()
        app.buttons["place-node/693337509"].tap()
        XCTAssertTrue(app.staticTexts["Choose two different places to compare routes."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        app.buttons["retry-route"].tap()
        XCTAssertTrue(app.staticTexts["Choose two different places to compare routes."].waitForExistence(timeout: 10))
        app.buttons["choose-destination"].tap()
        app.buttons["place-relation/1047789"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
    }
    @MainActor func testCancelAndResumeComparison() {
        let app = launch(slow: true)
        app.buttons["Cycle"].tap()
        XCTAssertTrue(app.buttons["cancel-route"].waitForExistence(timeout: 5))
        app.buttons["cancel-route"].tap()
        XCTAssertTrue(app.staticTexts["Comparison paused"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        app.buttons["retry-route"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 15))
    }
    @MainActor func testRepeatedModeBudgetAndSwapChanges() {
        let app = launch()
        for _ in 0..<2 {
            app.buttons["Cycle"].tap()
            app.buttons["2 min"].tap()
            app.buttons["Drive"].tap()
            app.buttons["10 min"].tap()
            app.buttons["swap"].tap()
            XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 12))
        }
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Kerry"))
        XCTAssertTrue(app.buttons["choose-destination"].label.contains("Gas Works"))
        XCTAssertTrue(app.buttons["10 min"].isSelected)
        XCTAssertTrue(app.buttons["Drive"].isSelected)
        app.buttons["recenter"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].exists)
    }
    @MainActor func testLandscapeKeepsComparison() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["choose-origin"].isHittable)
        app.buttons["Cycle"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        app.buttons["recenter"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].exists)
    }
    @MainActor func testHomeLandsOnFeaturedPlacesWithoutRoutes() {
        let app = launchHome()
        for id in ["relation/1047789", "way/37058377", "way/160545994", "node/693337509"] {
            XCTAssertTrue(app.buttons["featured-\(id)"].exists, id)
        }
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        for (id, subtitle) in [("way/37058377", "Fremont"), ("way/160545994", "University District"), ("node/693337509", "Queen Anne")] {
            XCTAssertTrue(app.buttons["featured-\(id)"].label.hasSuffix("· \(subtitle)"), id)
        }
        capture("00-home", app: app)
    }
    @MainActor func testSearchFindsParkAndOpensPlaceCard() {
        let app = launchHome()
        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("park")
        XCTAssertTrue(app.buttons["result-relation/1047789"].waitForExistence(timeout: 5))
        capture("04-search-park", app: app)
        app.buttons["result-relation/1047789"].tap()
        XCTAssertTrue(app.buttons["directions"].waitForExistence(timeout: 5))
        capture("05-place-card", app: app)
        app.buttons["close-place"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
    }
    @MainActor func testSearchWithNoMatchesAndCancel() {
        let app = launchHome()
        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("unfindableXYZ")
        XCTAssertTrue(app.descendants(matching: .any)["search-empty"].waitForExistence(timeout: 5))
        app.buttons["cancel-search-home"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
    }
    @MainActor func testClosingPreviewReturnsHome() {
        let app = launch()
        app.buttons["close-preview"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["route-fastest"].exists)
    }
    @MainActor func testHomeInLandscapeShowsSearchField() {
        let app = launchHome()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["search-field"].isHittable)
        capture("06-home-landscape", app: app)
    }
}
