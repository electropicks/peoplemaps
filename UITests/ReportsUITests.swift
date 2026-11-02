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
    /// About sits below the fit stop, so the home sheet comes up first.
    @MainActor private func openAbout(_ app: XCUIApplication) {
        let about = app.buttons["about"]
        if !about.isHittable {
            let start = app.buttons["search-field"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -300)))
        }
        about.tap()
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
        openAbout(app)
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
        openAbout(app)
        scrollTo(app.buttons["report-problem-about"], in: app)
        app.buttons["report-problem-about"].tap()
        let included = app.buttons["What\u{2019}s included"]
        XCTAssertTrue(included.waitForExistence(timeout: 5))
        included.tap()
        let json = app.descendants(matching: .any)["report-json"]
        XCTAssertTrue(json.waitForExistence(timeout: 5))
        XCTAssertTrue(json.label.contains("\"exactLocations\" : false"), json.label)
        XCTAssertTrue(json.label.contains("\"screen\" : \"about, over home\""), json.label)
        XCTAssertTrue(json.label.contains("\"events\""), "The recent app events are listed")
        XCTAssertTrue(json.label.contains("map style loaded"), json.label)
        capture("reports-01-composer")
        app.switches["report-exact"].switches.firstMatch.tap()
        let exactOn = NSPredicate { _, _ in json.label.contains("\"exactLocations\" : true") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: exactOn, object: nil)], timeout: 5), .completed)
        app.buttons["close-report"].tap()
    }

    @MainActor func testUsageLogIsOffUntilTurnedOnThenKeepsATripAndClears() {
        let app = launch(location: Self.atKerryPark, extra: ["--simulate-route"])
        openAbout(app)
        let toggle = app.switches["usage-log-toggle"]
        scrollTo(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0", "Off by default")
        XCTAssertFalse(app.buttons["usage-log-clear"].exists)
        toggle.switches.firstMatch.tap()
        capture("reports-02-about-usage-log")
        app.buttons["close-about"].tap()

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

        openAbout(app)
        let saved = app.staticTexts["Marked moment, no words yet"]
        scrollTo(saved, in: app)
        XCTAssertTrue(saved.exists, "The mark waits in the list")
        let clear = app.buttons["usage-log-clear"]
        scrollTo(clear, in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '1 trip kept'")).firstMatch.exists)
        clear.tap()
        let confirm = app.sheets.buttons["Clear"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '0 trips kept'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(clear.exists)
        app.buttons["close-about"].tap()
    }

    /// A marked moment can get words after the trip, in the normal arrival card and in the scrolling one at AX5.
    @MainActor private func markThenArrive(extra: [String]) -> XCUIApplication {
        let app = launch(location: Self.atKerryPark, extra: ["--simulate-route", "--fast-simulation"] + extra)
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
        XCTAssertTrue(app.staticTexts["guidance-arrived"].waitForExistence(timeout: 150), "Never arrived")
        return app
    }
    @MainActor func testAddWordsShowsOnTheArrivalCard() {
        let app = markThenArrive(extra: [])
        let add = app.buttons["add-words"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isHittable)
        add.tap()
        XCTAssertTrue(app.textFields["report-note"].waitForExistence(timeout: 5))
        app.buttons["close-report"].tap()
    }
    @MainActor func testAddWordsIsReachableAtAX5() {
        let app = markThenArrive(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let add = app.buttons["add-words"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        let card = app.scrollViews.containing(.button, identifier: "add-words").firstMatch
        for _ in 0..<5 where !add.isHittable { card.swipeUp() }
        XCTAssertTrue(add.isHittable, "Add words is out of reach at AX5")
        XCTAssertTrue(app.buttons["done-navigation"].isHittable, "Done stays pinned")
        capture("reports-04-add-words-ax5")
    }
}
