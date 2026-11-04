import XCTest
import CoreLocation

final class HomeAndSearchUITests: PeoplemapsUITestCase {
    /// At rest home is only its floating controls; More raises the sheet, and pulling that down leaves the controls again.
    @MainActor func testHomeRestsAsFloatingControlsAndRaisesToASheet() {
        let app = launchHome()
        XCTAssertFalse(app.buttons["about"].exists, "The rest of home waits for the sheet")
        app.buttons["home-more"].tap()
        XCTAssertTrue(app.buttons["about"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home-more"].exists)
        capture("home-raised", app: app)
        let start = app.buttons["search-field"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 500)))
        XCTAssertTrue(app.buttons["home-more"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["about"].exists)
        // Dragging the capsule raises it too.
        raiseHome(app)
        XCTAssertTrue(app.buttons["about"].waitForExistence(timeout: 5))
    }
    @MainActor func testHomeSaysWhereToWithAHintAndNoRoutes() {
        let app = launchHome()
        XCTAssertEqual(app.buttons["search-field"].label, "Where to?")
        XCTAssertTrue(app.staticTexts["home-hint"].exists, "First launch shows a one-line hint")
        XCTAssertFalse(app.staticTexts["Featured places"].exists)
        XCTAssertFalse(app.buttons["add-favourite"].exists)
        XCTAssertFalse(app.staticTexts["Recents"].exists)
        XCTAssertFalse(app.buttons["route-fastest"].exists)
        capture("00-home", app: app)
        // The search panel has nothing to list before the first search either.
        app.buttons["search-field"].tap()
        XCTAssertTrue(app.textFields["search-input"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["search-input"].placeholderValue, "Where to?")
        XCTAssertFalse(app.descendants(matching: .any)["search-empty"].exists)
    }
    @MainActor func testSearchFindsParkAndOpensPlaceCard() {
        let app = launchHome()
        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Gas Works Park")
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
    @MainActor func testRecentDestinationShowsWhenSearchIsEmpty() {
        let app = launch()
        app.buttons["close-preview"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home-recent-relation/1047789"].exists, "Recents wait for the raised sheet")
        raiseHome(app)
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
        field.typeText("Gas Works Park")
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
}
