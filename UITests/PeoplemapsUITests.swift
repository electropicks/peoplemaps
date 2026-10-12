import XCTest

final class PeoplemapsUITests: XCTestCase {
    @MainActor private func launch(slow: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = slow ? ["--ui-testing", "--slow-routing"] : ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        return app
    }
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testDrivingCyclingBudgetAndExplanation() {
        let app = launch()
        capture("01-driving-comparison", app: app)
        app.buttons["budget-0"].tap()
        XCTAssertTrue(app.staticTexts["One good option"].waitForExistence(timeout: 10))
        app.buttons["budget-5"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        app.buttons["mode-bike"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        capture("02-cycling-comparison", app: app)
        app.buttons["route-details"].tap()
        XCTAssertTrue(app.navigationBars["Behind the routes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cycleway / track tags"].exists)
        capture("03-route-evidence", app: app)
        app.buttons["close-details"].tap()
        app.buttons["mode-drive"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
    }
    @MainActor func testSearchEmptyCancelAndSelection() {
        let app = launch()
        let before = app.buttons["choose-origin"].label
        app.buttons["choose-origin"].tap()
        let field = app.textFields["place-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("unfindableXYZ")
        XCTAssertTrue(app.staticTexts["search-empty"].waitForExistence(timeout: 5))
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
        app.buttons["mode-bike"].tap()
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
            app.buttons["mode-bike"].tap()
            app.buttons["budget-2"].tap()
            app.buttons["mode-drive"].tap()
            app.buttons["budget-10"].tap()
            app.buttons["swap"].tap()
            XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 12))
        }
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Kerry"))
        XCTAssertTrue(app.buttons["choose-destination"].label.contains("Gas Works"))
        XCTAssertTrue(app.staticTexts["budget-label"].label.contains("10"))
        app.buttons["recenter"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].exists)
    }
}
