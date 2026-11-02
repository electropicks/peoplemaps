import XCTest

/// Screens for `Evidence/`, saved as test attachments. Skipped unless `TEST_RUNNER_PEOPLEMAPS_EVIDENCE=1`; set the
/// simulator's appearance (`xcrun simctl ui <udid> appearance dark`) before each run.
final class EvidenceTour: XCTestCase {
    @MainActor private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func launch(_ arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor private func open(_ app: XCUIApplication, _ query: String, id: String) {
        app.buttons["search-field"].tap()
        XCTAssertTrue(app.textFields["search-input"].waitForExistence(timeout: 5))
        app.textFields["search-input"].typeText(query)
        XCTAssertTrue(app.buttons["result-\(id)"].waitForExistence(timeout: 5))
        app.buttons["result-\(id)"].tap()
    }

    @MainActor private func raise(_ app: XCUIApplication) {
        let start = app.buttons["search-field"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -300)))
    }

    @MainActor private func waitForEstimate(_ app: XCUIApplication) {
        let directions = app.buttons["directions"]
        let estimated = NSPredicate { _, _ in (directions.value as? String)?.contains(" minute") == true }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: estimated, object: nil)], timeout: 20)
    }

    /// The home sheet, place card, preview and calm bar. Run once per appearance; `TEST_RUNNER_PEOPLEMAPS_TEXT` sets a text size.
    @MainActor func testHomeRedesign() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PEOPLEMAPS_EVIDENCE"] == "1", "Set TEST_RUNNER_PEOPLEMAPS_EVIDENCE=1")
        let text = ProcessInfo.processInfo.environment["PEOPLEMAPS_TEXT"].map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []
        let ballard = "47.6698,-122.3843", kerry = "47.6295,-122.3599"
        var app = launch(["--location-granted", ballard] + text)
        shot("home-peek-first-launch")
        open(app, "Gas Works", id: "relation/1047789")
        waitForEstimate(app)
        shot("place-calmer")
        app.buttons["favourite"].tap()
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["start-navigation"].waitForExistence(timeout: 20))
        shot("preview-calmer")
        app.buttons["route-details"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["calm-bar"].waitForExistence(timeout: 5))
        shot("details-calmer")
        app.buttons["close-details"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["start-navigation"].waitForExistence(timeout: 10))
        shot("preview-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["close-preview"].waitForExistence(timeout: 10))
        let start = app.buttons["start-navigation"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -6))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -500)))
        shot("preview-large")
        app.buttons["close-preview"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
        shot("home-peek-favourites")
        raise(app)
        shot("home-raised")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 10))
        shot("home-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        app = launch(["--location-granted", kerry] + text)
        open(app, "Gas Works", id: "relation/1047789")
        waitForEstimate(app)
        shot("place-no-calmer")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["start-navigation"].waitForExistence(timeout: 20))
        shot("preview-no-calmer")
        app.buttons["route-details"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["calm-bar"].waitForExistence(timeout: 5))
        shot("details-no-calmer")
    }

    /// Place markers and each screen around them. Run once per appearance.
    @MainActor func testMapPlaces() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PEOPLEMAPS_EVIDENCE"] == "1", "Set TEST_RUNNER_PEOPLEMAPS_EVIDENCE=1")
        var app = launch(["--location-granted", "47.6505,-122.35"])
        Thread.sleep(forTimeInterval: 3)
        shot("map-neighbourhood")
        let window = app.windows.firstMatch
        window.pinch(withScale: 2, velocity: 2)
        Thread.sleep(forTimeInterval: 2)
        shot("map-zoomed-in")
        window.pinch(withScale: 2, velocity: 2)
        Thread.sleep(forTimeInterval: 2)
        shot("map-zoomed-in-more")
        app.buttons["search-field"].tap()
        XCTAssertTrue(app.textFields["search-input"].waitForExistence(timeout: 5))
        app.textFields["search-input"].typeText("coffee")
        shot("search")
        app.buttons["cancel-search-home"].tap()
        open(app, "Gas Works", id: "relation/1047789")
        waitForEstimate(app)
        shot("place-card")
        app.buttons["favourite"].tap()
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["start-navigation"].waitForExistence(timeout: 20))
        shot("route-preview")
        app.buttons["close-preview"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
        shot("home-favourites")
        raise(app)
        shot("home-raised")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 10))
        shot("home-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        app = launch(["--location-granted", "47.6505,-122.35", "--simulate-route"])
        open(app, "Gas Works", id: "relation/1047789")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["start-navigation"].waitForExistence(timeout: 20))
        app.buttons["start-navigation"].tap()
        XCTAssertTrue(app.staticTexts["guidance-instruction"].waitForExistence(timeout: 10))
        shot("guidance")
        app.terminate()
        app = launch([])
        Thread.sleep(forTimeInterval: 3)
        shot("map-zoomed-out")
    }

    @MainActor func testEvidence() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PEOPLEMAPS_EVIDENCE"] == "1", "Set TEST_RUNNER_PEOPLEMAPS_EVIDENCE=1")
        // Location allowed, standing in Fremont.
        var app = launch(["--location-granted", "47.6505,-122.35"])
        let located = NSPredicate { _, _ in app.buttons["locate"].value as? String == "Found" }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: located, object: nil)], timeout: 10)
        shot("home-no-history")
        open(app, "Kerry Park", id: "node/693337509")
        let directions = app.buttons["directions"]
        let estimated = NSPredicate { _, _ in (directions.value as? String)?.contains(" minute") == true }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: estimated, object: nil)], timeout: 20)
        shot("place-card-near-estimate")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        shot("preview-current-location")
        app.buttons["close-preview"].tap()
        XCTAssertTrue(app.buttons["home-recent-node/693337509"].waitForExistence(timeout: 5))
        shot("home-recent")
        // Location off: the start stays empty.
        app.terminate()
        app = launch(["--keep-saved"])
        raise(app)
        app.buttons["home-recent-node/693337509"].tap()
        XCTAssertTrue(app.buttons["directions"].waitForExistence(timeout: 5))
        app.buttons["directions"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["needs-place"].waitForExistence(timeout: 10))
        shot("preview-empty-start")
    }
}
