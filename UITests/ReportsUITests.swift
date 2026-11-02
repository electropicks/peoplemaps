import XCTest

/// Problem reports and the usage log (Docs/REPORTS.md section 11). Reports are shared as a file; nothing is sent.
final class ReportsUITests: XCTestCase {
    private static let atKerryPark = "47.6295,-122.3599"

    @MainActor private func launch(location: String? = nil, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (location.map { ["--location-granted", $0] } ?? []) + extra
        app.launch()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 20))
        return app
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<5 where !element.isHittable { app.collectionViews.firstMatch.swipeUp() }
    }

    @MainActor func testReportFromAboutIsKeptAndShareable() {
        let app = launch()
        app.buttons["about"].tap()
        scrollTo(app.buttons["report-problem-about"], in: app)
        app.buttons["report-problem-about"].tap()
        let note = app.textFields["report-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(note.placeholderValue, "What happened, or what you\u{2019}d prefer")
        note.tap(); note.typeText("Wrong left on 45th")
        XCTAssertTrue(app.buttons["share-report"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["report-exact"].value as? String, "0", "Exact locations start off")
        app.buttons["close-report"].tap()
        XCTAssertFalse(app.textFields["report-note"].waitForExistence(timeout: 1))
        // The report waits in the About list until swiped away.
        let saved = app.staticTexts["Wrong left on 45th"]
        scrollTo(saved, in: app)
        XCTAssertTrue(saved.exists)
        saved.tap()
        XCTAssertTrue(app.textFields["report-note"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["report-note"].value as? String, "Wrong left on 45th")
        app.buttons["close-report"].tap()
    }

    @MainActor func testIncludedDetailsAreShownAndFollowTheToggle() {
        let app = launch(location: Self.atKerryPark)
        app.buttons["about"].tap()
        scrollTo(app.buttons["report-problem-about"], in: app)
        app.buttons["report-problem-about"].tap()
        let included = app.buttons["What\u{2019}s included"]
        XCTAssertTrue(included.waitForExistence(timeout: 5))
        included.tap()
        let json = app.descendants(matching: .any)["report-json"]
        XCTAssertTrue(json.waitForExistence(timeout: 5))
        XCTAssertTrue(json.label.contains("\"exactLocations\" : false"), json.label)
        XCTAssertTrue(json.label.contains("\"screen\" : \"about, over home\""), json.label)
        capture("reports-01-composer")
        app.switches["report-exact"].switches.firstMatch.tap()
        let exactOn = NSPredicate { _, _ in json.label.contains("\"exactLocations\" : true") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: exactOn, object: nil)], timeout: 5), .completed)
        app.buttons["close-report"].tap()
    }

    @MainActor func testUsageLogIsOffUntilTurnedOnThenKeepsATripAndClears() {
        let app = launch(location: Self.atKerryPark, extra: ["--simulate-route"])
        app.buttons["about"].tap()
        let toggle = app.switches["usage-log-toggle"]
        scrollTo(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0", "Off by default")
        XCTAssertFalse(app.buttons["usage-log-clear"].exists)
        toggle.switches.firstMatch.tap()
        capture("reports-02-about-usage-log")
        app.buttons["close-about"].tap()
        defer { setUsageLog(app, on: false) }

        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Gas Works")
        app.buttons["result-relation/1047789"].tap()
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        app.buttons["start-navigation"].tap()
        XCTAssertTrue(app.staticTexts["guidance-instruction"].waitForExistence(timeout: 20))
        let mark = app.buttons["mark-moment"]
        XCTAssertTrue(mark.waitForExistence(timeout: 10))
        mark.tap()
        XCTAssertTrue(app.buttons["Marked"].waitForExistence(timeout: 2), "A light confirmation")
        XCTAssertFalse(app.textFields["report-note"].exists, "Marking opens no sheet")
        capture("reports-03-marked")
        app.buttons["end-navigation"].tap()
        XCTAssertTrue(app.buttons["close-preview"].waitForExistence(timeout: 10))
        app.buttons["close-preview"].tap()

        app.buttons["about"].tap()
        let saved = app.staticTexts["Marked moment, no words yet"]
        scrollTo(saved, in: app)
        XCTAssertTrue(saved.exists, "The mark waits in the list")
        let clear = app.buttons["usage-log-clear"]
        scrollTo(clear, in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '1 trip kept'")).firstMatch.exists)
        clear.tap()
        app.buttons["Clear"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '0 trips kept'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(clear.exists)
    }

    @MainActor private func setUsageLog(_ app: XCUIApplication, on: Bool) {
        if !app.buttons["about"].exists { return }
        app.buttons["about"].tap()
        let toggle = app.switches["usage-log-toggle"]
        scrollTo(toggle, in: app)
        if (toggle.value as? String) == (on ? "0" : "1") { toggle.switches.firstMatch.tap() }
        app.buttons["close-about"].tap()
    }
}
