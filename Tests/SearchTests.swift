import XCTest
@testable import PeoplemapsCore

final class SearchTests: XCTestCase {
    static let graph = try! StreetGraph.bundled()
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peoplemaps-search-tests")
    static let index = try! SearchIndex.bundled(graph: graph, directory: directory)
    static let fremont = Coordinate(lat: 47.651, lon: -122.350)
    private var index: SearchIndex { Self.index }

    func testOpensWithPlacesAddressesAndSource() {
        XCTAssertGreaterThan(index.count, 50_000)
        XCTAssertTrue(index.source.hasPrefix("OpenStreetMap, "), index.source)
        XCTAssertTrue(index.search("").isEmpty)
        XCTAssertTrue(index.search("  ,. ").isEmpty)
    }
    func testReopeningReusesTheInflatedFile() throws {
        let again = try SearchIndex.bundled(graph: Self.graph, directory: Self.directory)
        XCTAssertEqual(again.count, index.count)
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path).filter { $0.hasPrefix("seattle-search-") }
        XCTAssertEqual(files.count, 1)
    }
    func testNormalizeMatchesTheImporter() {
        XCTAssertEqual(SearchIndex.normalize("Café Ladro's  Fremont-Ave"), "cafe ladros fremont ave")
        XCTAssertEqual(SearchIndex.normalize("Bread & Butter"), "bread and butter")
    }
    func testPrefixSearchAsYouType() {
        // "g" and "ga" rank landmarks (a museum) over the park, as intended.
        for typed in ["gas w", "gas wo", "gas works", "GAS WORKS PARK"] {
            XCTAssertEqual(index.search(typed, near: Self.fremont).first?.name, "Gas Works Park", typed)
        }
        XCTAssertEqual(index.search("gas works").first?.id, "relation/1047789", "keeps the graph's own place ID")
    }
    func testGraphPlacesGetTheirAddressFromTheIndex() throws {
        let park = try XCTUnwrap(Self.graph.places.first { $0.id == "relation/1047789" })
        XCTAssertEqual(index.withAddress(park).address, "2101 North Northlake Way")
        let pin = Place(id: "pin", name: "Dropped pin", lat: 47.65, lon: -122.34, category: "pin")
        XCTAssertNil(index.withAddress(pin).address)
    }
    func testRepeatedQueriesReuseTheLastAnswer() {
        let first = index.search("gas works", near: Self.fremont)
        XCTAssertEqual(index.search("gas works", near: Self.fremont).map(\.id), first.map(\.id))
        XCTAssertNotEqual(index.search("kerry", near: Self.fremont).first?.id, first.first?.id)
        XCTAssertTrue(index.search(" ").isEmpty)
    }
    func testHouseNumberAddresses() throws {
        for typed in ["3400 Fremont Ave N", "3400 fremont", "3400 Fremont Avenue North", "3400 frem av n"] {
            let first = try XCTUnwrap(index.search(typed, near: Self.fremont).first, typed)
            XCTAssertEqual(first.name, "3400 Fremont Avenue North", typed)
            XCTAssertEqual(first.kind, .address)
            XCTAssertEqual(first.category, "address")
        }
    }
    func testUnitsAndMissingHouseNumbers() throws {
        let unit = try XCTUnwrap(index.search("2101 N 55th St #100").first)
        XCTAssertEqual(unit.name, "2101 North 55th Street, Unit 100")
        // No 3405 is mapped: the nearest numbers on that street come first, each under its own real number.
        let near = index.search("3405 fremont ave n")
        XCTAssertFalse(near.isEmpty)
        XCTAssertFalse(near.contains { $0.name.hasPrefix("3405 ") })
        XCTAssertTrue(near[0].name.hasSuffix("Fremont Avenue North"), near[0].name)
    }
    func testRankingTextThenCategoryThenDistance() throws {
        // Parks and landmarks outrank shops and cafés for an equal text match.
        let fremont = index.search("fremont", near: Self.fremont)
        let troll = try XCTUnwrap(fremont.firstIndex { $0.name == "Fremont Troll" })
        let shop = try XCTUnwrap(fremont.firstIndex { $0.name == "Fremont Brewing Merchantile" })
        XCTAssertLessThan(troll, shop)
        XCTAssertLessThan(fremont.firstIndex { $0.kind == .place } ?? .max, fremont.firstIndex { $0.kind == .address } ?? .max)
        // Within a tier and weight, nearer first.
        let cafes = index.search("starbucks", near: Self.fremont).filter { $0.name == "Starbucks" }
        XCTAssertGreaterThan(cafes.count, 1)
        let distances = cafes.filter { $0.category == cafes[0].category }.map { $0.coordinate.distance(to: Self.fremont) }
        XCTAssertEqual(distances, distances.sorted())
        // A name that starts with the query beats one that only contains it.
        XCTAssertTrue(index.search("space needle").first?.name.hasPrefix("Space Needle") == true)
    }
    func testTypoFallback() {
        XCTAssertEqual(index.search("gas wroks").first?.name, "Gas Works Park")
        XCTAssertEqual(index.search("fremnot troll").first?.name, "Fremont Troll")
        XCTAssertTrue(index.search("qqqqzzzz").isEmpty)
        XCTAssertEqual(SearchIndex.editDistance(Array("wroks"), Array("works"), limit: 2), 1)
        XCTAssertEqual(SearchIndex.editDistance(Array("kitten"), Array("sitting"), limit: 3), 3)
    }
    func testResultsCarrySnapNodesAndRoute() throws {
        let address = try XCTUnwrap(index.search("3400 Fremont Ave N").first)
        XCTAssertEqual(Set(address.snap.keys), Set(TravelMode.allCases))
        let origin = try XCTUnwrap(Self.graph.places.first { $0.id == "way/37058377" })
        let router = NativeRouter(graph: Self.graph)
        let comparison = try router.compute(.init(origin: origin, destination: address, mode: .walk, extraMinutes: 2))
        XCTAssertLessThan(comparison.destinationSnapMeters, 60)
        XCTAssertEqual(comparison.snappedDestination, Self.graph.nodes[address.snap[.walk]!].coordinate)
    }
    func testSnapNodesIgnoredForAnotherGraph() throws {
        let gz = try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "seattle-search.sqlite", withExtension: "gz")))
        let other = try SearchIndex(gzipped: gz, graphNodeCount: 5, directory: Self.directory)
        XCTAssertTrue(try XCTUnwrap(other.search("3400 Fremont Ave N").first).snap.isEmpty)
    }
    func testQueryLatency() {
        let queries = ["s", "st", "sta", "star", "starb", "3400 fremont ave n", "gas works", "fremnot troll", "pho", "1 n"]
        _ = index.search("warm up")
        var worst = 0.0
        let start = Date()
        for q in queries {
            let t = Date(); _ = index.search(q, near: Self.fremont); worst = max(worst, Date().timeIntervalSince(t))
        }
        let mean = Date().timeIntervalSince(start) / Double(queries.count)
        print("search latency: mean \(Int(mean * 1000)) ms, worst \(Int(worst * 1000)) ms")
        XCTAssertLessThan(worst, 0.25)
    }
}
