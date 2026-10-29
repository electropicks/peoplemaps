import XCTest
import CoreLocation

final class PeoplemapsUITests: XCTestCase {
    @MainActor private func launch(slow: Bool = false, simulateRoute: Bool = false, fast: Bool = false, realLocation: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = (slow ? ["--ui-testing", "--slow-routing"] : ["--ui-testing"]) + (simulateRoute ? ["--simulate-route"] : []) + (fast ? ["--fast-simulation"] : []) + (realLocation ? ["--real-location"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["featured-relation/1047789"].waitForExistence(timeout: 20))
        app.buttons["featured-relation/1047789"].tap()
        XCTAssertTrue(app.buttons["directions"].waitForExistence(timeout: 5))
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        return app
    }
    @MainActor private func launchHome() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 20))
        return app
    }
    /// The screen, not the app: an app screenshot in landscape comes out rotated and cropped.
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testDrivingCyclingBudgetAndExplanation() {
        let app = launch()
        capture("01-driving-comparison", app: app)
        app.buttons["None"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["no-alternative"].waitForExistence(timeout: 10))
        app.buttons["5 min"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        app.buttons["Cycle"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        capture("02-cycling-comparison", app: app)
        app.buttons["route-details"].tap()
        XCTAssertTrue(app.navigationBars["Behind the routes"].waitForExistence(timeout: 5))
        let climbing = app.staticTexts["Climbing"]
        for _ in 0..<4 where !climbing.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(climbing.exists)
        capture("03-route-evidence", app: app)
        app.buttons["close-details"].tap()
        app.buttons["Drive"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
    }
    // MARK: Real location (Simulator location injection and the system permission alert)

    private static let kerryPark = CLLocationCoordinate2D(latitude: 47.6295, longitude: -122.3599)

    @MainActor private func setDevice(_ c: CLLocationCoordinate2D, course: Double = -1) {
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(coordinate: c, altitude: 50, horizontalAccuracy: 5, verticalAccuracy: 5,
                                                                         course: course, speed: course < 0 ? 0 : 8, timestamp: Date()))
    }

    /// Fresh permission state, device parked at Kerry Park, real location provider, route preview open.
    @MainActor private func launchReal(resetPermission: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        if resetPermission { app.resetAuthorizationStatus(for: .location) }
        setDevice(Self.kerryPark)
        return launch(realLocation: true)
    }

    @MainActor private func answerLocationAlert(_ button: String) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let choice = springboard.alerts.buttons[button]
        XCTAssertTrue(choice.waitForExistence(timeout: 15), "No system location alert with '\(button)'")
        choice.tap()
    }

    @MainActor private func probe(_ app: XCUIApplication, _ id: String) -> String {
        (app.descendants(matching: .any)[id].value as? String) ?? "<missing>"
    }

    @MainActor private func startGuidanceReal(_ app: XCUIApplication) {
        app.buttons["start-navigation"].tap()
        answerLocationAlert("Allow While Using App")
        XCTAssertTrue(app.staticTexts["guidance-instruction"].waitForExistence(timeout: 20))
    }

    /// Points of the route from the app's debug readout.
    @MainActor private func routePoints(_ app: XCUIApplication) -> [CLLocationCoordinate2D] {
        let text = probe(app, "debug-route")
        return text.split(separator: ";").compactMap { pair in
            let p = pair.split(separator: ",").compactMap { Double($0) }
            return p.count == 2 ? CLLocationCoordinate2D(latitude: p[0], longitude: p[1]) : nil
        }
    }

    private static func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Positions every `step` metres along the polyline, up to `limit` metres, with the course of each segment.
    private static func samples(_ line: [CLLocationCoordinate2D], step: Double, limit: Double) -> [(CLLocationCoordinate2D, Double)] {
        var out: [(CLLocationCoordinate2D, Double)] = []
        var carried = 0.0, travelled = 0.0
        for (a, b) in zip(line, line.dropFirst()) {
            let length = metres(a, b)
            guard length > 0 else { continue }
            let course = (atan2(b.longitude - a.longitude, b.latitude - a.latitude) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            var d = step - carried
            while d <= length {
                let t = d / length
                out.append((CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t), course))
                d += step
            }
            carried = length - (d - step)
            travelled += length
            if travelled > limit { break }
        }
        return out
    }

    @MainActor func testRealLocationPermissionAllowedStartsAndEndsGuidance() {
        let app = launchReal()
        startGuidanceReal(app)
        XCTAssertEqual(probe(app, "debug-nav-state"), "guiding")
        XCTAssertEqual(probe(app, "debug-idle-disabled"), "1")
        app.buttons["end-navigation"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        XCTAssertEqual(probe(app, "debug-idle-disabled"), "0")
    }

    @MainActor func testRealLocationPermissionDeniedKeepsPreview() {
        let app = launchReal()
        app.buttons["start-navigation"].tap()
        answerLocationAlert("Don\u{2019}t Allow")
        let alert = app.alerts["Location is off for PeopleMaps"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["Not Now"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["guidance-instruction"].exists)
        XCTAssertEqual(probe(app, "debug-idle-disabled"), "0")
    }

    @MainActor func testRealGPSAlongTheRouteAdvancesInstruction() {
        let app = launchReal()
        startGuidanceReal(app)
        let instruction = app.staticTexts["guidance-instruction"]
        let first = instruction.label
        let line = routePoints(app)
        XCTAssertGreaterThan(line.count, 3, "Route readout missing")
        var changed = false
        for (point, course) in Self.samples(line, step: 20, limit: 600) {
            setDevice(point, course: course)
            Thread.sleep(forTimeInterval: 0.4)
            if instruction.label != first { changed = true }
        }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(changed || instruction.label != first, "Instruction stayed '\(first)' after 600 m")
        XCTAssertFalse(probe(app, "debug-last-spoken").isEmpty)
        XCTAssertEqual(probe(app, "debug-nav-state"), "guiding")
        capture("09-real-gps-guidance", app: app)
    }

    @MainActor func testForcedRerouteRecoversWithNewRoute() {
        let app = launchReal()
        startGuidanceReal(app)
        let line = routePoints(app)
        XCTAssertGreaterThan(line.count, 3, "Route readout missing")
        let before = probe(app, "debug-route")
        let walk = Self.samples(line, step: 20, limit: 300)
        for (point, course) in walk { setDevice(point, course: course); Thread.sleep(forTimeInterval: 0.3) }
        guard let (last, course) = walk.last else { return XCTFail("No samples") }
        // 150 m to the side of the road (perpendicular to the travel direction).
        let side = (course + 90) * .pi / 180
        let off = CLLocationCoordinate2D(latitude: last.latitude + cos(side) * 150 / 111_000,
                                         longitude: last.longitude + sin(side) * 150 / 75_500)
        var sawRerouting = false
        let deadline = Date().addingTimeInterval(10)
        var jitter = 0.0
        while Date() < deadline {
            jitter += 0.00002
            setDevice(CLLocationCoordinate2D(latitude: off.latitude + jitter, longitude: off.longitude), course: course)
            if probe(app, "debug-nav-state") == "rerouting" || app.otherElements["guidance-rerouting"].exists { sawRerouting = true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        capture("10-after-forced-reroute", app: app)
        let rerouted = probe(app, "debug-route") != before
        XCTAssertTrue(sawRerouting || rerouted, "Neither a rerouting state nor a new route appeared")
        let guiding = NSPredicate { _, _ in self.probe(app, "debug-nav-state") == "guiding" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: guiding, object: nil)], timeout: 20), .completed, "Guidance never resumed")
        XCTAssertTrue(rerouted, "Route was not replaced")
        XCTAssertTrue(app.staticTexts["guidance-instruction"].exists)
        XCTAssertFalse(app.staticTexts["guidance-instruction"].label.isEmpty)
    }

    @MainActor func testBackgroundAndForegroundKeepsGuidance() {
        let app = launchReal()
        startGuidanceReal(app)
        let instruction = app.staticTexts["guidance-instruction"]
        let before = instruction.label
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(instruction.waitForExistence(timeout: 10))
        let guiding = NSPredicate { _, _ in self.probe(app, "debug-nav-state") == "guiding" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: guiding, object: nil)], timeout: 10), .completed)
        XCTAssertFalse(instruction.label.isEmpty)
        XCTAssertEqual(instruction.label, before)
        XCTAssertEqual(probe(app, "debug-idle-disabled"), "1")
    }
    @MainActor func testSimulatedGuidanceStartsAdvancesAndEnds() {
        let app = launch(simulateRoute: true)
        app.buttons["start-navigation"].tap()
        let instruction = app.staticTexts["guidance-instruction"]
        XCTAssertTrue(instruction.waitForExistence(timeout: 10))
        let first = instruction.label
        XCTAssertTrue(first.contains("Turn") || first.contains("Head"), first)
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        XCTAssertTrue(app.staticTexts["guidance-distance"].exists)
        XCTAssertTrue(app.staticTexts["trip-minutes"].exists)
        XCTAssertTrue(app.staticTexts["trip-arrival"].exists)
        XCTAssertTrue(app.buttons["guidance-overview"].exists)
        capture("06-guidance", app: app)
        let changed = NSPredicate { _, _ in instruction.exists && instruction.label != first }
        let expectation = XCTNSPredicateExpectation(predicate: changed, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 60), .completed, "Step text stayed '\(first)'")
        capture("07-guidance-next-step", app: app)
        app.buttons["end-navigation"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
    }
    @MainActor func testMuteButtonFlipsItsLabel() {
        let app = launch(simulateRoute: true)
        app.buttons["start-navigation"].tap()
        let mute = app.buttons["guidance-mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 10))
        XCTAssertEqual(mute.label, "Unmute voice", "UI tests start muted")
        mute.tap()
        XCTAssertEqual(mute.label, "Mute voice")
        mute.tap()
        XCTAssertEqual(mute.label, "Unmute voice")
    }
    @MainActor func testSimulatedGuidanceArrivesAndDoneReturnsHome() {
        let app = launch(simulateRoute: true, fast: true)
        app.buttons["start-navigation"].tap()
        XCTAssertTrue(app.staticTexts["guidance-instruction"].waitForExistence(timeout: 10))
        let arrived = app.staticTexts["guidance-arrived"]
        XCTAssertTrue(arrived.waitForExistence(timeout: 150), "Never arrived")
        XCTAssertTrue(arrived.label.contains("You've arrived at"), arrived.label)
        XCTAssertTrue(app.staticTexts["arrival-summary"].exists)
        XCTAssertFalse(app.buttons["end-navigation"].exists)
        capture("08-arrived", app: app)
        app.buttons["done-navigation"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 10))
    }
    @MainActor func testSearchEmptyCancelAndSelection() {
        let app = launch()
        let before = app.buttons["choose-origin"].label
        app.buttons["choose-origin"].tap()
        let field = app.textFields["place-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("unfindableXYZ")
        XCTAssertTrue(app.descendants(matching: .any)["search-empty"].waitForExistence(timeout: 5))
        app.buttons["cancel-search"].tap()
        XCTAssertEqual(app.buttons["choose-origin"].label, before)
        app.buttons["choose-origin"].tap()
        XCTAssertTrue(app.buttons["place-way/37058377"].waitForExistence(timeout: 5))
        app.buttons["place-way/37058377"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Fremont"))
    }
    @MainActor func testSamePlaceErrorAndRecovery() {
        let app = launch()
        app.buttons["choose-destination"].tap()
        app.buttons["place-node/693337509"].tap()
        XCTAssertTrue(app.staticTexts["Choose two different places to compare routes."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        app.buttons["retry-route"].tap()
        XCTAssertTrue(app.staticTexts["Choose two different places to compare routes."].waitForExistence(timeout: 10))
        app.buttons["choose-destination"].tap()
        app.buttons["place-relation/1047789"].tap()
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
            app.buttons["2 min"].tap()
            app.buttons["Drive"].tap()
            app.buttons["10 min"].tap()
            app.buttons["swap"].tap()
            XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 12))
        }
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Kerry"))
        XCTAssertTrue(app.buttons["choose-destination"].label.contains("Gas Works"))
        XCTAssertTrue(app.buttons["10 min"].isSelected)
        XCTAssertTrue(app.buttons["Drive"].isSelected)
        app.buttons["recenter"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].exists)
    }
    @MainActor func testLandscapeKeepsComparison() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["choose-origin"].isHittable)
        app.buttons["Cycle"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        app.buttons["recenter"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].exists)
    }
    @MainActor func testHomeLandsOnFeaturedPlacesWithoutRoutes() {
        let app = launchHome()
        for id in ["relation/1047789", "way/37058377", "way/160545994", "node/693337509"] {
            XCTAssertTrue(app.buttons["featured-\(id)"].exists, id)
        }
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        for (id, subtitle) in [("way/37058377", "Fremont"), ("way/160545994", "University District"), ("node/693337509", "Queen Anne")] {
            XCTAssertTrue(app.buttons["featured-\(id)"].label.hasSuffix("· \(subtitle)"), id)
        }
        capture("00-home", app: app)
    }
    @MainActor func testSearchFindsParkAndOpensPlaceCard() {
        let app = launchHome()
        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("park")
        XCTAssertTrue(app.buttons["result-relation/1047789"].waitForExistence(timeout: 5))
        capture("04-search-park", app: app)
        app.buttons["result-relation/1047789"].tap()
        XCTAssertTrue(app.buttons["directions"].waitForExistence(timeout: 5))
        capture("05-place-card", app: app)
        app.buttons["close-place"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
    }
    @MainActor func testSearchWithNoMatchesAndCancel() {
        let app = launchHome()
        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("unfindableXYZ")
        XCTAssertTrue(app.descendants(matching: .any)["search-empty"].waitForExistence(timeout: 5))
        app.buttons["cancel-search-home"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
    }
    @MainActor func testClosingPreviewReturnsHome() {
        let app = launch()
        app.buttons["close-preview"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["route-fastest"].exists)
    }
    @MainActor func testHomeInLandscapeShowsSearchField() {
        let app = launchHome()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["search-field"].isHittable)
        capture("06-home-landscape", app: app)
    }
    @MainActor func testAboutShowsAcknowledgementsAndLicences() {
        let app = launchHome()
        app.buttons["about"].tap()
        let acknowledgements = app.buttons["acknowledgements"]
        for _ in 0..<3 where !acknowledgements.isHittable { app.collectionViews.firstMatch.swipeUp() }
        acknowledgements.tap()
        XCTAssertTrue(app.navigationBars["Acknowledgements"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["USGS 3D Elevation Program"].exists)
        app.buttons["licence-Ferrostar-LICENSE"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Stadia Maps'")).firstMatch.waitForExistence(timeout: 5))
        capture("07-acknowledgements-ferrostar", app: app)
    }

    // MARK: Finding a place: current location, dropped pins, recents, favourites, Apple Maps hand-off

    private static let fremont = CLLocationCoordinate2D(latitude: 47.6505, longitude: -122.3500)

    @MainActor private func launchHome(keepSaved: Bool) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (keepSaved ? ["--keep-saved"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor func testCurrentLocationOriginWhenAllowed() {
        XCUIApplication().resetAuthorizationStatus(for: .location)
        setDevice(Self.fremont)
        let app = launch()
        app.buttons["choose-origin"].tap()
        let row = app.buttons["place-current-location"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Current location should be offered before permission is asked")
        capture("08-origin-current-location", app: app)
        row.tap()
        answerLocationAlert("Allow While Using App")
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Current location"))
        app.buttons["choose-origin"].tap()
        XCTAssertTrue(app.buttons["place-current-location"].waitForExistence(timeout: 5))
    }

    @MainActor func testCurrentLocationHiddenOnceDenied() {
        XCUIApplication().resetAuthorizationStatus(for: .location)
        setDevice(Self.fremont)
        let app = launch()
        let before = app.buttons["choose-origin"].label
        app.buttons["choose-origin"].tap()
        let row = app.buttons["place-current-location"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        answerLocationAlert("Don\u{2019}t Allow")
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Location is off for PeopleMaps"].exists, "A refusal here must not nag")
        app.buttons["cancel-search"].tap()
        XCTAssertEqual(app.buttons["choose-origin"].label, before)
        app.buttons["choose-origin"].tap()
        XCTAssertTrue(app.buttons["place-relation/1047789"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["place-current-location"].exists)
    }

    @MainActor func testLongPressDropsPinWithDirections() {
        let app = launchHome()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.3)).press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["Dropped pin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '° N'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["directions-from"].exists)
        capture("09-dropped-pin", app: app)
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["choose-destination"].label.contains("Dropped pin"))
        // Far outside the routing bounds: the card says so instead of offering directions.
        app.buttons["close-preview"].tap()
        let map = app.otherElements["Seattle offline map"]
        for _ in 0..<3 { map.pinch(withScale: 0.3, velocity: -2) }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.12)).press(forDuration: 1.2)
        XCTAssertTrue(app.descendants(matching: .any)["outside-coverage"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["directions"].exists)
        capture("10-dropped-pin-outside", app: app)
    }

    @MainActor func testFavouriteSurvivesRelaunchAndSwipesAway() {
        var app = launchHome(keepSaved: false)
        XCTAssertFalse(app.staticTexts["Favourites"].exists, "First launch shows no Favourites section")
        app.buttons["featured-relation/1047789"].tap()
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
        capture("12-home-favourites", app: app)
        row.swipeLeft()
        let remove = app.buttons["Remove"]
        if remove.waitForExistence(timeout: 2) { remove.tap() }
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Favourites"].exists)
    }

    @MainActor func testRecentDestinationShowsWhenSearchIsEmpty() {
        let app = launch()
        app.buttons["close-preview"].tap()
        app.buttons["search-field"].tap()
        XCTAssertTrue(app.buttons["recent-relation/1047789"].waitForExistence(timeout: 5))
        capture("13-search-recents", app: app)
        app.textFields["search-input"].typeText("Gas")
        XCTAssertFalse(app.buttons["recent-relation/1047789"].exists)
    }

    @MainActor func testNoResultsOffersAppleMapsLookup() {
        let app = launchHome()
        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("unfindableXYZ")
        let lookup = app.buttons["apple-maps-lookup"]
        XCTAssertTrue(lookup.waitForExistence(timeout: 5))
        XCTAssertTrue(lookup.label.contains("unfindableXYZ"))
        capture("14-search-apple-maps", app: app)
        app.buttons["cancel-search-home"].tap()
        XCTAssertFalse(lookup.exists)
    }

    @MainActor func testFavouritesAndDroppedPinInLandscape() {
        let app = launchHome()
        app.buttons["featured-way/37058377"].tap()
        XCTAssertTrue(app.buttons["favourite"].waitForExistence(timeout: 5))
        app.buttons["favourite"].tap()
        app.buttons["close-place"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let row = app.buttons["favourite-way/37058377"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.isHittable)
        capture("15-home-favourites-landscape", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["Dropped pin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["directions-from"].isHittable)
        capture("16-dropped-pin-landscape", app: app)
    }
}
