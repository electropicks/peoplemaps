import XCTest

/// A paced walk through the main workflows for screen recordings, with real animations (no `--ui-testing`).
/// Skipped unless the runner sets PEOPLEMAPS_DEMO=1 (`TEST_RUNNER_PEOPLEMAPS_DEMO=1 xcodebuild test ...`).
final class DemoTour: XCTestCase {
    @MainActor private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
    @MainActor private func type(_ text: String, into field: XCUIElement) {
        for character in text { field.typeText(String(character)); pause(0.08) }
    }
    @MainActor private func search(_ text: String, in app: XCUIApplication) {
        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        pause(0.6); type(text, into: field); pause(1.5)
    }

    @MainActor func testDemoTour() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PEOPLEMAPS_DEMO"] == "1", "Recording only")
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--simulate-route"]
        app.launch()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 20))
        pause(2.5)

        // 1. Find a place, save it, compare the calmer drive with the fastest, then follow it.
        search("Gas Works", in: app)
        let park = app.buttons["result-relation/1047789"]
        XCTAssertTrue(park.waitForExistence(timeout: 5)); park.tap(); pause(2)
        app.buttons["favourite"].tap(); pause(1.5)
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20)); pause(3)
        app.buttons["route-fastest"].tap(); pause(2)
        if app.buttons["route-calmer"].exists { app.buttons["route-calmer"].tap(); pause(2) }
        app.buttons["route-details"].tap(); pause(2.5)
        app.collectionViews.firstMatch.swipeUp(); pause(2)
        app.buttons["close-details"].tap(); pause(1.5)
        app.buttons["start-navigation"].tap()
        XCTAssertTrue(app.staticTexts["guidance-instruction"].waitForExistence(timeout: 10)); pause(22)
        app.buttons["guidance-overview"].tap(); pause(3)
        app.buttons["end-navigation"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10)); pause(1.5)

        // 2. Same trip by bike and on foot.
        app.buttons["Cycle"].tap(); pause(3)
        app.buttons["Walk"].tap(); pause(3)
        app.buttons["close-preview"].tap(); pause(2)

        // 3. Search an address and route to it.
        search("3400 Fremont Ave N", in: app)
        let address = app.buttons["result-node/2652117839"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); pause(2)
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20)); pause(3)
        app.buttons["close-preview"].tap(); pause(2)

        // 4. Drop a pin on the map; the saved favourite waits on home.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.3)).press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["Dropped pin"].waitForExistence(timeout: 5)); pause(3)
        app.buttons["close-place"].tap(); pause(3)

        // 5. Nothing found: hand off to Apple Maps (not followed).
        search("Pike Place Market", in: app); pause(2)
        app.buttons["cancel-search-home"].tap(); pause(2)
    }
}
