import XCTest
import CoreLocation

final class MapAndMarkerUITests: PeoplemapsUITestCase {
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
    /// A long move (Home at the user's neighbourhood to a place across town) flies instead of sweeping; the probe reports how
    /// each move was made, as it would be with motion on (`--ui-testing` itself cuts).
    @MainActor func testFarCameraMoveFliesAndShortOnesGlide() {
        let app = launchHome(location: Self.atKerryPark)
        openPlace(app, "Gas Works", id: "relation/1047789")
        let flew = NSPredicate { _, _ in self.probe(app, "debug-camera-moves").contains("fly") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: flew, object: nil)], timeout: 10), .completed,
                       "Moves were: \(probe(app, "debug-camera-moves"))")
        capture("40-far-move-lands", app: app)
    }
    /// Outside guidance the marker is the plain ring: with no heading source there is no direction to show, and none is invented.
    @MainActor func testMarkerIsAPlainRingOutsideGuidance() {
        let app = launchHome(location: Self.atKerryPark)
        let dot = NSPredicate { _, _ in self.probe(app, "debug-marker") == "ring" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: dot, object: nil)], timeout: 10), .completed, probe(app, "debug-marker"))
    }
    /// With a heading (the compass; here injected with `--fake-heading`) the ring grows into its pointed form. Captured in light and dark.
    @MainActor func testMarkerShowsHeadingFromTheCompass() {
        let app = launchHome(location: Self.atKerryPark, extra: ["--fake-heading", "70"])
        let beam = NSPredicate { _, _ in self.probe(app, "debug-marker") == "point 70" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: beam, object: nil)], timeout: 10), .completed, probe(app, "debug-marker"))
        capture("42-heading-beam-light", app: app)
        XCUIDevice.shared.appearance = .dark
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(probe(app, "debug-marker"), "point 70")
        capture("43-heading-beam-dark", app: app)
        XCUIDevice.shared.appearance = .light
    }
    /// While guiding, the marker is the ring until a course is known, then the pointed ring; the line splits at progress, the part behind
    /// in the passed colour, and is never emptied or rebuilt on the way.
    @MainActor func testGuidanceShowsPointedRingAndSplitsTheRouteAtProgress() {
        let app = launchAskingForLocation(answer: "Allow While Using App", at: Self.seattleCenterLawn)
        showGasWorksRoutes(app)
        startGuidanceReal(app)
        let line = routePoints(app)
        XCTAssertGreaterThan(line.count, 3, "Route readout missing")
        func passedMetres() -> Int { Int(probe(app, "debug-passed").split(separator: " ").first ?? "") ?? -1 }
        XCTAssertEqual(passedMetres(), 0, "Something was already passed at the start: \(probe(app, "debug-passed"))")
        XCTAssertTrue(probe(app, "debug-passed").hasSuffix(" A6B3C0"), "Passed colour: \(probe(app, "debug-passed"))")
        for (point, course) in Self.samples(line, step: 20, limit: 300) { setDevice(point, course: course); Thread.sleep(forTimeInterval: 0.3) }
        let split = NSPredicate { _, _ in passedMetres() > 100 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: split, object: nil)], timeout: 15), .completed,
                       "The line did not split as the device moved: \(probe(app, "debug-passed"))")
        XCTAssertTrue(probe(app, "debug-marker").hasPrefix("point "), "Marker: \(probe(app, "debug-marker"))")
        XCTAssertEqual(probe(app, "debug-route-clears"), "0", "The followed route's line was emptied while it was split")
        capture("41-arrow-and-passed-line", app: app)
    }
    @MainActor func testBaseMapDrawsFromBundledTiles() {
        let app = launchHome()
        let drawn = NSPredicate { _, _ in (Int(self.probe(app, "debug-map-features")) ?? 0) > 0 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: drawn, object: nil)], timeout: 10), .completed, "the bundled tiles drew no water or roads")
    }
    @MainActor func testTappingAPlaceMarkerOpensItsCardAndRoutesClearTheMarkers() {
        let app = launchHome(location: "47.6505,-122.35")
        waitForMarkers(app)
        XCTAssertTrue(marker(app).waitForExistence(timeout: 10), "Neighbourhood zoom shows markers, at \(probe(app, "debug-zoom"))")
        // One in the open: not under the map buttons at the top right.
        let found = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'map-place-'")).allElementsBoundByIndex
            .first { $0.frame.midY > 200 && $0.frame.midX < 300 }
        guard let found else { return XCTFail("No marker in the open") }
        let label = found.label
        // A plain tap on the map where the marker is, the way a finger gets there.
        found.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["close-place"].waitForExistence(timeout: 5))
        let name = String(label[..<(label.range(of: ",", options: .backwards)?.lowerBound ?? label.endIndex)])
        XCTAssertTrue(app.staticTexts[name].exists || app.staticTexts[String(name.prefix(while: { $0 != "," }))].exists, "\(label) opened another card")
        capture("place-from-marker", app: app)
        XCTAssertTrue(app.buttons["directions"].waitForExistence(timeout: 5))
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["start-navigation"].waitForExistence(timeout: 20))
        XCTAssertFalse(marker(app).exists, "Markers stay off the map while comparing routes")
    }
    @MainActor func testZoomedOutMapHasNoMarkers() {
        let app = launchHome()
        waitForMarkers(app)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertLessThan(Double(probe(app, "debug-zoom")) ?? 99, 13.5)
        XCTAssertFalse(marker(app).exists)
    }
    /// The credit is a licence term, so it has to clear home's floating controls, and they have to fit on the screen,
    /// whichever of them are showing.
    @MainActor func testPeekHoldsItsContentAndLeavesTheCreditVisible() {
        func check(_ app: XCUIApplication, last: XCUIElement, _ state: String) {
            Thread.sleep(forTimeInterval: 1)
            let screen = app.windows.firstMatch.frame
            let credit = app.links["Map data © OpenStreetMap contributors"]
            XCTAssertTrue(credit.exists, state)
            let field = app.buttons["search-field"], more = app.buttons["home-more"]
            XCTAssertTrue(more.isHittable, state)
            XCTAssertLessThanOrEqual(credit.frame.maxY, min(field.frame.minY, last.frame.minY), "\(state): credit behind the controls")
            XCTAssertLessThanOrEqual(field.frame.maxY, screen.maxY, "\(state): field cut off")
            XCTAssertLessThanOrEqual(more.frame.maxX, screen.maxX, "\(state): more cut off")
            XCTAssertLessThanOrEqual(last.frame.maxY, screen.maxY, "\(state): content cut off")
            print("home \(state): credit \(credit.frame) field \(field.frame) last \(last.frame)")
            capture("peek-\(state)", app: app)
        }
        let app = launchHome()
        check(app, last: app.staticTexts["home-hint"], "first-launch")
        openPlace(app, "Gas Works", id: "relation/1047789")
        app.buttons["directions"].tap()
        XCTAssertTrue(app.buttons["close-preview"].waitForExistence(timeout: 5))
        app.buttons["close-preview"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
        check(app, last: app.buttons["search-field"], "recents-only")
        openPlace(app, "Gas Works", id: "relation/1047789")
        app.buttons["favourite"].tap()
        app.buttons["close-place"].tap()
        XCTAssertTrue(app.buttons["add-favourite"].waitForExistence(timeout: 5))
        check(app, last: app.buttons["add-favourite"], "favourites")
    }
    /// Frame times while panning a zoomed-in map, for `Docs/PERFORMANCE.md`. Skipped unless `TEST_RUNNER_PEOPLEMAPS_PAN=1`;
    /// `TEST_RUNNER_PEOPLEMAPS_NO_MARKERS=1` measures the map without markers to compare.
    @MainActor func testPanFrameTimes() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PEOPLEMAPS_PAN"] == "1", "Set TEST_RUNNER_PEOPLEMAPS_PAN=1")
        let off = environment["PEOPLEMAPS_NO_MARKERS"] == "1"
        let app = launchHome(location: "47.6155,-122.3380", extra: ["--measure-frames"] + (off ? ["--no-place-markers"] : []))
        if !off { waitForMarkers(app) }
        let window = app.windows.firstMatch
        // About zoom 16, Downtown: the most markers the map ever has in view.
        window.pinch(withScale: 2.2, velocity: 2)
        Thread.sleep(forTimeInterval: 1)
        window.pinch(withScale: 2.2, velocity: 2)
        Thread.sleep(forTimeInterval: 2)
        let middle = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let offsets = [CGVector(dx: -260, dy: 120), CGVector(dx: 260, dy: -120), CGVector(dx: 180, dy: 220), CGVector(dx: -180, dy: -220)]
        for round in 0..<32 {
            middle.press(forDuration: 0.02, thenDragTo: middle.withOffset(offsets[round % offsets.count]), withVelocity: .fast, thenHoldForDuration: 0)
        }
        Thread.sleep(forTimeInterval: 1)
        let line = "pan frames \(off ? "without" : "with") markers at z\(probe(app, "debug-zoom")): \(probe(app, "debug-frames")); feed \(probe(app, "debug-place-markers"))"
        print(line)
        let attachment = XCTAttachment(string: line); attachment.name = "pan-frames"; attachment.lifetime = .keepAlways; add(attachment)
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
        let start = app.buttons["choose-destination"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -500)))
        XCTAssertTrue(app.buttons["start-navigation"].isHittable)
        XCTAssertTrue(osm.isHittable, "Pinned under Start")
        XCTAssertGreaterThan(osm.frame.minY, app.buttons["start-navigation"].frame.maxY)
        capture("23-credit-preview-large", app: app)
    }
}
