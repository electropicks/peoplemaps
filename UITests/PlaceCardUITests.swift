import XCTest
import CoreLocation

final class PlaceCardUITests: PeoplemapsUITestCase {
    @MainActor func testPlaceCardSubtitleAddressNearbyAddressOrNeighbourhood() {
        let app = launchHome()
        // The place's own address; the nearest indexed address within 40 m; else the neighbourhood.
        for (query, id, subtitle) in [("Fremont Branch", "way/37058377", "Library · 731 North 35th Street"),
                                      ("Amazon.com Nitro North", "way/1137900798", "Building · Near 2245 Happy Lemon"),
                                      ("Kerry Park", "node/693337509", "Viewpoint · Near 211 West Highland Drive"),
                                      ("Montlake Playfield", "way/40833029", "Park · Montlake")] {
            openPlace(app, query, id: id)
            XCTAssertEqual(app.staticTexts["place-subtitle"].label, subtitle, id)
            // Location is off: no start, so no estimate and no placeholder.
            XCTAssertFalse(app.staticTexts["place-estimate"].exists)
            XCTAssertFalse(app.staticTexts["place-estimate-loading"].exists)
            app.buttons["close-place"].tap()
            XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
        }
    }
    /// Kerry Park to Gas Works has no calmer drive to offer at any budget: the routes with less stress gain too little,
    /// so the button gives the one route's time, its calm word, and what the router found (Docs/STRESS_MODEL.md, Time).
    @MainActor func testPlaceCardSaysWhatTheRouterFoundWhenThereIsNoCalmerDrive() {
        let app = launchHome(location: Self.atKerryPark)
        openPlace(app, "Gas Works", id: "relation/1047789")
        let value = waitForEstimate(app)
        XCTAssertFalse(value.localizedCaseInsensitiveContains("safe"), value)
        if value.hasPrefix("Calmer route") {
            // A full city has a calmer drive here; the card then says so, fastest to calmer.
            XCTAssertNotNil(value.range(of: #"^Calmer route, \d+( to \d+)? minutes? drive, [\d.]+ (miles?|feet), .+ to .+, .+, estimate without live traffic$"#, options: .regularExpression), value)
        } else {
            XCTAssertNotNil(value.range(of: #"^\d+( to \d+)? minutes? drive, "#, options: .regularExpression), value)
            XCTAssertTrue(value.contains("best balance we found"), value)
        }
        XCTAssertFalse(app.staticTexts["place-estimate"].exists)
        XCTAssertFalse(app.staticTexts["place-estimate-loading"].exists)
    }
    /// The card already compared this request for its estimate, so Directions reuses it: no second "Comparing Seattle streets…".
    @MainActor func testDirectionsReusesTheCardsComparison() {
        let app = launchHome(location: Self.atBallardLibrary, extra: ["--slow-routing"])
        openPlace(app, "Gas Works", id: "relation/1047789")
        waitForEstimate(app)
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 1.5), "Directions repeated the comparison the card ran")
        XCTAssertFalse(app.buttons["cancel-route"].exists)
    }
    @MainActor func testPlaceCardEstimatesFromCurrentLocationInTheLastMode() {
        let app = launchHome(location: Self.atBallardLibrary, extra: ["--slow-routing"])
        openPlace(app, "Gas Works", id: "relation/1047789")
        XCTAssertTrue(app.staticTexts["place-estimate-loading"].waitForExistence(timeout: 2), "A quiet placeholder while it computes")
        XCTAssertTrue(app.buttons["directions"].isHittable, "The estimate never blocks the card")
        let value = waitForEstimate(app)
        // The button shows the calmer route Start defaults to, never the fastest time, and reads fastest to calmer.
        XCTAssertNotNil(value.range(of: #"^Calmer route, \d+( to \d+)? minutes? drive, [\d.]+ (miles?|feet), .+, estimate without live traffic$"#, options: .regularExpression), value)
        XCTAssertFalse(value.localizedCaseInsensitiveContains("safe"), value)
        // From Current location there's no start to name.
        XCTAssertFalse(app.staticTexts["place-estimate"].exists)
        capture("17-place-estimate", app: app)
        // Closing mid-way and opening another place starts over for the new one.
        app.buttons["close-place"].tap()
        openPlace(app, "Fremont Branch", id: "way/37058377")
        XCTAssertTrue(app.staticTexts["place-estimate-loading"].waitForExistence(timeout: 2))
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        app.buttons["Cycle"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        app.buttons["close-preview"].tap()
        // Home now lists it under Recents, and its card estimates in the mode used last.
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
        raiseHome(app)
        let recent = app.buttons["home-recent-way/37058377"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.tap()
        waitForEstimate(app, containing: " cycle")
    }
    @MainActor func testFirstLaunchAsksForLocationAndStartsFromIt() {
        let app = launchAskingForLocation(answer: "Allow While Using App", at: Self.fremont)
        // Home frames the user's neighbourhood once the first fix arrives.
        let located = NSPredicate { _, _ in app.buttons["locate"].value as? String == "Found" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: located, object: nil)], timeout: 10), .completed)
        capture("00b-home-at-user", app: app)
        openPlace(app, "Gas Works", id: "relation/1047789")
        waitForEstimate(app)
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons["choose-origin"].label, "Starting from, Current location")
        capture("08-preview-from-current-location", app: app)
        app.buttons["choose-origin"].tap()
        XCTAssertTrue(app.buttons["place-current-location"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["place-relation/1047789"].exists, "No featured places")
        app.buttons["cancel-search"].tap()
        // The next Directions starts from Current location again.
        app.buttons["close-preview"].tap()
        openPlace(app, "Fremont Branch", id: "way/37058377")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons["choose-origin"].label, "Starting from, Current location")
    }
    @MainActor func testDeniedLocationLeavesTheStartEmpty() {
        let app = launchAskingForLocation(answer: "Don\u{2019}t Allow", at: Self.fremont)
        XCTAssertFalse(app.alerts["Location is off for PeopleMaps"].exists, "A refusal must not nag")
        XCTAssertEqual(app.buttons["recenter"].label, "Fit map to Seattle")
        showGasWorksStartless(app)
        capture("09-preview-empty-start", app: app)
        app.buttons["choose-origin"].tap()
        XCTAssertTrue(app.textFields["place-search"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["place-current-location"].exists)
        XCTAssertFalse(app.buttons["place-relation/1047789"].exists, "No featured places")
        pick(app, "Kerry Park", id: "node/693337509")
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Kerry Park"))
        // Without location, the next Directions reuses the start chosen last.
        app.buttons["close-preview"].tap()
        openPlace(app, "Fremont Branch", id: "way/37058377")
        waitForEstimate(app)
        XCTAssertTrue(app.staticTexts["place-estimate"].label.hasPrefix("From Kerry Park"), app.staticTexts["place-estimate"].label)
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Kerry Park"))
    }
    @MainActor func testLongPressDropsPinWithDirections() {
        let app = launchHome(location: Self.atKerryPark)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["place-subtitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '° N'")).firstMatch.exists)
        capture("09-dropped-pin", app: app)
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["choose-destination"].label.hasPrefix("Going to, "))
        // Far outside the routing bounds: the card says so instead of offering directions.
        app.buttons["close-preview"].tap()
        // A pinch on the whole map would also land on the sheet, so fit the city and drag it away from the corner.
        app.buttons["recenter"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.12)).press(forDuration: 1.2)
        XCTAssertTrue(app.descendants(matching: .any)["outside-coverage"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["directions"].exists)
        capture("10-dropped-pin-outside", app: app)
    }
    @MainActor func testFavouriteSurvivesRelaunchAndCanBeRemoved() {
        var app = launchHome(keepSaved: false)
        XCTAssertFalse(app.buttons["add-favourite"].exists, "First launch shows no favourites row")
        openPlace(app, "Gas Works", id: "relation/1047789")
        let star = app.buttons["favourite"]
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        XCTAssertEqual(star.label, "Add to Favourites")
        star.tap()
        XCTAssertEqual(star.label, "Remove from Favourites")
        capture("11-place-favourite", app: app)
        app.buttons["close-place"].tap()
        XCTAssertTrue(app.buttons["favourite-relation/1047789"].waitForExistence(timeout: 5))
        app.terminate()
        app = launchHome(keepSaved: true)
        let row = app.buttons["favourite-relation/1047789"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Favourite should survive a relaunch")
        XCTAssertTrue(row.isHittable, "The row is part of the peek")
        capture("12-home-favourites", app: app)
        // Long-press removes it from the row.
        row.press(forDuration: 1.2)
        let remove = app.buttons["Remove from Favourites"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["add-favourite"].exists, "Hidden again once none are left")
    }
    @MainActor func testAddBadgeAndEditFavourites() {
        let app = launchHome(keepSaved: false)
        openPlace(app, "Gas Works", id: "relation/1047789")
        app.buttons["favourite"].tap()
        app.buttons["close-place"].tap()
        // Add searches, and the place picked goes straight into the row.
        let add = app.buttons["add-favourite"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.placeholderValue, "Add a favourite")
        field.typeText("Kerry Park")
        let result = app.buttons["result-node/693337509"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        XCTAssertTrue(app.buttons["favourite-node/693337509"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["close-place"].exists, "Back on home, not on the place card")
        // Edit, on the raised sheet, lists them; swipe deletes one, and removing the last closes the list and hides the row.
        raiseHome(app)
        XCTAssertTrue(app.buttons["edit-favourites"].waitForExistence(timeout: 5))
        app.buttons["edit-favourites"].tap()
        let swiped = app.cells.containing(.any, identifier: "edit-favourite-node/693337509").firstMatch
        XCTAssertTrue(swiped.waitForExistence(timeout: 5))
        capture("12c-edit-favourites", app: app)
        swiped.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(swiped.waitForNonExistence(timeout: 5))
        let last = app.cells.containing(.any, identifier: "edit-favourite-relation/1047789").firstMatch
        last.swipeLeft()
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["favourite-relation/1047789"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["add-favourite"].exists)
    }
    /// The Directions button's words start where the place's name does, not centred under it.
    @MainActor func testDirectionsWordsLineUpWithTheName() {
        let app = launchHome(location: Self.atBallardLibrary)
        openPlace(app, "Gas Works", id: "relation/1047789")
        waitForEstimate(app)
        Thread.sleep(forTimeInterval: 1)
        let button = app.buttons["directions"].frame, name = app.staticTexts["Gas Works Park"].firstMatch.frame
        // The headline's row: the mode symbol, a gap, then the words.
        let runs = ScreenLuma().inkRuns(in: CGRect(x: button.minX + 10, y: button.minY + 8, width: button.width - 20, height: 20))
        XCTAssertGreaterThanOrEqual(runs.count, 2, "Expected a symbol and words: \(runs)")
        guard runs.count >= 2 else { return }
        XCTAssertEqual(runs[1].lowerBound, name.minX, accuracy: 3, "The words start at \(runs[1].lowerBound), the name at \(name.minX)")
        XCTAssertLessThan(runs[0].upperBound, name.minX, "The mode symbol sits in the badge\u{2019}s column")
    }
    /// In dark mode the primary action is a quiet fill with light words, not a near-white slab, and still reads at 4.5:1.
    @MainActor func testDirectionsIsNotABrightSlabInDarkMode() {
        XCUIDevice.shared.appearance = .dark
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
        let app = launchHome(location: Self.atBallardLibrary)
        openPlace(app, "Gas Works", id: "relation/1047789")
        waitForEstimate(app)
        Thread.sleep(forTimeInterval: 1)
        capture("place-card-dark", app: app)
        func check(_ id: String) {
            let frame = app.buttons[id].frame
            let values = ScreenLuma().values(in: frame.insetBy(dx: frame.height / 2, dy: 6)).sorted()
            guard values.count > 100 else { return XCTFail("No pixels for \(id)") }
            let fill = values[values.count / 2]
            XCTAssertLessThan(fill, 140, "\(id) is a bright slab in dark mode: \(fill) of 255")
            // The words are the pixels furthest from the fill.
            let words = abs(values[values.count - 1] - fill) > abs(values[0] - fill) ? values[values.count - 1] : values[0]
            func linear(_ v: Double) -> Double { let c = v / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let ratio = (max(linear(words), linear(fill)) + 0.05) / (min(linear(words), linear(fill)) + 0.05)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(id): words \(words) on \(fill)")
        }
        check("directions")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["start-navigation"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 1)
        capture("preview-dark", app: app)
        check("start-navigation")
    }
}

extension PlaceCardUITests {
    /// The card is laid out once: when the estimate lands, the Directions button keeps its size and place, so the sheet under it
    /// has not moved either (owner's phone, 9 November 2026: the button's height flickered as each card opened).
    @MainActor func testCardDoesNotMoveWhenTheEstimateLands() {
        let app = launchHome(location: Self.atBallardLibrary, extra: ["--slow-routing"])
        openPlace(app, "Gas Works", id: "relation/1047789")
        XCTAssertTrue(app.staticTexts["place-estimate-loading"].waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 1)
        let before = app.buttons["directions"].frame
        waitForEstimate(app)
        Thread.sleep(forTimeInterval: 1)
        let after = app.buttons["directions"].frame
        XCTAssertEqual(before.height, after.height, accuracy: 0.5, "The button changed height")
        XCTAssertEqual(before.minY, after.minY, accuracy: 0.5, "The card moved")
    }
}
