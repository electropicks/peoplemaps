import XCTest
import CoreLocation

final class HomeAndSearchUITests: PeoplemapsUITestCase {
    /// At rest home is only its floating controls; More raises the sheet, and pulling that down leaves the controls again.
    @MainActor func testHomeRestsAsFloatingControlsAndRaisesToASheet() {
        let app = launchHome()
        XCTAssertFalse(app.buttons["settings"].exists, "The rest of home waits for the sheet")
        app.buttons["home-more"].tap()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home-more"].exists)
        capture("home-raised", app: app)
        let start = app.buttons["search-field"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 500)))
        XCTAssertTrue(app.buttons["home-more"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings"].exists)
        // Dragging the capsule raises it too.
        raiseHome(app)
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
    }
    /// The raised home sheet is frosted, and stays so after Settings opens over it and closes, and after the map is panned: the system's
    /// own glass stops drawing in both cases, so the frost comes from the sheet's background (Docs/DESIGN.md, principle 4).
    @MainActor func testHomeSheetStaysFrostedAfterSettingsAndAPan() {
        let app = launchHome(location: Self.atKerryPark)
        raiseHome(app)
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        // The empty body of the sheet, below its last row, over a part of the map with streets and water.
        let body = CGRect(x: 0.1, y: 0.70, width: 0.8, height: 0.22)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertLessThan(brightnessSpread(body), 5, "Raised home is frosted")
        app.buttons["settings"].tap()
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 5))
        app.buttons["close-settings"].tap()
        XCTAssertTrue(app.buttons["search-field"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        capture("home-after-settings", app: app)
        XCTAssertLessThan(brightnessSpread(body), 5, "Still frosted after Settings closes")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4)))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertLessThan(brightnessSpread(body), 5, "Still frosted after the map is panned")
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
        XCTAssertTrue(app.staticTexts["search-hint"].exists, "The empty search sheet says what to type")
        XCTAssertEqual(app.staticTexts["search-hint"].label, "Search a place, an address or a street")
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
    @MainActor func testMapDataCountsSegmentsFromTheGraphFile() {
        let app = launchHome(extra: ["--hold-router"])
        openSettings(app)
        openSettingsPage(app, "map-data")
        let counted = app.descendants(matching: .any)["segment-count"]
        XCTAssertTrue(counted.waitForExistence(timeout: 5), "A count while the graph is still loading")
        XCTAssertNotNil(rowText(counted).range(of: #"[\d,]{5,}"#, options: .regularExpression), rowText(counted))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'This prototype has not been field validated.'")).firstMatch.exists)
    }
    @MainActor func testSettingsShowsAcknowledgementsAndLicences() {
        let app = launchHome()
        openSettings(app)
        openSettingsPage(app, "acknowledgements")
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
    /// On the raised sheet the first-launch hint is a caption under the field, with nothing behind it, so it can\u{2019}t pass for a
    /// second field. Floating over the map it stays a chip above the capsule (Docs/DESIGN.md 4.2).
    @MainActor func testRaisedHomeHintIsACaptionNotASecondField() {
        let app = launchHome()
        let hint = app.staticTexts["home-hint"], field = app.buttons["search-field"]
        XCTAssertTrue(hint.exists)
        XCTAssertLessThanOrEqual(hint.frame.maxY, field.frame.minY, "Floating, the hint chip sits above the capsule")
        app.buttons["home-more"].tap()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(hint.exists, "The raised sheet still says what to do")
        XCTAssertEqual(hint.label, "Search a place or address, or long-press the map")
        XCTAssertGreaterThanOrEqual(hint.frame.minY, field.frame.maxY, "Raised, the hint is a caption under the field")
        Thread.sleep(forTimeInterval: 1)
        let screen = ScreenLuma()
        // Just outside the words on the leading side, where a well would be, against the bare panel left of the field at the same height.
        let beside = screen.mean(around: CGPoint(x: hint.frame.minX - 5, y: hint.frame.midY))
        let panel = screen.mean(around: CGPoint(x: field.frame.minX - 5, y: hint.frame.midY))
        XCTAssertLessThan(abs(beside - panel), 3, "The hint sits in a well like the field\u{2019}s: \(beside) against \(panel)")
        capture("home-raised-hint", app: app)
    }
    /// With no match and the keyboard up, the Apple Maps hand-off is in full view: clear of the keyboard and of the credit above it.
    /// At the largest standard text size, which on this phone is what a smaller phone shows at the default one.
    @MainActor func testAppleMapsLookupIsInReachWithTheKeyboardUp() {
        let app = launchHome(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        app.buttons["search-field"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("unfindableXYZ")
        let lookup = app.buttons["apple-maps-lookup"], keyboard = app.keyboards.firstMatch
        XCTAssertTrue(lookup.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "The keyboard is up while typing")
        Thread.sleep(forTimeInterval: 1)
        capture("search-no-results-keyboard", app: app)
        XCTAssertTrue(lookup.isHittable)
        XCTAssertGreaterThanOrEqual(lookup.frame.height, 44)
        XCTAssertLessThanOrEqual(lookup.frame.maxY, keyboard.frame.minY, "The row runs under the keyboard")
        let credit = app.links["Map data © OpenStreetMap contributors"]
        if credit.exists { XCTAssertLessThanOrEqual(lookup.frame.maxY, credit.frame.minY, "The row runs under the credit") }
        XCTAssertGreaterThanOrEqual(lookup.frame.minY, field.frame.maxY)
        XCTAssertTrue(app.descendants(matching: .any)["search-empty"].exists, "It still says that nothing matched")
    }
}

extension HomeAndSearchUITests {
    @MainActor private func drag(_ element: XCUIElement, by dy: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 8, dy: dy)))
    }
    @MainActor private func raised(_ app: XCUIApplication) -> Bool { app.buttons["settings"].waitForExistence(timeout: 3) && app.buttons["settings"].isHittable }

    /// The drawer comes up from a short, loose drag on any of the floating controls, not only a long one on the search capsule
    /// (owner's phone, 10 November 2026: "finger has to be too precise").
    @MainActor func testAShortDragOnAnyFloatingControlRaisesHome() {
        for id in ["search-field", "home-more", "home-hint"] {
            let app = launchHome()
            let element = id == "home-hint" ? app.staticTexts[id] : app.buttons[id]
            XCTAssertTrue(element.waitForExistence(timeout: 5), id)
            drag(element, by: -70)
            XCTAssertTrue(raised(app), "A 70 pt drag up on \(id) did not raise home")
            app.terminate()
        }
    }

    /// And goes back down from a short drag anywhere on it.
    @MainActor func testAShortDragDownAnywhereLowersHome() {
        for id in ["settings", "search-field"] {
            let app = launchHome()
            app.buttons["home-more"].tap()
            XCTAssertTrue(raised(app))
            drag(app.buttons[id], by: 110)
            XCTAssertTrue(app.buttons["home-more"].waitForExistence(timeout: 3), "A 110 pt drag down on \(id) did not lower home")
            app.terminate()
        }
    }
}
