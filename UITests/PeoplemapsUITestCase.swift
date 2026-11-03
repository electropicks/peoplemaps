import XCTest
import CoreLocation

/// Launch and wait helpers shared by the app UI test classes. Xcode parallelises by class, so the tests are split by area into
/// classes of similar run time.
class PeoplemapsUITestCase: XCTestCase {
    /// `--location-granted` value: the app starts as if location were allowed with the device at Kerry Park.
    static let atKerryPark = "47.6295,-122.3599"
    static let atBallardLibrary = "47.6698,-122.3843"
    /// Gas Works Park previewed from Current location at Kerry Park (location faked as allowed, no system prompt).
    @MainActor func launch(slow: Bool = false, simulateRoute: Bool = false, fast: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = launchHome(location: Self.atKerryPark, extra: extra + (slow ? ["--slow-routing"] : []) + (simulateRoute ? ["--simulate-route"] : []) + (fast ? ["--fast-simulation"] : []))
        showGasWorksRoutes(app)
        return app
    }
    /// Home with location faked as denied unless `location` is given (`--location-granted`).
    @MainActor func launchHome(location: String? = nil, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (location.map { ["--location-granted", $0] } ?? []) + extra
        app.launch()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 20))
        return app
    }
    /// Searches from Home and opens the place card for `id`.
    @MainActor func openPlace(_ app: XCUIApplication, _ query: String, id: String) {
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
    @MainActor func raiseHome(_ app: XCUIApplication) {
        let start = app.buttons["search-field"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -300)))
    }
    /// Pulls the route preview up from where it opens, to where swap and the Extra time menu are.
    @MainActor func raisePreview(_ app: XCUIApplication) {
        guard !app.buttons["extra-time-menu"].exists else { return }
        let start = app.buttons["choose-destination"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -230)))
    }
    /// Picks a limit from the Extra time menu.
    @MainActor func setExtraTime(_ app: XCUIApplication, _ value: String) {
        raisePreview(app)
        let menu = app.buttons["extra-time-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let item = app.buttons[value]
        XCTAssertTrue(item.waitForExistence(timeout: 5), value)
        item.tap()
    }
    /// Waits for the card's estimate, which the Directions button carries as "Calmer route, 16 to 19 minutes drive, 4.2 miles, …".
    @MainActor @discardableResult func waitForEstimate(_ app: XCUIApplication, containing text: String = " minute") -> String {
        let directions = app.buttons["directions"]
        let ready = NSPredicate { _, _ in (directions.value as? String)?.contains(text) == true }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 20), .completed, text)
        return directions.value as? String ?? ""
    }
    @MainActor func showGasWorksRoutes(_ app: XCUIApplication) {
        openPlace(app, "Gas Works", id: "relation/1047789")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["route-fastest"].waitForExistence(timeout: 20))
    }
    /// Picks a place in the open start or destination picker by searching for it.
    @MainActor func pick(_ app: XCUIApplication, _ query: String, id: String) {
        let field = app.textFields["place-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(query)
        let row = app.buttons["place-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), id)
        row.tap()
    }
    /// The screen, not the app: an app screenshot in landscape comes out rotated and cropped.
    @MainActor func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    // MARK: Real location (Simulator location injection and the system permission alert)

    static let kerryPark = CLLocationCoordinate2D(latitude: 47.6295, longitude: -122.3599)
    /// The Seattle Center lawn: the nearest drivable node, where a route from here starts, is about 143 m away.
    static let seattleCenterLawn = CLLocationCoordinate2D(latitude: 47.6213, longitude: -122.3510)
    @MainActor func setDevice(_ c: CLLocationCoordinate2D, course: Double = -1, accuracy: Double = 5) {
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(coordinate: c, altitude: 50, horizontalAccuracy: accuracy, verticalAccuracy: 5,
                                                                         course: course, speed: course < 0 ? 0 : 8, timestamp: Date()))
    }
    /// Fresh permission state, device parked at `at`, real location: the system prompt comes up once the map shows.
    @MainActor func launchAskingForLocation(answer: String, at: CLLocationCoordinate2D = kerryPark) -> XCUIApplication {
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
    @MainActor func launchReal() -> XCUIApplication {
        let app = launchAskingForLocation(answer: "Allow While Using App")
        showGasWorksRoutes(app)
        XCTAssertTrue(app.buttons["choose-origin"].label.contains("Current location"))
        return app
    }
    @MainActor func answerLocationAlert(_ button: String) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let choice = springboard.alerts.buttons[button]
        XCTAssertTrue(choice.waitForExistence(timeout: 15), "No system location alert with '\(button)'")
        choice.tap()
    }
    @MainActor func probe(_ app: XCUIApplication, _ id: String) -> String {
        (app.descendants(matching: .any)[id].value as? String) ?? "<missing>"
    }
    /// Permission was given at launch, so Start goes straight into guidance.
    @MainActor func startGuidanceReal(_ app: XCUIApplication) {
        app.buttons["start-navigation"].tap()
        XCTAssertTrue(app.staticTexts["guidance-instruction"].waitForExistence(timeout: 20))
    }
    /// Points of the route from the app's debug readout.
    @MainActor func routePoints(_ app: XCUIApplication) -> [CLLocationCoordinate2D] {
        let text = probe(app, "debug-route")
        return text.split(separator: ";").compactMap { pair in
            let p = pair.split(separator: ",").compactMap { Double($0) }
            return p.count == 2 ? CLLocationCoordinate2D(latitude: p[0], longitude: p[1]) : nil
        }
    }
    static func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
    /// Positions every `step` metres along the polyline, up to `limit` metres, with the course of each segment.
    static func samples(_ line: [CLLocationCoordinate2D], step: Double, limit: Double) -> [(CLLocationCoordinate2D, Double)] {
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
    /// Polls the label, so a read a frame early does not fail the test; the message shows what was seen.
    @MainActor func waitForLabel(_ element: XCUIElement, _ label: String, _ note: String = "") {
        let changed = NSPredicate { _, _ in element.label == label }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 5), .completed,
                       "Label is '\(element.label)', wanted '\(label)'. \(note)")
    }
    /// Simulated guidance from the Gas Works preview, waited for before any guidance button is tapped.
    @MainActor func startSimulatedGuidance(_ app: XCUIApplication) {
        app.buttons["start-navigation"].tap()
        XCTAssertTrue(app.staticTexts["guidance-instruction"].waitForExistence(timeout: 10))
    }
    /// Drags across the middle of the screen, the free map between the turn card and the trip bar.
    @MainActor func panMap(_ app: XCUIApplication) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        from.press(forDuration: 0.1, thenDragTo: to)
    }
    @MainActor func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = NSPredicate { _, _ in !element.exists }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: timeout) == .completed
    }
    /// Scrolls the preferences sheet until `element` can be tapped; the first swipe also lifts the sheet to its large detent.
    @MainActor func scrollPreferences(to element: XCUIElement, in app: XCUIApplication) {
        for i in 0..<4 where !(element.exists && element.isHittable) {
            (i.isMultiple(of: 2) ? app.navigationBars["Calmer means"] : app.collectionViews.firstMatch).swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    /// Any marker the map says is on screen.
    @MainActor func marker(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'map-place-'")).firstMatch
    }
    @MainActor func waitForMarkers(_ app: XCUIApplication) {
        let ready = NSPredicate { _, _ in !self.probe(app, "debug-place-markers").isEmpty }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 20), .completed, "No marker feed")
    }
    // MARK: Finding a place: current location, dropped pins, recents, favourites, Apple Maps hand-off

    static let fremont = CLLocationCoordinate2D(latitude: 47.6505, longitude: -122.3500)
    @MainActor func launchHome(keepSaved: Bool) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (keepSaved ? ["--keep-saved"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 20))
        return app
    }
    /// Directions to Gas Works with no start: an empty "Choose start" field and no route.
    @MainActor func showGasWorksStartless(_ app: XCUIApplication) {
        openPlace(app, "Gas Works", id: "relation/1047789")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["needs-place"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["choose-origin"].label, "Choose start")
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        XCTAssertFalse(app.buttons["start-navigation"].exists)
    }
}
