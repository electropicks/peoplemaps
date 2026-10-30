import XCTest
import CoreLocation

final class PeoplemapsUITests: XCTestCase {
    /// `--location-granted` value: the app starts as if location were allowed with the device at Kerry Park.
    private static let atKerryPark = "47.6295,-122.3599"

    /// Gas Works Park previewed from Current location at Kerry Park (location faked as allowed, no system prompt).
    @MainActor private func launch(slow: Bool = false, simulateRoute: Bool = false, fast: Bool = false) -> XCUIApplication {
        let app = launchHome(location: Self.atKerryPark, extra: (slow ? ["--slow-routing"] : []) + (simulateRoute ? ["--simulate-route"] : []) + (fast ? ["--fast-simulation"] : []))
        showGasWorksRoutes(app)
        return app
    }
    /// Home with location faked as denied unless `location` is given (`--location-granted`).
    @MainActor private func launchHome(location: String? = nil, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (location.map { ["--location-granted", $0] } ?? []) + extra
        app.launch()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 20))
        return app
    }
    /// Searches from Home and opens the place card for `id`.
    @MainActor private func openPlace(_ app: XCUIApplication, _ query: String, id: String) {
        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(query)
        let result = app.buttons["result-\(id)"]
        XCTAssertTrue(result.waitForExistence(timeout: 5), id)
        result.tap()
        XCTAssertTrue(app.buttons["close-place"].waitForExistence(timeout: 5))
    }
    @MainActor private func showGasWorksRoutes(_ app: XCUIApplication) {
        openPlace(app, "Gas Works", id: "relation/1047789")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
    }
    /// Picks a place in the open start or destination picker by searching for it.
    @MainActor private func pick(_ app: XCUIApplication, _ query: String, id: String) {
        let field = app.textFields["place-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(query)
        let row = app.buttons["place-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), id)
        row.tap()
    }
    /// The screen, not the app: an app screenshot in landscape comes out rotated and cropped.
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testDrivingCyclingBudgetAndExplanation() {
        let app = launch()
        capture("01-driving-comparison", app: app)
        // Drive, Cycle, Walk from left to right.
        let x = ["Drive", "Cycle", "Walk"].map { app.buttons[$0].frame.midX }
        XCTAssertEqual(x, x.sorted(), "Mode order")
        XCTAssertTrue(app.buttons["Drive"].isSelected)
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

    /// Fresh permission state, device parked at `at`, real location: the system prompt comes up once the map shows.
    @MainActor private func launchAskingForLocation(answer: String, at: CLLocationCoordinate2D = kerryPark) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        setDevice(at)
        app.launchArguments = ["--ui-testing", "--real-location"]
        app.launch()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 20))
        answerLocationAlert(answer)
        return app
    }

    /// Location allowed at first launch, device at Kerry Park, real location provider, route preview from there open.
    @MainActor private func launchReal() -> XCUIApplication {
        let app = launchAskingForLocation(answer: "Allow While Using App")
        showGasWorksRoutes(app)
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Current location"))
        return app
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

    /// Permission was given at launch, so Start goes straight into guidance.
    @MainActor private func startGuidanceReal(_ app: XCUIApplication) {
        app.buttons["start-navigation"].tap()
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
        let app = launchAskingForLocation(answer: "Don\u{2019}t Allow")
        showGasWorksStartless(app)
        app.buttons["choose-origin"].tap()
        pick(app, "Kerry Park", id: "node/693337509")
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        // Start still checks: guidance needs location, so it explains how to turn it on.
        app.buttons["start-navigation"].tap()
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
        let spoken = probe(app, "debug-last-spoken")
        XCTAssertFalse(spoken.isEmpty)
        // The probe reports the normalised text: no street-type or compass abbreviations are left to be misread.
        XCTAssertNil(spoken.range(of: #"\b(St|Ave|Pl|Blvd|Dr|Ct|Ln|N|S|E|W|NE|NW|SE|SW)\b"#, options: .regularExpression), "Abbreviation in spoken text: \(spoken)")
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
        XCTAssertTrue(before.contains("Current location"), before)
        app.buttons["choose-origin"].tap()
        let field = app.textFields["place-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("unfindableXYZ")
        XCTAssertTrue(app.descendants(matching: .any)["search-empty"].waitForExistence(timeout: 5))
        app.buttons["cancel-search"].tap()
        XCTAssertEqual(app.buttons["choose-origin"].label, before)
        app.buttons["choose-origin"].tap()
        pick(app, "Fremont Branch", id: "way/37058377")
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Fremont"))
    }
    @MainActor func testSamePlaceErrorAndRecovery() {
        let app = launch()
        app.buttons["choose-origin"].tap()
        pick(app, "Gas Works", id: "relation/1047789")
        XCTAssertTrue(app.staticTexts["Choose two different places to compare routes."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        app.buttons["retry-route"].tap()
        XCTAssertTrue(app.staticTexts["Choose two different places to compare routes."].waitForExistence(timeout: 10))
        app.buttons["choose-destination"].tap()
        pick(app, "Kerry Park", id: "node/693337509")
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
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Current location"))
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
    @MainActor func testHomeSaysWhereToWithAHintAndNoRoutes() {
        let app = launchHome()
        XCTAssertEqual(app.buttons["search-field"].label, "Where to?")
        XCTAssertTrue(app.staticTexts["home-hint"].exists, "First launch shows a one-line hint")
        XCTAssertFalse(app.staticTexts["Featured places"].exists)
        XCTAssertFalse(app.staticTexts["Favourites"].exists)
        XCTAssertFalse(app.staticTexts["Recents"].exists)
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        capture("00-home", app: app)
        // The search panel has nothing to list before the first search either.
        app.buttons["search-field"].tap()
        XCTAssertTrue(app.textFields["search-input"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["search-input"].placeholderValue, "Where to?")
        XCTAssertFalse(app.descendants(matching: .any)["search-empty"].exists)
    }
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
    @MainActor func testPlaceCardEstimatesFromCurrentLocationInTheLastMode() {
        let app = launchHome(location: Self.atKerryPark, extra: ["--slow-routing"])
        openPlace(app, "Gas Works", id: "relation/1047789")
        XCTAssertTrue(app.staticTexts["place-estimate-loading"].waitForExistence(timeout: 2), "A quiet placeholder while it computes")
        XCTAssertTrue(app.buttons["directions"].isHittable, "The estimate never blocks the card")
        let estimate = app.staticTexts["place-estimate"]
        XCTAssertTrue(estimate.waitForExistence(timeout: 20))
        XCTAssertNotNil(estimate.label.range(of: #"^Estimate, no live traffic: \d+ min drive · calmer"#, options: .regularExpression), estimate.label)
        XCTAssertFalse(estimate.label.localizedCaseInsensitiveContains("safe"))
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
        let recent = app.buttons["home-recent-way/37058377"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.tap()
        XCTAssertTrue(estimate.waitForExistence(timeout: 20))
        XCTAssertTrue(estimate.label.contains("min cycle"), estimate.label)
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
    @MainActor func testSearchAddressAndRouteToIt() {
        let app = launchHome(location: Self.atKerryPark)
        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("3400 Fremont Ave N")
        let result = app.buttons["result-node/2652117839"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.hasPrefix("3400 Fremont Avenue North, Address"), result.label)
        capture("04b-search-address", app: app)
        result.tap()
        XCTAssertTrue(app.buttons["directions"].waitForExistence(timeout: 5))
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["choose-destination"].label.contains("3400 Fremont"), app.buttons["choose-destination"].label)
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

    /// Directions to Gas Works with no start: an empty "Choose start" field and no route.
    @MainActor private func showGasWorksStartless(_ app: XCUIApplication) {
        openPlace(app, "Gas Works", id: "relation/1047789")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["needs-place"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["choose-origin"].label, "Choose start")
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        XCTAssertFalse(app.buttons["start-navigation"].exists)
    }

    @MainActor func testFirstLaunchAsksForLocationAndStartsFromIt() {
        let app = launchAskingForLocation(answer: "Allow While Using App", at: Self.fremont)
        // Home frames the user's neighbourhood once the first fix arrives.
        let located = NSPredicate { _, _ in app.buttons["recenter"].label == "Centre on your location" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: located, object: nil)], timeout: 10), .completed)
        capture("00b-home-at-user", app: app)
        openPlace(app, "Gas Works", id: "relation/1047789")
        XCTAssertTrue(app.staticTexts["place-estimate"].waitForExistence(timeout: 20))
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
        XCTAssertTrue(app.staticTexts["place-estimate"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["place-estimate"].label.contains("from Kerry Park"), app.staticTexts["place-estimate"].label)
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Kerry Park"))
    }

    @MainActor func testLongPressDropsPinWithDirections() {
        let app = launchHome(location: Self.atKerryPark)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.3)).press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["Dropped pin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '° N'")).firstMatch.exists)
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
        XCTAssertTrue(app.buttons["home-recent-relation/1047789"].waitForExistence(timeout: 5), "Home lists Recents")
        XCTAssertFalse(app.staticTexts["home-hint"].exists, "The hint is only for an empty history")
        capture("12b-home-recents", app: app)
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
        openPlace(app, "Fremont Branch", id: "way/37058377")
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
        XCTAssertTrue(app.buttons["directions"].isHittable)
        capture("16-dropped-pin-landscape", app: app)
    }
}
