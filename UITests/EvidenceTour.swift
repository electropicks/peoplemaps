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

    /// Every screen the glass and colour rules touch (Docs/DESIGN.md section 1). Run once per appearance;
    /// `TEST_RUNNER_PEOPLEMAPS_GLASS` adds launch arguments, such as `--glass-regular`.
    @MainActor func testGlassScreens() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PEOPLEMAPS_EVIDENCE"] == "1", "Set TEST_RUNNER_PEOPLEMAPS_EVIDENCE=1")
        let extra = ProcessInfo.processInfo.environment["PEOPLEMAPS_GLASS"].map { [$0] } ?? []
        let ballard = "47.6698,-122.3843"
        var app = launch(["--location-granted", ballard] + extra)
        Thread.sleep(forTimeInterval: 3)
        shot("home")
        let window = app.windows.firstMatch
        window.pinch(withScale: 2, velocity: 2)
        Thread.sleep(forTimeInterval: 2)
        shot("markers")
        app.buttons["search-field"].tap()
        XCTAssertTrue(app.textFields["search-input"].waitForExistence(timeout: 5))
        app.textFields["search-input"].typeText("coffee")
        shot("search")
        app.buttons["cancel-search-home"].tap()
        open(app, "Gas Works", id: "relation/1047789")
        waitForEstimate(app)
        shot("place")
        app.buttons["favourite"].tap()
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["start-navigation"].waitForExistence(timeout: 20))
        shot("preview")
        if app.buttons["route-calmer"].exists {
            app.buttons["route-fastest"].tap()
            shot("preview-fastest")
            app.buttons["route-calmer"].tap()
        }
        let top = app.buttons["start-navigation"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -6))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: -230)))
        shot("preview-raised")
        app.buttons["route-details"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["calm-bar"].waitForExistence(timeout: 5))
        shot("details")
        app.buttons["close-details"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["start-navigation"].waitForExistence(timeout: 10))
        shot("preview-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["close-preview"].waitForExistence(timeout: 10))
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
        app = launch(["--location-granted", ballard, "--simulate-route"] + extra)
        open(app, "Gas Works", id: "relation/1047789")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["start-navigation"].waitForExistence(timeout: 20))
        app.buttons["start-navigation"].tap()
        XCTAssertTrue(app.staticTexts["guidance-instruction"].waitForExistence(timeout: 10))
        shot("guidance")
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        shot("guidance-landscape")
        XCUIDevice.shared.orientation = .portrait
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

    /// A screenshot with the frames (in points) of the texts and buttons on screen and the screen's size, so a script can leave the
    /// text out when it measures the sheet's background.
    @MainActor private func shotWithFrames(_ app: XCUIApplication, _ name: String) {
        shot(name)
        var lines = ["screen \(Int(app.frame.width)) \(Int(app.frame.height))"]
        for type in [XCUIElement.ElementType.staticText, .button, .searchField, .textField] {
            for element in app.descendants(matching: type).allElementsBoundByIndex {
                let f = element.frame
                guard f.width > 0, f.height > 0, f.height < 400 else { continue }
                lines.append("\(type == .staticText ? "text" : "control") \(f.minX) \(f.minY) \(f.width) \(f.height) \(element.label.replacingOccurrences(of: "\n", with: " "))")
            }
        }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = name + ".frames"; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// The sheet on every screen it carries, over the map at the default view and zoomed into the labels, for the contrast
    /// measurement in Docs/DESIGN.md. Run once per appearance.
    @MainActor func testSheetLegibility() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PEOPLEMAPS_EVIDENCE"] == "1", "Set TEST_RUNNER_PEOPLEMAPS_EVIDENCE=1")
        let app = launch(["--location-granted", "47.6295,-122.3599"])
        Thread.sleep(forTimeInterval: 3)
        open(app, "Gas Works", id: "relation/1047789")
        waitForEstimate(app)
        shotWithFrames(app, "sheet-place")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["start-navigation"].waitForExistence(timeout: 20))
        shotWithFrames(app, "sheet-preview")
        app.buttons["close-preview"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
        shotWithFrames(app, "sheet-home-peek")
        raise(app)
        Thread.sleep(forTimeInterval: 1)
        shotWithFrames(app, "sheet-home-recents")
        // Pan the map so its labels (a neighbourhood's, then the lake's) pass under the sheet's body.
        let window = app.windows.firstMatch
        func pan(_ from: CGVector, _ to: CGVector) {
            window.coordinate(withNormalizedOffset: from).press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: to))
            Thread.sleep(forTimeInterval: 2)
        }
        pan(CGVector(dx: 0.5, dy: 0.15), CGVector(dx: 0.5, dy: 0.45))
        shotWithFrames(app, "sheet-home-recents-label")
        pan(CGVector(dx: 0.85, dy: 0.1), CGVector(dx: 0.3, dy: 0.2))
        shotWithFrames(app, "sheet-home-recents-label2")
        app.buttons["search-field"].tap()
        XCTAssertTrue(app.textFields["search-input"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        shotWithFrames(app, "sheet-search")
    }

    @MainActor func testAboutSwitches() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PEOPLEMAPS_EVIDENCE"] == "1", "Set TEST_RUNNER_PEOPLEMAPS_EVIDENCE=1")
        let app = launch([])
        raise(app)
        app.buttons["about"].tap()
        let toggle = app.switches["usage-log-toggle"]
        for _ in 0..<5 where !toggle.isHittable { app.collectionViews.firstMatch.swipeUp() }
        shot("about-switches-off")
        toggle.switches.firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        shot("about-switches-on")
    }
}
