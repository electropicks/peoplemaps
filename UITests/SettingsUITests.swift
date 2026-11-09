import XCTest

/// Settings, from the home sheet: its root list, the pages behind it, and the two log switches (Docs/DESIGN.md section 4.9).
final class SettingsUITests: PeoplemapsUITestCase {
    /// The root list is four sections of rows that fit on one screen at the default text size, over the app's version.
    @MainActor func testRootShowsTheFourSectionsOnOneScreen() {
        let app = launchHome()
        openSettings(app)
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        for header in ["Map", "Trip logs", "Feedback", "About"] {
            XCTAssertTrue(app.staticTexts[header].exists, "\(header) section")
        }
        let current = rowText(app.descendants(matching: .any)["region-current"])
        XCTAssertTrue(current.contains("Seattle"), current)
        for row in ["usage-log", "drive-log", "report-problem-about", "calmer-means", "map-data", "acknowledgements"] {
            XCTAssertTrue(app.buttons[row].isHittable, "\(row) shows without scrolling")
        }
        XCTAssertTrue(rowText(app.buttons["usage-log"]).hasSuffix("Off"), rowText(app.buttons["usage-log"]))
        XCTAssertTrue(rowText(app.buttons["drive-log"]).hasSuffix("Off"), rowText(app.buttons["drive-log"]))
        XCTAssertFalse(app.buttons["saved-reports"].exists, "No Saved reports row until there is one")
        let version = app.staticTexts["app-version"]
        XCTAssertTrue(version.isHittable, "The version shows without scrolling")
        XCTAssertTrue(version.label.hasPrefix("PeopleMaps 0.1.0"), version.label)
        // No paragraph on the root: nothing there runs past two sentences.
        let prose = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.components(separatedBy: ". ").count > 2 }
        XCTAssertEqual(prose, [], "Prose on the root list")
        capture("settings-root", app: app)
        app.buttons["close-settings"].tap()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
    }

    /// Each log's switch is two taps from Settings: its row, then the switch. The root row says what the switch says.
    @MainActor func testEachLogSwitchIsTwoTapsFromSettingsAndFlips() {
        let app = launchHome()
        openSettings(app)
        for log in ["usage-log", "drive-log"] {
            app.buttons[log].tap()
            let toggle = app.switches["\(log)-toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), log)
            XCTAssertTrue(toggle.isHittable, "\(log): the switch shows without scrolling")
            XCTAssertEqual(toggle.value as? String, "0", "\(log) is off by default")
            toggle.switches.firstMatch.tap()
            XCTAssertEqual(toggle.value as? String, "1", "\(log) turns on")
            capture("settings-\(log)-on", app: app)
            backToSettings(app)
            XCTAssertTrue(rowText(app.buttons[log]).hasSuffix("On"), rowText(app.buttons[log]))
        }
        app.buttons["usage-log"].tap()
        XCTAssertTrue(app.switches["usage-log-exact"].waitForExistence(timeout: 5), "Exact places shows while the usage log is on")
        let toggle = app.switches["usage-log-toggle"]
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0", "and off again")
        XCTAssertFalse(app.switches["usage-log-exact"].exists)
        backToSettings(app)
        XCTAssertTrue(rowText(app.buttons["usage-log"]).hasSuffix("Off"), rowText(app.buttons["usage-log"]))
    }

    /// Start recording is on the root list while the detailed log is on, and only then.
    @MainActor func testStartRecordingIsOnTheRootOnlyWhileTheDetailedLogIsOn() {
        let app = launchHome(location: Self.atKerryPark)
        openSettings(app)
        let record = app.buttons["drive-record-toggle"]
        XCTAssertFalse(record.exists, "No Start recording while the detailed log is off")
        openSettingsPage(app, "drive-log")
        let toggle = app.switches["drive-log-toggle"]
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(record.exists, "Not on the log's own page")
        backToSettings(app)
        XCTAssertTrue(record.waitForExistence(timeout: 5), "On the root list once the log is on")
        XCTAssertTrue(record.isHittable)
        XCTAssertEqual(record.label, "Start recording")
        capture("settings-root-detailed-log-on", app: app)
        openSettingsPage(app, "drive-log")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        backToSettings(app)
        XCTAssertFalse(record.exists, "Gone again with the log off")
    }

    /// With location off, Start recording says why nothing started, next to the row.
    @MainActor func testStartRecordingSaysWhenLocationIsOff() {
        let app = launchHome()
        openSettings(app)
        openSettingsPage(app, "drive-log")
        app.switches["drive-log-toggle"].switches.firstMatch.tap()
        backToSettings(app)
        let record = app.buttons["drive-record-toggle"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        let denied = app.staticTexts["drive-record-denied"]
        XCTAssertTrue(denied.waitForExistence(timeout: 5))
        XCTAssertTrue(denied.label.hasPrefix("Location is off for PeopleMaps, so the recording did not start."), denied.label)
        XCTAssertEqual(record.label, "Start recording")
    }

    /// What calmer means keeps its honest sentence, a row per mode; the log pages keep what they said about the logs.
    @MainActor func testPagesKeepTheirWords() {
        let app = launchHome()
        openSettings(app)
        func shows(_ text: String) -> Bool { app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists }
        openSettingsPage(app, "calmer-means")
        XCTAssertTrue(app.navigationBars["What calmer means"].exists)
        XCTAssertTrue(shows("These are transparent preferences, not safety ratings. Times and stress are estimates, with no live traffic."))
        for mode in ["Driving", "Cycling", "Walking"] { XCTAssertTrue(shows(mode), mode) }
        capture("settings-calmer-means", app: app)
        backToSettings(app)
        openSettingsPage(app, "map-data")
        XCTAssertTrue(shows("OpenStreetMap contributors"))
        XCTAssertTrue(shows("USGS"))
        XCTAssertTrue(shows("2026"), "The data's date")
        capture("settings-map-data", app: app)
        backToSettings(app)
        openSettingsPage(app, "drive-log")
        let list = app.collectionViews.firstMatch
        for text in ["every location fix with its speed and accuracy", "iOS shows its blue location indicator", "unless you share the files", "under 3 minutes"] {
            for _ in 0..<4 where !shows(text) { list.swipeUp() }
            XCTAssertTrue(shows(text), text)
        }
        XCTAssertTrue(app.descendants(matching: .any)["drive-log-footer"].exists)
        for label in app.staticTexts.allElementsBoundByIndex.map(\.label) { XCTAssertFalse(label.contains("Zero"), label) }
    }
}
