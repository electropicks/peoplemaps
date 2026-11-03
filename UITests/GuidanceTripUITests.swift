import XCTest
import CoreLocation

final class GuidanceTripUITests: PeoplemapsUITestCase {
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
}
