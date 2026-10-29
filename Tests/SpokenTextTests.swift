import XCTest
@testable import PeoplemapsCore

final class SpokenTextTests: XCTestCase {
    private func say(_ s: String) -> String { SpokenText.normalize(s) }

    func testDirectionalsAndStreetTypes() {
        XCTAssertEqual(say("Turn left onto N 45th St"), "Turn left onto North 45th Street")
        XCTAssertEqual(say("Turn right onto Aurora Ave N"), "Turn right onto Aurora Avenue North")
        XCTAssertEqual(say("Head south on NE 65th St"), "Head south on Northeast 65th Street")
        XCTAssertEqual(say("Continue onto Dexter Ave N"), "Continue onto Dexter Avenue North")
        XCTAssertEqual(say("Turn left onto 5th Pl SW"), "Turn left onto 5th Place Southwest")
        XCTAssertEqual(say("Turn right onto Lake Washington Blvd S"), "Turn right onto Lake Washington Boulevard South")
    }

    func testDirectionalsOnlyAsWholeTokens() {
        XCTAssertEqual(say("Turn left onto Nickerson St"), "Turn left onto Nickerson Street")
        XCTAssertEqual(say("Head north on Eastlake Ave E"), "Head north on Eastlake Avenue East")
    }

    func testSaintAndDoctorAtStartOfName() {
        XCTAssertEqual(say("Turn left onto St Marks Pl"), "Turn left onto Saint Marks Place")
        XCTAssertEqual(say("Turn left onto Dr Jose Rizal Bridge"), "Turn left onto Doctor Jose Rizal Bridge")
        XCTAssertEqual(say("Turn left onto Pine St"), "Turn left onto Pine Street")
    }

    func testRoutes() {
        XCTAssertEqual(say("Continue onto SR 99"), "Continue onto State Route 99")
        XCTAssertEqual(say("Continue onto SR-520"), "Continue onto State Route 520")
        XCTAssertEqual(say("Continue onto I-5 N"), "Continue onto I 5 North")
        XCTAssertEqual(say("Continue onto Mt Baker Blvd"), "Continue onto Mount Baker Boulevard")
    }

    func testDistances() {
        XCTAssertEqual(say("In 500 feet, turn left onto Pine St"), "In 500 feet, turn left onto Pine Street")
        XCTAssertEqual(say("In 0.3 miles, turn left"), "In a quarter mile, turn left")
        XCTAssertEqual(say("In 0.5 miles, turn left"), "In half a mile, turn left")
        XCTAssertEqual(say("In 1.0 mile, turn left"), "In 1 mile, turn left")
        XCTAssertEqual(say("In 1.5 miles, turn left"), "In a mile and a half, turn left")
        XCTAssertEqual(say("In 2.4 miles, turn left"), "In 2.4 miles, turn left")
    }

    func testPlainTextUntouched() {
        XCTAssertEqual(say("Cross at the signal"), "Cross at the signal")
        XCTAssertEqual(say("Make a U-turn"), "Make a U-turn")
        XCTAssertEqual(say("You've arrived at Gas Works Park"), "You've arrived at Gas Works Park")
    }

    /// Every distinct street name in the bundled graph, as the banner shortens it, must come out with no abbreviation left.
    func testEveryBundledStreetName() throws {
        let graph = try StreetGraph.bundled()
        let names = Set(graph.edges.map(\.name).filter { !$0.isEmpty })
        XCTAssertGreaterThan(names.count, 100)
        let leftover: Set<String> = ["St", "Ave", "Pl", "Blvd", "Dr", "Ct", "Ln", "Pkwy", "Hwy", "Ter", "Terr", "Rd", "N", "S", "E", "W", "NE", "NW", "SE", "SW"]
        var odd: [String] = []
        for name in names.sorted() {
            let spoken = say(NavigationBuilder.shorten(name))
            if spoken.split(separator: " ").contains(where: { leftover.contains(String($0)) }) { odd.append("\(name) → \(spoken)") }
        }
        if !odd.isEmpty { print("SPOKEN-ODD:\n" + odd.joined(separator: "\n")) }
        XCTAssertTrue(odd.isEmpty, "\(odd.count) names keep an abbreviation: \(odd.prefix(10))")
    }
}
