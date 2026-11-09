import XCTest

/// Problem reports, the usage log and the detailed log (Docs/REPORTS.md section 11). Reports are shared as a file; nothing is sent.
final class ReportsUITests: PeoplemapsUITestCase {
    /// Settings, then one of its log pages.
    @MainActor private func openLog(_ app: XCUIApplication, _ row: String) {
        openSettings(app)
        openSettingsPage(app, row)
    }
    /// What a log's page says is kept: "Kept on this phone, 1 trip".
    @MainActor private func kept(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    /// The row says "Clear usage log"; the confirmation's button is the only plain "Clear".
    @MainActor private func confirmClear(_ app: XCUIApplication) {
        let confirm = app.buttons["Clear"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<5 where !element.isHittable { app.collectionViews.firstMatch.swipeUp() }
    }

    @MainActor func testReportFromSettingsIsKeptAndShareable() {
        let app = launchHome()
        openSettings(app)
        XCTAssertFalse(app.buttons["saved-reports"].exists, "No Saved reports row until there is one")
        app.buttons["report-problem-about"].tap()
        let note = app.textFields["report-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(note.placeholderValue, "What happened, or what you\u{2019}d prefer")
        note.tap(); note.typeText("Wrong left on 45th")
        XCTAssertTrue(app.buttons["share-report"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["report-exact"].value as? String, "0", "Exact locations start off")
        app.buttons["close-report"].tap()
        XCTAssertFalse(app.textFields["report-note"].waitForExistence(timeout: 1))
        // The report waits on its own page until swiped away.
        XCTAssertTrue(rowText(app.buttons["saved-reports"]).contains("1"), rowText(app.buttons["saved-reports"]))
        openSettingsPage(app, "saved-reports")
        let saved = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Wrong left on 45th'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), app.debugDescription)
        saved.tap()
        XCTAssertTrue(app.textFields["report-note"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["report-note"].value as? String, "Wrong left on 45th")
        app.buttons["close-report"].tap()
    }

    @MainActor func testIncludedDetailsAreShownAndFollowTheToggle() {
        let app = launchHome(location: Self.atKerryPark)
        openSettings(app)
        app.buttons["report-problem-about"].tap()
        let included = app.buttons["What\u{2019}s included"]
        XCTAssertTrue(included.waitForExistence(timeout: 5))
        included.tap()
        let json = app.descendants(matching: .any)["report-json"]
        XCTAssertTrue(json.waitForExistence(timeout: 5))
        XCTAssertTrue(json.label.contains("\"exactLocations\" : false"), json.label)
        XCTAssertTrue(json.label.contains("\"screen\" : \"settings, over home\""), json.label)
        XCTAssertTrue(json.label.contains("\"events\""), "The recent app events are listed")
        XCTAssertTrue(json.label.contains("map style loaded"), json.label)
        capture("reports-01-composer")
        app.switches["report-exact"].switches.firstMatch.tap()
        let exactOn = NSPredicate { _, _ in json.label.contains("\"exactLocations\" : true") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: exactOn, object: nil)], timeout: 5), .completed)
        app.buttons["close-report"].tap()
    }

    @MainActor func testUsageLogIsOffUntilTurnedOnThenKeepsATripAndClears() {
        let app = launchHome(location: Self.atKerryPark, extra: ["--simulate-route"])
        openLog(app, "usage-log")
        let toggle = app.switches["usage-log-toggle"]
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.value as? String, "0", "Off by default")
        XCTAssertFalse(app.buttons["usage-log-clear"].exists)
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1", "The switch turns on")
        XCTAssertTrue(app.switches["usage-log-exact"].exists, "and the exact-places switch appears")
        capture("reports-02-usage-log")
        app.buttons["close-settings"].tap()

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

        openSettings(app)
        XCTAssertTrue(rowText(app.buttons["usage-log"]).contains("On \u{00B7} 1 trip"), rowText(app.buttons["usage-log"]))
        openSettingsPage(app, "saved-reports")
        let saved = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Marked moment, no words yet'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "The mark waits in the list")
        backToSettings(app)
        openSettingsPage(app, "usage-log")
        let summary = kept(app, "usage-log-summary")
        XCTAssertTrue(rowText(summary).contains("1 trip"), rowText(summary))
        let clear = app.buttons["usage-log-clear"]
        scrollTo(clear, in: app)
        clear.tap()
        confirmClear(app)
        let cleared = NSPredicate { _, _ in (summary.label + " " + (summary.value as? String ?? "")).contains("0 trips") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: cleared, object: nil)], timeout: 5), .completed, rowText(summary))
        XCTAssertFalse(clear.exists)
        app.buttons["close-settings"].tap()
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
        let app = launchHome(location: Self.atKerryPark, extra: ["--simulate-route", "--drive-log-keep-short"])
        openLog(app, "drive-log")
        let toggle = app.switches["drive-log-toggle"]
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.value as? String, "0", "Off by default")
        XCTAssertFalse(app.buttons["drive-log-clear"].exists)
        capture("drivelog-01-off")
        app.buttons["close-settings"].tap()

        driveBriefly(app)

        openSettings(app)
        XCTAssertTrue(rowText(app.buttons["drive-log"]).hasSuffix("Off"), rowText(app.buttons["drive-log"]))
        openSettingsPage(app, "drive-log")
        let summary = rowText(kept(app, "drive-log-summary"))
        XCTAssertTrue(summary.hasSuffix("0 trips"), summary)
        XCTAssertFalse(app.buttons["drive-log-share"].exists, "Nothing to share")
        XCTAssertFalse(app.buttons["drive-log-clear"].exists)
        app.buttons["close-settings"].tap()
    }

    /// With it on, a simulated trip writes a file that Settings counts, shares and clears.
    @MainActor func testDetailedLogOnKeepsASimulatedTripAndClears() {
        let app = launchHome(location: Self.atKerryPark, extra: ["--simulate-route", "--drive-log-keep-short"])
        turnDetailedLogOn(app)

        driveBriefly(app)

        openSettings(app)
        let row = rowText(app.buttons["drive-log"])
        XCTAssertTrue(row.hasSuffix("On \u{00B7} 1 trip"), row)
        XCTAssertFalse(row.contains("Zero"), row)
        openSettingsPage(app, "drive-log")
        let summary = kept(app, "drive-log-summary")
        XCTAssertTrue(rowText(summary).contains("1 trip, "), rowText(summary))
        XCTAssertFalse(rowText(summary).contains("Zero"), rowText(summary))
        XCTAssertTrue(app.buttons["drive-log-share"].exists)
        capture("drivelog-02-on-one-trip")
        let clear = app.buttons["drive-log-clear"]
        scrollTo(clear, in: app)
        clear.tap()
        confirmClear(app)
        let cleared = NSPredicate { _, _ in (summary.label + " " + (summary.value as? String ?? "")).contains("0 trips") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: cleared, object: nil)], timeout: 5), .completed, rowText(summary))
        XCTAssertFalse(clear.exists)
        app.buttons["close-settings"].tap()
    }

    /// Shares a log from its page in Settings after one simulated trip; the tap must bring up the share sheet.
    @MainActor @discardableResult private func shareLogsAfterATrip(_ id: String) -> XCUIApplication {
        let app = launchHome(location: Self.atKerryPark, extra: ["--simulate-route", "--drive-log-keep-short"])
        openSettings(app)
        for log in ["usage-log", "drive-log"] {
            openSettingsPage(app, log)
            let toggle = app.switches["\(log)-toggle"]
            toggle.switches.firstMatch.tap()
            XCTAssertEqual(toggle.value as? String, "1")
            backToSettings(app)
        }
        app.buttons["close-settings"].tap()
        driveBriefly(app)
        openLog(app, String(id.dropLast("-share".count)))
        let share = app.buttons[id]
        scrollTo(share, in: app)
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        // Clear of the home indicator, where a tap at the row's centre would not reach the button.
        for _ in 0..<5 where share.frame.maxY > app.frame.height - 120 { app.collectionViews.firstMatch.swipeUp() }
        share.tap()
        let sheet = app.otherElements["ActivityListView"]
        let copy = app.buttons["Copy"]
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !sheet.exists && !copy.exists { usleep(200_000) }
        capture("share-\(id)")
        XCTAssertTrue(sheet.exists || copy.exists, "\(id) brings up the share sheet\n\(app.debugDescription)")
        return app
    }

    @MainActor func testUsageLogShareOpensTheShareSheet() { shareLogsAfterATrip("usage-log-share") }
    @MainActor func testDetailedLogShareOpensTheShareSheet() { shareLogsAfterATrip("drive-log-share") }

    /// Shares a log, closes the share sheet, then clears the log: Clear must still ask, and confirming must empty the log.
    @MainActor private func clearAfterSharing(_ log: String) {
        let app = shareLogsAfterATrip("\(log)-share")
        let sheet = app.otherElements["ActivityListView"]
        let close = app.buttons["Close"]
        if close.exists { close.tap() } else {
            let top = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
            top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 700)))
        }
        let gone = NSPredicate { _, _ in !sheet.exists && !app.buttons["Copy"].exists }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 10), .completed, "The share sheet closes")
        let clear = app.buttons["\(log)-clear"]
        scrollTo(clear, in: app)
        XCTAssertTrue(clear.isHittable, app.debugDescription)
        clear.tap()
        let confirm = app.buttons["Clear"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Clear asks first, also after a share\n\(app.debugDescription)")
        capture("clear-after-share-\(log)")
        confirm.tap()
        let summary = kept(app, "\(log)-summary")
        let cleared = NSPredicate { _, _ in (summary.label + " " + (summary.value as? String ?? "")).contains("0 trips") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: cleared, object: nil)], timeout: 5), .completed, rowText(summary))
        XCTAssertFalse(clear.exists, "Nothing left to clear")
        XCTAssertFalse(app.buttons["\(log)-share"].exists, "or to share")
    }
    @MainActor func testUsageLogClearsAfterSharing() { clearAfterSharing("usage-log") }
    @MainActor func testDetailedLogClearsAfterSharing() { clearAfterSharing("drive-log") }

    /// A marked moment can get words after the trip, in the normal arrival card and in the scrolling one at AX5.
    @MainActor private func markThenArrive(extra: [String]) -> XCUIApplication {
        let app = launchHome(location: Self.atKerryPark, extra: ["--simulate-route", "--fast-simulation"] + extra)
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
        openLog(app, "drive-log")
        let toggle = app.switches["drive-log-toggle"]
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["close-settings"].tap()
    }

    /// With the detailed log off there is nothing to start; turning it on shows the record control.
    @MainActor func testRecordControlFollowsTheDetailedLogSwitch() {
        let app = launchHome(location: Self.atKerryPark)
        XCTAssertTrue(app.buttons["locate"].exists)
        XCTAssertFalse(app.buttons["record-start"].exists, "No control while the detailed log is off")
        openSettings(app)
        XCTAssertFalse(app.buttons["drive-record-toggle"].exists, "No Start in Settings while it is off")
        app.buttons["close-settings"].tap()
        turnDetailedLogOn(app)
        XCTAssertTrue(app.buttons["record-start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["record-pill"].exists)
    }

    /// Start shows the pill with Stop on home; Stop writes a recording that Settings counts, and the control comes back.
    @MainActor func testManualRecordingStartsShowsThePillAndStopsWritingAFile() {
        let app = launchHome(location: Self.atKerryPark, extra: ["--drive-log-keep-short"])
        turnDetailedLogOn(app)
        app.buttons["record-start"].tap()
        let pill = app.descendants(matching: .any)["record-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["record-start"].exists, "The pill takes the control\u{2019}s place")
        sleep(3)
        capture("recording-01-pill-on-home")

        openSettings(app)
        let record = app.buttons["drive-record-toggle"]
        XCTAssertTrue(record.isHittable, "On the root list, with no scrolling")
        XCTAssertEqual(record.label, "Stop recording", "Settings shows the same state")
        app.buttons["close-settings"].tap()

        app.buttons["record-stop"].tap()
        let gone = NSPredicate { _, _ in !pill.exists }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["record-start"].waitForExistence(timeout: 5))

        openSettings(app)
        XCTAssertEqual(app.buttons["drive-record-toggle"].label, "Start recording")
        XCTAssertTrue(rowText(app.buttons["drive-log"]).hasSuffix("On \u{00B7} 1 recording"), rowText(app.buttons["drive-log"]))
        openSettingsPage(app, "drive-log")
        let summary = rowText(kept(app, "drive-log-summary"))
        XCTAssertTrue(summary.contains("0 trips, 1 recording, "), summary)
        XCTAssertTrue(app.buttons["drive-log-share"].exists)
        app.buttons["close-settings"].tap()
    }

    /// Without --drive-log-keep-short, a recording under 3 minutes is deleted when it stops.
    @MainActor func testShortManualRecordingIsDeletedOnStop() {
        let app = launchHome(location: Self.atKerryPark)
        turnDetailedLogOn(app)
        app.buttons["record-start"].tap()
        XCTAssertTrue(app.buttons["record-stop"].waitForExistence(timeout: 10))
        sleep(2)
        app.buttons["record-stop"].tap()
        XCTAssertTrue(app.buttons["record-start"].waitForExistence(timeout: 5))
        openLog(app, "drive-log")
        let summary = rowText(kept(app, "drive-log-summary"))
        XCTAssertTrue(summary.contains("0 trips"), summary)
        XCTAssertFalse(summary.contains("recording"), summary)
        app.buttons["close-settings"].tap()
    }
}
