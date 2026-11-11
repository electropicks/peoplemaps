import XCTest

/// Not part of the suite (`Scripts/verify.sh` runs `*UITests.swift`): drives Safari's share sheet to check that the
/// Share Extension is offered and can open the app, which iOS does not promise. Run it by name after an iOS update.
final class ShareSheetSpike: PeoplemapsUITestCase {
    @MainActor func testSharingALinkFromSafariOpensItsPlaceInPeopleMaps() {
        let app = launchHome()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        safari.open(URL(string: "https://www.openstreetmap.org/?mlat=47.6497&mlon=-122.3496")!)
        capture("spike-1-safari", app: safari)
        var share = safari.buttons["ShareButton"]
        if !share.waitForExistence(timeout: 8) {
            // Newer Safari keeps Share behind the page menu.
            for id in ["MoreMenuButton", "PageFormatMenuButton", "More"] where safari.buttons[id].exists { safari.buttons[id].tap(); break }
            share = safari.buttons["Share"].exists ? safari.buttons["Share"] : safari.buttons["ShareButton"]
        }
        XCTAssertTrue(share.waitForExistence(timeout: 5), safari.debugDescription)
        share.tap()
        // The sheet shows the app's name, not the extension's.
        let ours = safari.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] 'Peoplemaps'")).firstMatch
        capture("spike-2-share-sheet", app: safari)
        XCTAssertTrue(ours.waitForExistence(timeout: 8), "PeopleMaps is offered in the share sheet")
        ours.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "the extension opened the app")
        let opened = app.buttons["close-place"].waitForExistence(timeout: 10)
        XCTAssertTrue(opened, "the shared point opened as a place; search holds: \(app.textFields["search-input"].value ?? "nothing")")
        capture("spike-3-opened", app: app)
    }
}
