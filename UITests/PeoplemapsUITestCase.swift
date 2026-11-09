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
    /// Pulls the home sheet up from the peek, to where Recents and Settings are.
    @MainActor func raiseHome(_ app: XCUIApplication) {
        let start = app.buttons["search-field"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -300)))
    }
    /// Settings sits below the fit stop, so the home sheet comes up first.
    @MainActor func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["settings"]
        if !settings.isHittable { raiseHome(app) }
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 5))
    }
    /// Opens a page of Settings from its row on the root list.
    @MainActor func openSettingsPage(_ app: XCUIApplication, _ row: String) {
        let link = app.buttons[row]
        XCTAssertTrue(link.waitForExistence(timeout: 5), row)
        for _ in 0..<3 where !link.isHittable { app.collectionViews.firstMatch.swipeUp() }
        link.tap()
        XCTAssertTrue(backButton(app).waitForExistence(timeout: 5), "\(row) opens a page")
    }
    /// Back from a page of Settings to its root list.
    @MainActor func backToSettings(_ app: XCUIApplication) {
        backButton(app).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }
    @MainActor private func backButton(_ app: XCUIApplication) -> XCUIElement { app.navigationBars.buttons["BackButton"] }
    /// What a row with a trailing value says: "Usage log" and "Off" may be its label and value, or one label.
    @MainActor func rowText(_ element: XCUIElement) -> String { (element.label + " " + (element.value as? String ?? "")).trimmingCharacters(in: .whitespaces) }
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
    /// Saves the screen as `<name>.png` in the folder `TEST_RUNNER_PEOPLEMAPS_SHOTS` names, and in the results.
    @MainActor func saveEvidence(_ name: String) {
        Thread.sleep(forTimeInterval: 1)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["PEOPLEMAPS_SHOTS"], !folder.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        XCTAssertNoThrow(try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")))
    }
    /// The screen, not the app: an app screenshot in landscape comes out rotated and cropped. `TEST_RUNNER_PEOPLEMAPS_SHOTS`, a folder on
    /// the Mac, also gets the PNG.
    @MainActor func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["PEOPLEMAPS_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
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
    /// Standard deviation of the screen's brightness (0 to 255) over `region`, given in fractions of the screen. Over the empty part
    /// of a frosted sheet it is about 1 to 4; with the map showing sharply through it, 10 or more.
    @MainActor func brightnessSpread(_ region: CGRect) -> Double {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return .nan }
        let rect = CGRect(x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height),
                          width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height)).integral
        guard let crop = image.cropping(to: rect) else { return .nan }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        guard let context = CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .nan }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var sum = 0.0, squares = 0.0
        let count = Double(crop.width * crop.height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let y = 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
            sum += y; squares += y * y
        }
        let mean = sum / count
        return (squares / count - mean * mean).squareRoot()
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

/// The screen's brightness (0 to 255), read in points, for checks no accessibility value can make: a fill, an alignment.
@MainActor struct ScreenLuma {
    private var pixels: [UInt8] = []
    private(set) var width = 0, height = 0
    /// Pixels per point.
    private(set) var scale: CGFloat = 1

    init() {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return }
        width = image.width; height = image.height
        scale = CGFloat(image.width) / XCUIApplication().windows.firstMatch.frame.width
        pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { pixels = []; return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    /// One pixel, by pixel coordinates.
    func pixel(_ x: Int, _ y: Int) -> Double {
        guard x >= 0, y >= 0, x < width, y < height, !pixels.isEmpty else { return .nan }
        return Double(pixels[y * width + x])
    }
    /// Every pixel of `rect`, given in points.
    func values(in rect: CGRect) -> [Double] {
        let r = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        var out: [Double] = []
        for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { let v = pixel(x, y); if !v.isNaN { out.append(v) } } }
        return out
    }
    /// The mean over 2 pt around `point`.
    func mean(around point: CGPoint) -> Double {
        let v = values(in: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2))
        return v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count)
    }
    /// The x, in points, of each run of columns in `rect` holding a pixel at least `contrast` away from the rect's median: the
    /// start and end of every glyph or symbol on a plain fill. Runs closer than `gap` points count as one.
    func inkRuns(in rect: CGRect, contrast: Double = 60, gap: CGFloat = 5) -> [ClosedRange<CGFloat>] {
        let all = values(in: rect).sorted()
        guard !all.isEmpty else { return [] }
        let median = all[all.count / 2]
        let r = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        var runs: [ClosedRange<CGFloat>] = []
        for x in Int(r.minX)..<Int(r.maxX) {
            let ink = (Int(r.minY)..<Int(r.maxY)).contains { abs(pixel(x, $0) - median) >= contrast }
            guard ink else { continue }
            let at = CGFloat(x) / scale
            if let last = runs.last, at - last.upperBound <= gap { runs[runs.count - 1] = last.lowerBound...at } else { runs.append(at...at) }
        }
        return runs
    }
}

