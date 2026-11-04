import XCTest

/// Problem reports, the usage log and the detailed log (Docs/REPORTS.md section 11). Reports are shared as a file; nothing is sent.
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
        XCTAssertEqual(toggle.value as? String, "1", "The switch turns on")
        XCTAssertTrue(app.switches["usage-log-exact"].exists, "and the exact-places switch appears")
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

    /// Runs a short simulated trip from Kerry Park to Gas Works and ends it from the guidance screen.
    @MainActor private func driveBriefly(_ app: XCUIApplication) {
        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Gas Works")
        app.buttons["result-relation/1047789"].tap()
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        app.buttons["start-navigation"].tap()
        XCTAssertTrue(app.staticTexts["guidance-instruction"].waitForExistence(timeout: 20))
        sleep(5)   // a few simulated fixes
        app.buttons["end-navigation"].tap()
        XCTAssertTrue(app.buttons["close-preview"].waitForExistence(timeout: 10))
        app.buttons["close-preview"].tap()
    }

    /// The detailed log is off on a fresh install, and with it off a whole trip leaves no file.
    @MainActor func testDetailedLogIsOffByDefaultAndWritesNothingWhenOff() {
        let app = launch(location: Self.atKerryPark, extra: ["--simulate-route", "--drive-log-keep-short"])
        openAbout(app)
        let toggle = app.switches["drive-log-toggle"]
        scrollTo(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0", "Off by default")
        XCTAssertFalse(app.buttons["drive-log-clear"].exists)
        capture("drivelog-01-off")
        app.buttons["close-about"].tap()

        driveBriefly(app)

        openAbout(app)
        let footer = app.staticTexts["drive-log-footer"]
        scrollTo(footer, in: app)
        XCTAssertTrue(footer.label.contains("0 trips"), footer.label)
        XCTAssertFalse(app.buttons["drive-log-share"].exists, "Nothing to share")
        XCTAssertFalse(app.buttons["drive-log-clear"].exists)
        app.buttons["close-about"].tap()
    }

    /// With it on, a simulated trip writes a file that About counts, shares and clears.
    @MainActor func testDetailedLogOnKeepsASimulatedTripAndClears() {
        let app = launch(location: Self.atKerryPark, extra: ["--simulate-route", "--drive-log-keep-short"])
        openAbout(app)
        let toggle = app.switches["drive-log-toggle"]
        scrollTo(toggle, in: app)
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["close-about"].tap()

        driveBriefly(app)

        openAbout(app)
        let footer = app.staticTexts["drive-log-footer"]
        scrollTo(footer, in: app)
        XCTAssertTrue(footer.label.contains("1 trip,"), footer.label)
        XCTAssertFalse(footer.label.contains("Zero"), footer.label)
        XCTAssertTrue(app.buttons["drive-log-share"].exists)
        capture("drivelog-02-on-one-trip")
        let clear = app.buttons["drive-log-clear"]
        scrollTo(clear, in: app)
        clear.tap()
        let confirm = app.sheets.buttons["Clear"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let cleared = NSPredicate { _, _ in footer.label.contains("0 trips") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: cleared, object: nil)], timeout: 5), .completed, footer.label)
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

    // MARK: Manual recording

    @MainActor private func turnDetailedLogOn(_ app: XCUIApplication) {
        openAbout(app)
        let toggle = app.switches["drive-log-toggle"]
        scrollTo(toggle, in: app)
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["close-about"].tap()
    }

    /// With the detailed log off there is nothing to start; turning it on shows the record control.
    @MainActor func testRecordControlFollowsTheDetailedLogSwitch() {
        let app = launch(location: Self.atKerryPark)
        XCTAssertTrue(app.buttons["locate"].exists)
        XCTAssertFalse(app.buttons["record-start"].exists, "No control while the detailed log is off")
        openAbout(app)
        XCTAssertFalse(app.buttons["drive-record-toggle"].exists, "No Start in About while it is off")
        app.buttons["close-about"].tap()
        turnDetailedLogOn(app)
        XCTAssertTrue(app.buttons["record-start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["record-pill"].exists)
    }

    /// Start shows the pill with Stop on home; Stop writes a recording that About counts, and the control comes back.
    @MainActor func testManualRecordingStartsShowsThePillAndStopsWritingAFile() {
        let app = launch(location: Self.atKerryPark, extra: ["--drive-log-keep-short"])
        turnDetailedLogOn(app)
        app.buttons["record-start"].tap()
        let pill = app.descendants(matching: .any)["record-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["record-start"].exists, "The pill takes the control\u{2019}s place")
        sleep(3)
        capture("recording-01-pill-on-home")

        openAbout(app)
        let record = app.buttons["drive-record-toggle"]
        scrollTo(record, in: app)
        XCTAssertEqual(record.label, "Stop recording", "About shows the same state")
        app.buttons["close-about"].tap()

        app.buttons["record-stop"].tap()
        let gone = NSPredicate { _, _ in !pill.exists }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["record-start"].waitForExistence(timeout: 5))

        openAbout(app)
        let footer = app.staticTexts["drive-log-footer"]
        scrollTo(footer, in: app)
        XCTAssertTrue(footer.label.contains("0 trips, 1 recording,"), footer.label)
        XCTAssertTrue(app.buttons["drive-log-share"].exists)
        XCTAssertEqual(app.buttons["drive-record-toggle"].label, "Start recording")
        app.buttons["close-about"].tap()
    }

    /// Without --drive-log-keep-short, a recording under 3 minutes is deleted when it stops.
    @MainActor func testShortManualRecordingIsDeletedOnStop() {
        let app = launch(location: Self.atKerryPark)
        turnDetailedLogOn(app)
        app.buttons["record-start"].tap()
        XCTAssertTrue(app.buttons["record-stop"].waitForExistence(timeout: 10))
        sleep(2)
        app.buttons["record-stop"].tap()
        XCTAssertTrue(app.buttons["record-start"].waitForExistence(timeout: 5))
        openAbout(app)
        let footer = app.staticTexts["drive-log-footer"]
        scrollTo(footer, in: app)
        XCTAssertTrue(footer.label.contains("0 trips, "), footer.label)
        XCTAssertFalse(footer.label.contains("recording,"), footer.label)
        app.buttons["close-about"].tap()
    }
}
