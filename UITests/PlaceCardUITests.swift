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
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.3)).press(forDuration: 1.2)
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
}
