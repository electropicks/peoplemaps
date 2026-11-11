import XCTest
@testable import PeoplemapsCore

final class SearchTests: XCTestCase {
    static let graph = try! StreetGraph.bundled()
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peoplemaps-search-tests")
    static let index = try! SearchIndex.bundled(graphNodes: graph.nodes.count, directory: directory)
    static let fremont = Coordinate(lat: 47.651, lon: -122.350)
    private var index: SearchIndex { Self.index }

    func testOpensWithPlacesAddressesAndSource() {
        XCTAssertGreaterThan(index.count, 60_000)
        XCTAssertTrue(index.source.hasPrefix("OpenStreetMap, "), index.source)
        XCTAssertTrue(index.search("").isEmpty)
        XCTAssertTrue(index.search("  ,. ").isEmpty)
    }
    func testOvertureBusinessIsFoundByNameWithItsOwnSource() throws {
        // Overture-only: no OSM place has this name. Foursquare's record, dated by the release, not by the record.
        let hit = try XCTUnwrap(index.search("broadcast coffee", near: Self.fremont).first)
        XCTAssertEqual(hit.name, "Broadcast Coffee")
        XCTAssertEqual(hit.id, "overture/e1fb6a43-f757-4588-bdae-60ea3637cc69")
        XCTAssertEqual(hit.category, "cafe")
        XCTAssertNil(hit.address, "addresses come from OSM only")
        XCTAssertEqual(hit.source, "Overture (Foursquare), Oct 2026")
        XCTAssertEqual(index.place(id: hit.id)?.name, "Broadcast Coffee")
        XCTAssertEqual(Set(hit.snap.keys), Set(TravelMode.allCases), "snapped to routable nodes like OSM rows")
        let osm = try XCTUnwrap(index.search("gas works").first)
        XCTAssertEqual(osm.source, "OpenStreetMap, Oct 2026")
        XCTAssertEqual(try XCTUnwrap(index.search("3400 Fremont Ave N").first).source, "OpenStreetMap, Oct 2026")
    }
    func testOvertureDuplicateOfAnOSMPlaceAppearsOnce() {
        // Overture also lists Chutneys Bistro (id 01021a76-...) at the same spot; the OSM place keeps the row.
        let hits = index.search("chutneys bistro", near: Self.fremont).filter { $0.name == "Chutneys Bistro" }
        XCTAssertEqual(hits.map(\.id), ["node/3033233528"])
        XCTAssertEqual(hits.first?.source, "OpenStreetMap, Oct 2026")
        XCTAssertNil(index.place(id: "overture/01021a76-cb85-4ca2-9bca-7b42301517ff"))
    }
    func testReopeningReusesTheInflatedFile() throws {
        let again = try SearchIndex.bundled(graphNodes: Self.graph.nodes.count, directory: Self.directory)
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
    func testNearestAddressForAPlaceWithoutOne() throws {
        // Amazon.com Nitro North has no address in OSM; the nearest mapped one is about 20 m away.
        let nitro = try XCTUnwrap(index.place(id: "way/1137900798"))
        XCTAssertNil(nitro.address)
        let near = try XCTUnwrap(index.nearestAddress(to: nitro.coordinate, within: 40))
        XCTAssertEqual(near.kind, .address)
        XCTAssertEqual(near.id, "node/10964497269")
        XCTAssertEqual(near.coordinate.distance(to: nitro.coordinate), 19.5, accuracy: 1)
        XCTAssertEqual(index.nearestAddress(to: nitro.coordinate)?.id, near.id, "40 m by default")
        XCTAssertNil(index.nearestAddress(to: nitro.coordinate, within: 15))
    }
    func testNearestAddressPrefersTheBuildingOverAUnit() throws {
        // A unit row and its building's row share one point.
        let spot = Coordinate(lat: 47.6179645, lon: -122.3140016)
        XCTAssertEqual(index.nearestAddress(to: spot, within: 5)?.name, "1808 14th Avenue")
    }
    func testNearestAddressIsNilFarFromAny() {
        XCTAssertNil(index.nearestAddress(to: Coordinate(lat: 47.637, lon: -122.336), within: 40), "middle of Lake Union")
    }
    func testCategoryWordsFindPlacesByCategoryBelowNameMatches() {
        for (query, category) in [("gas station", "fuel"), ("gas stations", "fuel"), ("petrol", "fuel"), ("coffee shop", "cafe"),
                                  ("grocery", "supermarket"), ("pharmacy", "pharmacy"), ("drugstore", "pharmacy")] {
            let hits = index.search(query, near: Self.fremont)
            XCTAssertGreaterThanOrEqual(hits.count, 5, query)
            XCTAssertTrue(hits.prefix(30).contains { $0.category == category }, query)
        }
        let restaurants = index.search("restaurants", near: Self.fremont)
        XCTAssertTrue(restaurants.contains { $0.category == "thai_restaurant" || $0.category == "restaurant" })
        XCTAssertTrue(restaurants.allSatisfy { $0.kind == .place })
    }
    func testCategoryMatchesComeAfterNameMatches() throws {
        let hits = index.search("gas", near: Self.fremont)
        let named: (Place) -> Bool = { SearchIndex.normalize($0.name).split(separator: " ").contains { $0.hasPrefix("gas") } }
        XCTAssertEqual(hits.first?.name, "Gas Works Park", "a name match stays first")
        let shell = try XCTUnwrap(hits.firstIndex { $0.category == "fuel" && !named($0) })
        XCTAssertGreaterThan(shell, try XCTUnwrap(hits.lastIndex(where: named)))
        XCTAssertLessThan(shell, 30, "ahead of text found only in a category such as gastroenterology")
        XCTAssertEqual(Set(hits.map(\.id)).count, hits.count, "no duplicates")
        XCTAssertEqual(index.search("coffee", near: Self.fremont).first?.name.lowercased().contains("coffee"), true)
        XCTAssertEqual(index.search("gas station", near: Self.fremont).first?.category, "fuel")
    }
    func testNonCategoryQueriesAreUnchanged() {
        XCTAssertTrue(index.search("zzzz qqqq").isEmpty)
        XCTAssertEqual(index.search("gas works").first?.id, "relation/1047789")
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
    func testPastedPostalAddress() throws {
        // As Apple Maps and Google Maps copy it: the unit mid-way, then city, state, ZIP and country, none of them indexed.
        let pasted = try XCTUnwrap(index.search("400 E Pine St\nSte 100\nSeattle, WA 98122\nUnited States").first)
        XCTAssertEqual(pasted.name, "400 East Pine Street, Unit 100")
        for query in ["400 E Pine St, Seattle, WA 98122", "400 E Pine St Seattle WA 98122-2316 USA", "400 East Pine Street, Seattle, Washington",
                      "400 e pine st seattle", "400 E Pine St, Seattle, WA 98122, United States of America"] {
            XCTAssertEqual(index.search(query).first?.name, "400 East Pine Street", query)
        }
        XCTAssertEqual(index.search("400 E Pine St #100, Seattle, WA").first?.name, "400 East Pine Street, Unit 100")
        // A name the index doesn't have, in front of an address it does.
        XCTAssertEqual(index.search("Kelley-Ross Pharmacy, 400 E Pine St Ste 100, Seattle, WA 98122").first?.name, "400 East Pine Street, Unit 100")
        // A typo in the street, and a number that isn't mapped: the nearest on that street, as when typed alone.
        XCTAssertEqual(index.search("400 E Pien St, Seattle, WA 98122").first?.name, "400 East Pine Street")
        XCTAssertEqual(index.search("3329 Fremont Ave N, Seattle, WA 98103").map(\.name).prefix(3), index.search("3329 Fremont Ave N").map(\.name).prefix(3))
        // No address in it, or no such street: still nothing, never a guess from the number alone.
        XCTAssertTrue(index.search("Kelley-Ross Pharmacy Seattle WA 98122").isEmpty)
        XCTAssertTrue(index.search("400 Zzyzx Qqqqx Rd, Seattle, WA 98122").isEmpty)
    }
    func testAddressReadingsAndUnits() {
        XCTAssertEqual(SearchIndex.addressReadings(["400", "e", "pine", "st", "seattle", "wa", "98122", "united", "states"]),
                       [["400", "e", "pine", "st", "seattle"], ["400", "e", "pine", "st"], ["400", "e", "pine"]])
        XCTAssertEqual(SearchIndex.addressReadings(["cafe", "12", "main", "st", "98122", "2316"]), [["12", "main", "st"]])
        XCTAssertTrue(SearchIndex.addressReadings(["gas", "works", "park", "seattle"]).isEmpty)
        XCTAssertEqual(SearchIndex.splitUnit("400 E Pine St\nSte 100\nSeattle", anywhere: true).1, "100")
        XCTAssertEqual(SearchIndex.splitUnit("400 E Pine St Apt B Seattle", anywhere: true).1, "B")
        XCTAssertNil(SearchIndex.splitUnit("12 Suite Life Rd Seattle", anywhere: true).1)
        XCTAssertNil(SearchIndex.splitUnit("1900 Stewart").1, "a street that starts like \"ste\" is not a unit")
        XCTAssertEqual(SearchIndex.splitUnit("3400 Fremont Ave N unit2").1, "2")
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
        let distances = cafes.filter { $0.category == cafes[0].category && $0.source == cafes[0].source }.map { $0.coordinate.distance(to: Self.fremont) }
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
    /// A dropped letter in a short word, as the scout typed it.
    func testTypoFallbackFindsGasWorksFromGasWrks() {
        XCTAssertTrue(index.search("Gas Wrks").contains { $0.name == "Gas Works Park" }, "\(index.search("Gas Wrks").map(\.name))")
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
