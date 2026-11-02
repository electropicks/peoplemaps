import XCTest
import CoreLocation

final class PeoplemapsUITests: XCTestCase {
    /// `--location-granted` value: the app starts as if location were allowed with the device at Kerry Park.
    private static let atKerryPark = "47.6295,-122.3599"
    private static let atBallardLibrary = "47.6698,-122.3843"

    /// Gas Works Park previewed from Current location at Kerry Park (location faked as allowed, no system prompt).
    @MainActor private func launch(slow: Bool = false, simulateRoute: Bool = false, fast: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = launchHome(location: Self.atKerryPark, extra: extra + (slow ? ["--slow-routing"] : []) + (simulateRoute ? ["--simulate-route"] : []) + (fast ? ["--fast-simulation"] : []))
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
    /// Pulls the home sheet up from the peek, to where Recents and About are.
    @MainActor private func raiseHome(_ app: XCUIApplication) {
        let start = app.buttons["search-field"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -300)))
    }
    /// Picks a limit from the Extra time menu, which is what the preview shows at its default height.
    @MainActor private func setExtraTime(_ app: XCUIApplication, _ value: String) {
        let menu = app.buttons["extra-time-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let item = app.buttons[value]
        XCTAssertTrue(item.waitForExistence(timeout: 5), value)
        item.tap()
    }
    /// Waits for the card's estimate, which the Directions button carries as "Calmer route, 16 to 19 minutes drive, 4.2 miles, …".
    @MainActor @discardableResult private func waitForEstimate(_ app: XCUIApplication, containing text: String = " minute") -> String {
        let directions = app.buttons["directions"]
        let ready = NSPredicate { _, _ in (directions.value as? String)?.contains(text) == true }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 20), .completed, text)
        return directions.value as? String ?? ""
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
        XCTAssertEqual(app.buttons["extra-time-menu"].value as? String, "10 min", "The default leans to calm")
        // Routes with less stress exist here but gain too little, so this one must not be called the calmest.
        let finding = app.descendants(matching: .any)["no-alternative"]
        XCTAssertTrue(finding.waitForExistence(timeout: 10))
        XCTAssertTrue(finding.label.contains("Best balance we found"), finding.label)
        XCTAssertTrue(finding.label.contains("estimates"), finding.label)
        XCTAssertFalse(finding.label.localizedCaseInsensitiveContains("calmest"), finding.label)
        XCTAssertFalse(finding.label.localizedCaseInsensitiveContains("safe"), finding.label)
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
    @MainActor func testSelectedRouteLineDrawsOnTop() {
        let app = launchHome(location: Self.atBallardLibrary)
        showGasWorksRoutes(app)
        XCTAssertTrue(app.buttons["route-calmer"].waitForExistence(timeout: 10))
        func waitForTop(_ route: String) {
            let onTop = NSPredicate { _, _ in self.probe(app, "debug-top-route") == route }
            XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: onTop, object: nil)], timeout: 5), .completed, "\(route) is not on top")
        }
        waitForTop("calmer")
        app.buttons["route-fastest"].tap()
        waitForTop("fastest")
        app.buttons["route-calmer"].tap()
        waitForTop("calmer")
    }
    // MARK: Real location (Simulator location injection and the system permission alert)

    private static let kerryPark = CLLocationCoordinate2D(latitude: 47.6295, longitude: -122.3599)
    /// The Seattle Center lawn: the nearest drivable node, where a route from here starts, is about 143 m away.
    private static let seattleCenterLawn = CLLocationCoordinate2D(latitude: 47.6213, longitude: -122.3510)

    @MainActor private func setDevice(_ c: CLLocationCoordinate2D, course: Double = -1, accuracy: Double = 5) {
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(coordinate: c, altitude: 50, horizontalAccuracy: accuracy, verticalAccuracy: 5,
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
        // Keep the fixes coming until the route is replaced: a reroute needs a run of off-route fixes, and at
        // least ten seconds since the route was installed.
        var sawRerouting = false
        let deadline = Date().addingTimeInterval(25)
        var jitter = 0.0
        while Date() < deadline, probe(app, "debug-route") == before {
            jitter += 0.00002
            setDevice(CLLocationCoordinate2D(latitude: off.latitude + jitter, longitude: off.longitude), course: course)
            if probe(app, "debug-nav-state") == "rerouting" || app.otherElements["guidance-rerouting"].exists { sawRerouting = true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        capture("18-after-forced-reroute", app: app)
        let rerouted = probe(app, "debug-route") != before
        XCTAssertTrue(sawRerouting || rerouted, "Neither a rerouting state nor a new route appeared")
        let guiding = NSPredicate { _, _ in self.probe(app, "debug-nav-state") == "guiding" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: guiding, object: nil)], timeout: 20), .completed, "Guidance never resumed")
        XCTAssertTrue(rerouted, "Route was not replaced")
        XCTAssertGreaterThanOrEqual(Int(probe(app, "debug-reroute-count")) ?? 0, 1, "Reroute count did not move")
        XCTAssertEqual(probe(app, "debug-route-clears"), "0", "The followed route's line was emptied during the reroute")
        XCTAssertTrue(app.staticTexts["guidance-instruction"].exists)
        XCTAssertFalse(app.staticTexts["guidance-instruction"].label.isEmpty)
    }

    /// Routes start at a snapped node, so a trip can begin some way from where the line does: a dashed leader
    /// bridges the gap, heading for the start is not treated as leaving the route, and the leader goes once on it.
    @MainActor func testLeaderBridgesTheGapToASnappedStart() {
        let app = launchAskingForLocation(answer: "Allow While Using App", at: Self.seattleCenterLawn)
        showGasWorksRoutes(app)
        startGuidanceReal(app)
        let leader = NSPredicate { _, _ in (Int(self.probe(app, "debug-leader")) ?? 0) > 25 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: leader, object: nil)], timeout: 10), .completed,
                       "No leader at a start \(probe(app, "debug-leader")) m from the route")
        // Calmer is the selected route here, so its line and leader hold the calmer green. (A fastest route is the palette's
        // grey, by design: grey is not an unstyled state.) Both layers must carry the colour of the route's kind.
        XCTAssertEqual(probe(app, "debug-line-style"), "calmer 248A3D leader 248A3D", "Line or leader not styled for the calmer route")
        capture("19-leader-at-start", app: app)
        let line = routePoints(app)
        XCTAssertGreaterThan(line.count, 3, "Route readout missing")
        for (point, course) in Self.samples(line, step: 20, limit: 120) { setDevice(point, course: course); Thread.sleep(forTimeInterval: 0.3) }
        let gone = NSPredicate { _, _ in self.probe(app, "debug-leader") == "0" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 10), .completed, "Leader stayed once on the route")
        XCTAssertEqual(probe(app, "debug-reroute-count"), "0", "Heading for the start counted as a deviation")
        XCTAssertEqual(probe(app, "debug-nav-state"), "guiding")
    }

    /// A fix on the route's line but with a poor error radius proves nothing: the engine snaps it, but the gate does not
    /// count it as reaching the route, so the leader from the device's own position to the start stays.
    @MainActor func testPoorAccuracyFixOnTheLineKeepsTheLeader() {
        let app = launchAskingForLocation(answer: "Allow While Using App", at: Self.seattleCenterLawn)
        showGasWorksRoutes(app)
        startGuidanceReal(app)
        let leader = NSPredicate { _, _ in (Int(self.probe(app, "debug-leader")) ?? 0) > 25 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: leader, object: nil)], timeout: 10), .completed, "No leader at the start")
        let line = routePoints(app)
        XCTAssertGreaterThan(line.count, 3, "Route readout missing")
        guard let (point, course) = Self.samples(line, step: 60, limit: 200).first else { return XCTFail("Route too short") }
        for _ in 0..<5 { setDevice(point, course: course, accuracy: 40); Thread.sleep(forTimeInterval: 0.5) }
        let held = Int(probe(app, "debug-leader")) ?? 0
        XCTAssertGreaterThan(held, 25, "A poor fix on the line hid the leader")
        // A good fix at the same place is on the route: the leader goes.
        setDevice(point, course: course, accuracy: 5)
        let gone = NSPredicate { _, _ in self.probe(app, "debug-leader") == "0" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 10), .completed, "Leader stayed after a good fix on the route")
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
    /// The arrow the card draws must point the way its instruction says, at every moment of a whole simulated trip.
    @MainActor func testGuidanceArrowMatchesInstructionThroughoutTrip() {
        let app = launch(simulateRoute: true)
        app.buttons["start-navigation"].tap()
        let instruction = app.staticTexts["guidance-instruction"]
        let arrow = app.descendants(matching: .any)["guidance-arrow"]
        XCTAssertTrue(instruction.waitForExistence(timeout: 10))
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        var checked = Set<String>(), mismatches: [String] = []
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline, !app.staticTexts["guidance-arrived"].exists {
            // Three reads take a moment each: only compare a card that did not change between them.
            let symbol = (arrow.value as? String) ?? "", text = instruction.label
            guard (arrow.value as? String) == symbol, instruction.label == text else { continue }
            for side in ["left", "right"] where text.lowercased().contains(side) {
                checked.insert("\(side) \(symbol)")
                if !symbol.hasSuffix(side) { mismatches.append("'\(text)' drew \(symbol)") }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(mismatches.isEmpty, "Arrow disagrees with text: \(Set(mismatches))")
        XCTAssertGreaterThan(checked.count, 1, "Too few turns seen to compare: \(checked)")
    }
    @MainActor func testMuteButtonFlipsItsLabel() {
        let app = launch(simulateRoute: true)
        app.buttons["start-navigation"].tap()
        // The map buttons sit under the turn card, which appears and grows with the first instruction. A tap
        // aimed before that lands on the card, so wait for the instruction like the other guidance tests do.
        XCTAssertTrue(app.staticTexts["guidance-instruction"].waitForExistence(timeout: 20))
        let mute = app.buttons["guidance-mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 10))
        waitForLabel(mute, "Unmute voice", "UI tests start muted")
        mute.tap(); waitForLabel(mute, "Mute voice")
        mute.tap(); waitForLabel(mute, "Unmute voice")
    }
    /// Polls the label, so a read a frame early does not fail the test; the message shows what was seen.
    @MainActor private func waitForLabel(_ element: XCUIElement, _ label: String, _ note: String = "") {
        let changed = NSPredicate { _, _ in element.label == label }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 5), .completed,
                       "Label is '\(element.label)', wanted '\(label)'. \(note)")
    }
    /// Simulated guidance from the Gas Works preview, waited for before any guidance button is tapped.
    @MainActor private func startSimulatedGuidance(_ app: XCUIApplication) {
        app.buttons["start-navigation"].tap()
        XCTAssertTrue(app.staticTexts["guidance-instruction"].waitForExistence(timeout: 10))
    }
    /// Drags across the middle of the screen, the free map between the turn card and the trip bar.
    @MainActor private func panMap(_ app: XCUIApplication) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        from.press(forDuration: 0.1, thenDragTo: to)
    }
    @MainActor private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = NSPredicate { _, _ in !element.exists }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: timeout) == .completed
    }
    @MainActor func testGuidanceStartsHeadingUpAndCompassFlipsToNorthUp() {
        let app = launch(simulateRoute: true)
        startSimulatedGuidance(app)
        let compass = app.buttons["guidance-compass"]
        XCTAssertTrue(compass.waitForExistence(timeout: 5))
        XCTAssertEqual(compass.label, "Heading up", "Heading-up is the default while guiding")
        XCTAssertFalse(app.buttons["guidance-recenter"].exists, "Following shows no Re-centre")
        compass.tap()
        XCTAssertEqual(compass.label, "North up")
        compass.tap()
        XCTAssertEqual(compass.label, "Heading up")
        XCTAssertFalse(app.buttons["guidance-recenter"].exists)
    }
    @MainActor func testPanningTheMapShowsRecentreWhichFollowsAgain() {
        let app = launch(simulateRoute: true)
        startSimulatedGuidance(app)
        let recenter = app.buttons["guidance-recenter"]
        XCTAssertFalse(recenter.exists)
        panMap(app)
        XCTAssertTrue(recenter.waitForExistence(timeout: 5), "A pan should stop following and offer Re-centre")
        XCTAssertEqual(recenter.label, "Re-centre")
        XCTAssertEqual(app.buttons["guidance-compass"].label, "Heading up", "A free look keeps the follow mode to return to")
        capture("09-guidance-free-look", app: app)
        recenter.tap()
        XCTAssertTrue(waitUntilGone(recenter), "Re-centre should go once following again")
        XCTAssertTrue(app.staticTexts["guidance-instruction"].exists)
        // The compass still toggles after a free look, and following stays on.
        app.buttons["guidance-compass"].tap()
        XCTAssertEqual(app.buttons["guidance-compass"].label, "North up")
        XCTAssertFalse(recenter.exists)
    }
    @MainActor func testOverviewTogglesAndReturnsToFollowing() {
        let app = launch(simulateRoute: true)
        startSimulatedGuidance(app)
        let overview = app.buttons["guidance-overview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertEqual(overview.label, "Route overview")
        overview.tap()
        XCTAssertEqual(overview.label, "Follow my position")
        XCTAssertFalse(app.buttons["guidance-recenter"].exists, "The overview is not a free look")
        capture("10-guidance-overview", app: app)
        overview.tap()
        XCTAssertEqual(overview.label, "Route overview")
        XCTAssertEqual(app.buttons["guidance-compass"].label, "Heading up")
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
    /// AX3 text with long street names: the "Then:" row stays inside the banner, above the calm chip, and the current
    /// instruction is fully on screen.
    @MainActor func testGuidanceBannerHoldsLongNamesAtAX3() {
        let app = launch(simulateRoute: true, extra: ["--long-street-names", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        app.buttons["start-navigation"].tap()
        let instruction = app.staticTexts["guidance-instruction"]
        XCTAssertTrue(instruction.waitForExistence(timeout: 10))
        let then = app.descendants(matching: .any)["guidance-then"]
        XCTAssertTrue(then.waitForExistence(timeout: 5))
        let card = app.descendants(matching: .any)["guidance-card"].frame
        XCTAssertTrue(instruction.label.contains("Extension"), instruction.label)
        XCTAssertGreaterThanOrEqual(then.frame.minY, instruction.frame.maxY - 1, "Then row overprints the instruction")
        XCTAssertLessThanOrEqual(then.frame.maxY, card.maxY + 1, "Then row spills out of the banner")
        let chip = app.descendants(matching: .any)["guidance-calm-note"]
        if chip.exists { XCTAssertGreaterThanOrEqual(chip.frame.minY, card.maxY - 1, "Calm chip overlaps the banner") }
        capture("guidance-ax3-banner", app: app)
    }
    /// AX5 arrival: Done stays on screen, the summary shows in full and the rest scrolls.
    @MainActor func testArrivalCardFitsAtAX5() {
        let app = launch(simulateRoute: true, fast: true, extra: ["--long-street-names", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["start-navigation"].tap()
        let arrived = app.staticTexts["guidance-arrived"]
        XCTAssertTrue(arrived.waitForExistence(timeout: 150), "Never arrived")
        let window = app.windows.firstMatch.frame
        let done = app.buttons["done-navigation"]
        XCTAssertTrue(done.isHittable)
        XCTAssertLessThanOrEqual(done.frame.maxY, window.maxY)
        XCTAssertGreaterThanOrEqual(arrived.frame.minY, window.minY)
        let summary = app.staticTexts["arrival-summary"]
        XCTAssertTrue(summary.label.contains("route"), summary.label)
        XCTAssertLessThanOrEqual(summary.frame.maxY, window.maxY)
        capture("arrival-ax5", app: app)
        done.tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 10))
    }
    /// A tap on the compass while in the overview only leaves it: the orientation it had stays.
    @MainActor func testCompassInOverviewOnlyLeavesTheOverview() {
        let app = launch(simulateRoute: true)
        startSimulatedGuidance(app)
        let compass = app.buttons["guidance-compass"], overview = app.buttons["guidance-overview"]
        XCTAssertTrue(compass.waitForExistence(timeout: 5))
        XCTAssertEqual(compass.label, "Heading up")
        overview.tap()
        XCTAssertEqual(overview.label, "Follow my position")
        compass.tap()
        XCTAssertEqual(overview.label, "Route overview", "The compass should leave the overview")
        XCTAssertEqual(compass.label, "Heading up", "Leaving the overview must not flip the orientation")
    }
    /// At AX3 the chrome still leaves the three map buttons, End and the map's own gestures reachable.
    @MainActor func testGuidanceAtAX3KeepsButtonsReachableAndMapPannable() {
        let app = launchHome(location: Self.atKerryPark, extra: ["--simulate-route", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        showGasWorksRoutes(app)
        startSimulatedGuidance(app)
        for id in ["guidance-mute", "guidance-compass", "guidance-overview", "end-navigation"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), id)
            XCTAssertTrue(app.buttons[id].isHittable, "\(id) is not hittable at AX3")
        }
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.35)))
        XCTAssertTrue(app.buttons["guidance-recenter"].waitForExistence(timeout: 5), "A pan should reach the map at AX3")
    }
    @MainActor func testLandscapeGuidanceKeepsEndAndMuteHittable() {
        let app = launch(simulateRoute: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        startSimulatedGuidance(app)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "The device did not rotate to landscape")
        XCTAssertTrue(app.buttons["end-navigation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["end-navigation"].isHittable, "End must be reachable in the landscape card")
        XCTAssertTrue(app.buttons["guidance-mute"].isHittable, "Mute must be reachable in the trailing capsule")
        capture("11-guidance-landscape", app: app)
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
    @MainActor func testLandscapeKeepsComparison() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["choose-origin"].isHittable)
        XCTAssertTrue(app.buttons["start-navigation"].isHittable, "Start stays on screen in landscape")
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
    /// Kerry Park to Gas Works has no calmer drive to offer at any budget: the routes with less stress gain too little,
    /// so the button gives the one route's time, its calm word, and what the router found (Docs/STRESS_MODEL.md, Time).
    @MainActor func testPlaceCardSaysWhatTheRouterFoundWhenThereIsNoCalmerDrive() {
        let app = launchHome(location: Self.atKerryPark)
        openPlace(app, "Gas Works", id: "relation/1047789")
        let value = waitForEstimate(app)
        XCTAssertNotNil(value.range(of: #"^\d+( to \d+)? minutes? drive, "#, options: .regularExpression), value)
        XCTAssertTrue(value.contains("best balance we found"), value)
        XCTAssertFalse(value.contains("Calmer route"), value)
        XCTAssertFalse(value.localizedCaseInsensitiveContains("safe"), value)
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
        let recent = app.buttons["home-recent-way/37058377"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        raiseHome(app)
        recent.tap()
        waitForEstimate(app, containing: " cycle")
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
    @MainActor func testHomeAndSearchWorkWhileTheRouterIsStillLoading() {
        let app = launchHome(location: Self.atKerryPark, extra: ["--hold-router"])
        XCTAssertFalse(app.staticTexts["Opening Seattle…"].exists)
        openPlace(app, "Gas Works", id: "relation/1047789")
        // Routing waits for the router, with the usual loading states and a way out.
        XCTAssertTrue(app.staticTexts["place-estimate-loading"].exists)
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["cancel-route"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        app.buttons["cancel-route"].tap()
        XCTAssertFalse(app.buttons["cancel-route"].waitForExistence(timeout: 1))
    }
    @MainActor func testAboutCountsSegmentsFromTheGraphFile() {
        let app = launchHome(extra: ["--hold-router"])
        raiseHome(app)
        app.buttons["about"].tap()
        let counted = app.staticTexts.containing(NSPredicate(format: "label MATCHES %@", #"^[\d,]{5,} directed street and path segments are bundled.*"#)).firstMatch
        XCTAssertTrue(counted.waitForExistence(timeout: 5), "A real count while the graph is still loading")
    }
    @MainActor func testAboutShowsAcknowledgementsAndLicences() {
        let app = launchHome()
        raiseHome(app)
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

    /// Current location far outside the routing bounds: Directions says the start is outside and offers to pick another.
    @MainActor func testStartOutsideCoverageSaysSoAndLetsYouPickAStart() {
        let app = launchHome(location: "47.4000,-122.2000")
        openPlace(app, "Gas Works", id: "relation/1047789")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["start-outside-coverage"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your start is outside the area we cover"].exists)
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        XCTAssertFalse(app.buttons["retry-route"].exists, "not a generic failure")
        capture("10b-start-outside", app: app)
        app.buttons["Choose start"].tap()
        XCTAssertTrue(app.textFields["place-search"].waitForExistence(timeout: 5))
    }

    @MainActor func testFavouriteSurvivesRelaunchAndCanBeRemoved() {
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
        XCTAssertTrue(row.isHittable, "The row is part of the peek")
        capture("12-home-favourites", app: app)
        // Long-press removes it from the row.
        row.press(forDuration: 1.2)
        let remove = app.buttons["Remove from Favourites"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Favourites"].exists, "Hidden again once none are left")
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
        // Edit lists them; swipe deletes one, and removing the last closes the list and hides the row.
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
        XCTAssertFalse(app.staticTexts["Favourites"].exists)
    }

    /// Locate is always shown; when it can't centre, it says why instead of doing nothing.
    @MainActor func testLocateExplainsWhenItCannotCentre() {
        var app = launchHome()
        XCTAssertEqual(app.buttons["locate"].value as? String ?? "", "")
        app.buttons["locate"].tap()
        XCTAssertTrue(app.alerts["Location is off for PeopleMaps"].waitForExistence(timeout: 5))
        app.alerts.buttons["Not Now"].tap()
        app.terminate()
        app = launchHome(location: "47.4000,-122.2000")
        app.buttons["locate"].tap()
        XCTAssertTrue(app.alerts["You\u{2019}re outside the area we cover"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        app.terminate()
        app = launchHome(location: Self.atKerryPark)
        app.buttons["locate"].tap()
        let centred = NSPredicate { _, _ in app.buttons["locate"].value as? String == "Centred" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: centred, object: nil)], timeout: 5), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    /// The map credit stays on screen at every stop: over the map, then inside the sheet once the sheet is fully raised.
    @MainActor func testMapCreditStaysVisibleWhenTheSheetIsRaised() {
        let app = launchHome(location: Self.atBallardLibrary)
        let osm = app.links["Map data © OpenStreetMap contributors"], overture = app.links["Places from Overture Maps Foundation"]
        XCTAssertTrue(osm.isHittable)
        XCTAssertTrue(overture.isHittable)
        // Search raises the sheet fully, and the keyboard mustn't hide the credit.
        app.buttons["search-field"].tap()
        XCTAssertTrue(app.textFields["search-input"].waitForExistence(timeout: 5))
        XCTAssertTrue(osm.waitForExistence(timeout: 2))
        XCTAssertTrue(osm.isHittable)
        XCTAssertTrue(overture.isHittable)
        capture("22-credit-search", app: app)
        app.buttons["cancel-search-home"].tap()
        showGasWorksRoutes(app)
        XCTAssertTrue(app.buttons["route-calmer"].waitForExistence(timeout: 10))
        let start = app.buttons["start-navigation"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -6))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -500)))
        XCTAssertTrue(app.buttons["start-navigation"].isHittable)
        XCTAssertTrue(osm.isHittable, "Pinned under Start")
        XCTAssertGreaterThan(osm.frame.minY, app.buttons["start-navigation"].frame.maxY)
        capture("23-credit-preview-large", app: app)
    }

    /// The bar explains the rating in words and scores; a route with nothing calmer has one marker and says what was found.
    @MainActor func testCalmBarInRouteDetails() {
        var app = launchHome(location: Self.atBallardLibrary)
        showGasWorksRoutes(app)
        XCTAssertTrue(app.buttons["route-calmer"].waitForExistence(timeout: 10))
        // The calmer card reads fastest to calmer.
        XCTAssertTrue(app.buttons["route-calmer"].label.contains(" to "), app.buttons["route-calmer"].label)
        app.buttons["route-details"].tap()
        var bar = app.descendants(matching: .any)["calm-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.label.hasPrefix("Calm estimate"), bar.label)
        XCTAssertTrue(bar.label.contains("Fastest: "), bar.label)
        XCTAssertTrue(bar.label.contains("Calmer: "), bar.label)
        XCTAssertTrue(bar.label.contains(" out of 100"), bar.label)
        XCTAssertFalse(bar.label.localizedCaseInsensitiveContains("safe"), bar.label)
        capture("18-calm-bar", app: app)
        app.terminate()
        app = launchHome(location: Self.atKerryPark)
        showGasWorksRoutes(app)
        app.buttons["route-details"].tap()
        bar = app.descendants(matching: .any)["calm-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.label.contains("This route: "), bar.label)
        XCTAssertFalse(bar.label.contains("Calmer: "), bar.label)
        capture("19-calm-bar-one-route", app: app)
    }

    /// At the largest text everything still scrolls into reach, with Start pinned.
    @MainActor func testPreviewScrollsAndKeepsStartAtTheLargestText() {
        let app = launchHome(location: Self.atBallardLibrary, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openPlace(app, "Gas Works", id: "relation/1047789")
        waitForEstimate(app)
        XCTAssertTrue(app.buttons["directions"].isHittable)
        capture("20-place-largest-text", app: app)
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["start-navigation"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["start-navigation"].isHittable)
        capture("21-preview-largest-text", app: app)
        XCTAssertTrue(app.buttons["route-details"].isHittable, "Why this route is pinned with Start")
        let fastest = app.buttons["route-fastest"]
        for _ in 0..<8 where !fastest.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(fastest.isHittable, "The routes scroll into reach")
        XCTAssertTrue(app.buttons["start-navigation"].isHittable)
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

    @MainActor func testSearchResultShowsSourceAndEmptyStateStays() {
        let app = launchHome()
        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("park")
        let result = app.buttons["result-relation/1047789"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        // The visible source line, not just the VoiceOver label.
        XCTAssertTrue(result.staticTexts["OpenStreetMap, Oct 2026"].exists, result.debugDescription)
        XCTAssertTrue(result.label.hasSuffix(", OpenStreetMap, Oct 2026"), result.label)
        app.buttons["cancel-search-home"].tap()
        app.buttons["search-field"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("unfindableXYZ")
        XCTAssertTrue(app.descendants(matching: .any)["search-empty"].waitForExistence(timeout: 5))
    }

    /// VoiceOver order (DESIGN section 7): name, category, address or area, source and date.
    @MainActor func testAddressRowLabelOrder() {
        let app = launchHome()
        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("3400 Fremont Ave N")
        let result = app.buttons["result-node/2652117839"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.label, "3400 Fremont Avenue North, Address, Fremont, OpenStreetMap, Oct 2026")
        XCTAssertTrue(result.staticTexts["Address \u{00B7} Fremont"].exists, result.debugDescription)
        XCTAssertTrue(result.staticTexts["OpenStreetMap, Oct 2026"].exists)
    }

    /// Picker distances run from where the user is, not from the place being replaced, and are absent when that is unknown.
    @MainActor func testPickerDistanceIsFromTheUser() {
        let app = launch()
        app.buttons["choose-origin"].tap()
        pick(app, "Fremont Branch", id: "way/37058377")
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 10))
        app.buttons["choose-origin"].tap()
        let gasWorks = app.buttons["place-recent-relation/1047789"]
        XCTAssertTrue(gasWorks.waitForExistence(timeout: 5))
        // The user is at Kerry Park, 1.6 mi from Gas Works; the start place (Fremont) is under a mile away.
        let measured = NSPredicate { _, _ in gasWorks.label.contains("1.6 miles") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: measured, object: nil)], timeout: 10), .completed, gasWorks.label)
        capture("14b-picker-distance", app: app)
        app.buttons["cancel-search"].tap()
        // The destination picker doesn't know where the user is, so it shows no distances.
        app.buttons["choose-destination"].tap()
        let recent = app.buttons["place-recent-relation/1047789"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        XCTAssertFalse(recent.label.contains("mile") || recent.label.contains("feet"), recent.label)
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
        XCTAssertTrue(app.staticTexts["place-subtitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["directions"].isHittable)
        capture("16-dropped-pin-landscape", app: app)
    }
}
