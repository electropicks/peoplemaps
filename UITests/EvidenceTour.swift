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

    @MainActor func testEvidence() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PEOPLEMAPS_EVIDENCE"] == "1", "Set TEST_RUNNER_PEOPLEMAPS_EVIDENCE=1")
        // Location allowed, standing in Fremont.
        var app = launch(["--location-granted", "47.6505,-122.35"])
        let located = NSPredicate { _, _ in app.buttons["recenter"].label == "Centre on your location" }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: located, object: nil)], timeout: 10)
        shot("home-no-history")
        open(app, "Kerry Park", id: "node/693337509")
        XCTAssertTrue(app.staticTexts["place-estimate"].waitForExistence(timeout: 20))
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
        app.buttons["home-recent-node/693337509"].tap()
        XCTAssertTrue(app.buttons["directions"].waitForExistence(timeout: 5))
        app.buttons["directions"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["needs-place"].waitForExistence(timeout: 10))
        shot("preview-empty-start")
    }
}
