import XCTest
import CoreLocation

final class RoutePreviewUITests: PeoplemapsUITestCase {
    @MainActor func testDrivingCyclingBudgetAndExplanation() {
        let app = launch()
        capture("01-driving-comparison", app: app)
        // Drive, Cycle, Walk from left to right.
        let x = ["Drive", "Cycle", "Walk"].map { app.buttons[$0].frame.midX }
        XCTAssertEqual(x, x.sorted(), "Mode order")
        XCTAssertTrue(app.buttons["Drive"].isSelected)
        raisePreview(app)
        XCTAssertTrue(app.buttons["extra-time-menu"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["extra-time-menu"].value as? String, "10 min", "The default leans to calm")
        // Which of the two the data gives depends on the region: the small fixture has routes that gain too little for their
        // time (so this one must not be called the calmest), a full city usually has a calmer drive to offer.
        let finding = app.descendants(matching: .any)["no-alternative"]
        let calmer = app.buttons["route-calmer"]
        let settled = NSPredicate { _, _ in finding.exists || calmer.exists }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 10), .completed)
        if finding.exists {
            XCTAssertTrue(finding.label.contains("Best balance we found"), finding.label)
            XCTAssertTrue(finding.label.contains("estimates"), finding.label)
            XCTAssertFalse(finding.label.localizedCaseInsensitiveContains("calmest"), finding.label)
            XCTAssertFalse(finding.label.localizedCaseInsensitiveContains("safe"), finding.label)
        } else {
            XCTAssertFalse(calmer.label.localizedCaseInsensitiveContains("safe"), calmer.label)
        }
        setExtraTime(app, "None")
        let unchecked = NSPredicate { _, _ in finding.exists && finding.label.contains("nothing else was checked") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: unchecked, object: nil)], timeout: 10), .completed, "None says it did not look")
        app.buttons["route-details"].tap()
        XCTAssertTrue(app.navigationBars["Behind the routes"].waitForExistence(timeout: 5))
        // The calm estimate comes first, so this is further down the list.
        let oneRoute = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '1 distinct route was found'")).firstMatch
        for _ in 0..<4 where !oneRoute.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(oneRoute.exists, "One route reads properly")
        capture("02-none-details", app: app)
        app.buttons["close-details"].tap()
        setExtraTime(app, "5 min")
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        app.buttons["Cycle"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        capture("02-cycling-comparison", app: app)
        app.buttons["route-details"].tap()
        XCTAssertTrue(app.navigationBars["Behind the routes"].waitForExistence(timeout: 5))
        let climbing = app.staticTexts["Climbing"]
        for _ in 0..<4 where !climbing.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(climbing.exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' km' OR label ENDSWITH ' m'")).count, 0, "Imperial units only")
        capture("03-route-evidence", app: app)
        app.buttons["close-details"].tap()
        app.buttons["Drive"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
    }
    @MainActor func testCancelAndResumeComparison() {
        let app = launch(slow: true)
        app.buttons["Cycle"].tap()
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
            app.buttons["Cycle"].tap()
            setExtraTime(app, "2 min")
            app.buttons["Drive"].tap()
            setExtraTime(app, "10 min")
            app.buttons["swap"].tap()
            XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 12))
        }
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Current location"))
        XCTAssertTrue(app.buttons["choose-destination"].label.contains("Gas Works"))
        XCTAssertEqual(app.buttons["extra-time-menu"].value as? String, "10 min")
        XCTAssertTrue(app.buttons["Drive"].isSelected)
        app.buttons["recenter"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].exists)
    }
    @MainActor func testCalmerMeansPreferencesSetAndReset() {
        let app = launch()
        let row = app.buttons["route-preferences"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "Calmer means, Default")
        row.tap()
        XCTAssertTrue(app.navigationBars["Calmer means"].waitForExistence(timeout: 5))
        let hills = app.segmentedControls["preference-hills"]
        scrollPreferences(to: hills, in: app)
        hills.buttons["Avoid"].tap()
        XCTAssertTrue(hills.buttons["Avoid"].isSelected)
        capture("17-route-preferences", app: app)
        app.buttons["preferences-done"].tap()
        XCTAssertTrue(app.buttons["preferences-done"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(row.label, "Calmer means, Custom")
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 12), "The comparison reruns with the new preference")
        row.tap()
        XCTAssertTrue(app.navigationBars["Calmer means"].waitForExistence(timeout: 5))
        let reset = app.buttons["reset-preferences"]
        scrollPreferences(to: reset, in: app)
        XCTAssertTrue(reset.isEnabled)
        reset.tap()
        XCTAssertFalse(reset.isEnabled)
        app.buttons["preferences-done"].tap()
        XCTAssertTrue(app.buttons["preferences-done"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(row.label, "Calmer means, Default")
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 12))
    }
    /// At the default size the routes, Start and Why this route are all in reach without scrolling.
    @MainActor func testPreviewShowsRoutesStartAndWhyWithoutScrolling() {
        let app = launchHome(location: Self.atBallardLibrary)
        showGasWorksRoutes(app)
        XCTAssertTrue(app.buttons["route-calmer"].waitForExistence(timeout: 10))
        let start = app.buttons["start-navigation"], why = app.buttons["route-details"], fastest = app.buttons["route-fastest"]
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(why.isHittable)
        XCTAssertLessThanOrEqual(fastest.frame.maxY, start.frame.minY + 1, "The last route isn't behind Start")
        XCTAssertLessThanOrEqual(start.frame.maxY, app.frame.maxY)
    }
    /// Every control in the preview has a 44 pt target of its own, and a tap just inside its edge still acts.
    @MainActor func testPreviewControlsHaveFullSizeTargets() {
        let app = launchHome(location: Self.atBallardLibrary)
        showGasWorksRoutes(app)
        XCTAssertTrue(app.buttons["route-calmer"].waitForExistence(timeout: 10))
        let small = ["choose-destination", "choose-origin", "route-fastest", "route-details", "route-preferences"]
        for id in small {
            let frame = app.buttons[id].frame
            XCTAssertGreaterThanOrEqual(frame.height, 44, "\(id) is \(frame.height) pt tall")
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\(id) is \(frame.width) pt wide")
        }
        let all = small + ["route-calmer", "close-preview", "start-navigation"]
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] {
                XCTAssertFalse(app.buttons[a].frame.insetBy(dx: 1, dy: 1).intersects(app.buttons[b].frame), "\(a) \(app.buttons[a].frame) overlaps \(b) \(app.buttons[b].frame)")
            }
        }
        /// 3 pt inside the top or bottom edge, a quarter of the way along.
        func tapEdge(_ id: String, top: Bool) {
            let element = app.buttons[id]
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0)).withOffset(CGVector(dx: 0, dy: top ? 3 : element.frame.height - 3)).tap()
        }
        let fastest = app.buttons["route-fastest"], calmer = app.buttons["route-calmer"]
        XCTAssertTrue(calmer.isSelected)
        XCTAssertFalse(fastest.isSelected)
        tapEdge("route-fastest", top: true)
        XCTAssertTrue(fastest.isSelected, "A tap at the top edge of Fastest picks it")
        XCTAssertEqual(app.buttons["start-navigation"].label, "Start fastest")
        calmer.tap()
        tapEdge("route-fastest", top: false)
        XCTAssertTrue(fastest.isSelected, "A tap at the bottom edge of Fastest picks it")
        calmer.tap()
        XCTAssertTrue(calmer.isSelected)
        tapEdge("choose-destination", top: true)
        XCTAssertTrue(app.navigationBars["Going to"].waitForExistence(timeout: 5), "A tap at the top edge of the destination opens its picker")
        app.buttons["cancel-search"].tap()
        XCTAssertTrue(app.buttons["cancel-search"].waitForNonExistence(timeout: 5))
        tapEdge("choose-origin", top: false)
        XCTAssertTrue(app.navigationBars["Starting from"].waitForExistence(timeout: 5), "A tap at the bottom edge of the start opens its picker")
        app.buttons["cancel-search"].tap()
        XCTAssertTrue(app.buttons["cancel-search"].waitForNonExistence(timeout: 5))
        tapEdge("route-details", top: false)
        XCTAssertTrue(app.navigationBars["Behind the routes"].waitForExistence(timeout: 5))
        app.buttons["close-details"].tap()
        XCTAssertTrue(app.buttons["close-details"].waitForNonExistence(timeout: 5))
        tapEdge("route-preferences", top: true)
        XCTAssertTrue(app.navigationBars["Calmer means"].waitForExistence(timeout: 5))
        app.buttons["preferences-done"].tap()
    }
    /// Why this route and Calmer means each sit in a well, so they read as buttons and not as bold text.
    @MainActor func testPreviewTextButtonsSitInAWell() {
        let app = launchHome(location: Self.atBallardLibrary)
        showGasWorksRoutes(app)
        XCTAssertTrue(app.buttons["route-calmer"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        let screen = ScreenLuma()
        for id in ["route-details", "route-preferences"] {
            let frame = app.buttons[id].frame
            // Just above the words, inside the well, against the corner of the target, which is the bare panel.
            let inside = screen.mean(around: CGPoint(x: frame.minX + 16, y: frame.minY + 9)), corner = screen.mean(around: CGPoint(x: frame.minX + 2, y: frame.minY + 2))
            XCTAssertGreaterThanOrEqual(abs(inside - corner), 5, "\(id) has nothing behind its words: \(inside) against \(corner)")
        }
    }
}
