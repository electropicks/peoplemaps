import XCTest
@testable import PeoplemapsCore

final class SharedLinkMatchTests: XCTestCase {
    private var index: SearchIndex { SearchTests.index }
    private let everywhere: (Coordinate) -> Bool = { _ in true }
    /// About `meters` north of `c`.
    private func north(_ c: Coordinate, _ meters: Double) -> Coordinate { Coordinate(lat: c.lat + meters / 111_000, lon: c.lon) }

    func testNameNearTheSharedPointIsOurOwnRecord() throws {
        let ours = try XCTUnwrap(index.search("broadcast coffee", near: SearchTests.fremont).first)
        let stop = SharedStop(name: "Broadcast Coffee Roasters", address: "1 Nowhere St, Seattle, WA", coordinate: north(ours.coordinate, 30))
        XCTAssertEqual(index.match(stop, covers: everywhere), .place(ours))
        XCTAssertEqual(ours.source, "Overture (Foursquare), Oct 2026", "what shows is our record and its source")
    }

    func testSameNameFarFromTheSharedPointIsAPinNotAGuess() throws {
        let ours = try XCTUnwrap(index.search("broadcast coffee", near: SearchTests.fremont).first)
        let point = north(ours.coordinate, 900)
        guard case let .pin(pin) = index.match(SharedStop(name: "Broadcast Coffee", coordinate: point), covers: everywhere) else { return XCTFail() }
        XCTAssertEqual(pin.coordinate, point)
        XCTAssertEqual(pin.category, Place.pinCategory)
        XCTAssertFalse(pin.name.contains("Broadcast"), "named from what we have there, never from the link")
    }

    func testAddressMatchesAcrossAbbreviations() throws {
        let ours = try XCTUnwrap(index.search("3400 Fremont Ave N").first)
        XCTAssertEqual(ours.kind, .address)
        let stop = SharedStop(name: "Somewhere We Lack", address: "3400 Fremont Ave N\nSeattle, WA  98103\nUnited States", coordinate: north(ours.coordinate, 40))
        XCTAssertEqual(index.match(stop, covers: everywhere), .place(ours))
        XCTAssertEqual(index.match(SharedStop(name: "3400 Fremont Ave N, Seattle"), covers: everywhere), .place(ours), "a route stop is text only")
        XCTAssertTrue(SearchIndex.sameAddress("400 E Pine St", "400 East Pine Street"))
        XCTAssertTrue(SearchIndex.sameAddress("12 Elm Blvd", "12 Elm Boulevard"))
        XCTAssertFalse(SearchIndex.sameAddress("400 E Pine St", "402 East Pine Street"))
        XCTAssertFalse(SearchIndex.sameAddress("400 E Pine St", "400 East Pike Street"))
    }

    func testLooseNameOffersTheSearchAndThePin() throws {
        let ours = try XCTUnwrap(index.search("broadcast coffee", near: SearchTests.fremont).first)
        let point = north(ours.coordinate, 150)
        guard case let .candidates(query, near, pin) = index.match(SharedStop(name: "Broadcast Coffee", coordinate: point), covers: everywhere) else { return XCTFail() }
        XCTAssertEqual(query, "Broadcast Coffee")
        XCTAssertEqual(near, point)
        XCTAssertEqual(pin?.coordinate, point)
    }

    func testTextOnlyNameIsASearchNearThePerson() {
        XCTAssertEqual(index.match(SharedStop(name: "Gas Works Park"), covers: everywhere, near: SearchTests.fremont),
                       .candidates(query: "Gas Works Park", near: SearchTests.fremont, pin: nil))
        XCTAssertEqual(index.match(SharedStop(name: "Zzyzx Qwerty Emporium"), covers: everywhere), .candidates(query: "Zzyzx Qwerty Emporium", near: nil, pin: nil))
    }

    func testAMapViewIsNeverTreatedAsThePlace() throws {
        let ours = try XCTUnwrap(index.search("broadcast coffee", near: SearchTests.fremont).first)
        let view = SharedStop(name: "Broadcast Coffee", coordinate: north(ours.coordinate, 20), exact: false)
        XCTAssertEqual(index.match(view, covers: everywhere), .candidates(query: "Broadcast Coffee", near: view.coordinate, pin: nil))
    }

    func testPointAloneIsADroppedPinAndOutsideSaysSo() {
        let point = SearchTests.fremont
        XCTAssertEqual(index.match(SharedStop(coordinate: point), covers: everywhere), .pin(index.droppedPin(at: point)))
        XCTAssertEqual(index.match(SharedStop(name: "Pike Place", coordinate: Coordinate(lat: 45.5, lon: -122.6)), covers: { $0.lat > 47 }), .outside)
    }

    func testShortLinkExpandsThroughAllowedHostsOnly() async {
        let asked = Asked()
        let chain = ["https://maps.app.goo.gl/abc": "https://goo.gl/maps/def", "https://goo.gl/maps/def": "https://www.google.com/maps/place/Space+Needle/data=!3d47.6205!4d-122.3493"]
        let expander = SharedLinkExpander { url in await asked.add(url); return chain[url.absoluteString].flatMap(URL.init) }
        let found = await expander.expand(URL(string: "https://maps.app.goo.gl/abc")!)
        XCTAssertEqual(found, .place(SharedStop(name: "Space Needle", coordinate: Coordinate(lat: 47.6205, lon: -122.3493))))
        let hosts = await asked.urls.map { $0.host }
        XCTAssertEqual(hosts, ["maps.app.goo.gl", "goo.gl"])
    }

    func testExpansionStopsAtAnythingElse() async {
        let asked = Asked()
        let offline = await SharedLinkExpander { url in await asked.add(url); return nil }.expand(URL(string: "https://maps.apple/p/x")!, text: "Space Needle")
        XCTAssertEqual(offline, .unreadable(text: "Space Needle"))
        let elsewhere = await SharedLinkExpander { _ in URL(string: "https://consent.example.com/?continue=x") }.expand(URL(string: "https://maps.apple/p/x")!)
        XCTAssertEqual(elsewhere, .unreadable(text: nil))
        let notShort = await SharedLinkExpander { url in await asked.add(url); return nil }.expand(URL(string: "https://example.com/p/x")!)
        XCTAssertEqual(notShort, .unreadable(text: nil))
        let count = await asked.urls.count
        XCTAssertEqual(count, 1, "a host off the list is never contacted")
        let loop = await SharedLinkExpander { url in await asked.add(url); return url }.expand(URL(string: "https://maps.apple/p/x")!)
        XCTAssertEqual(loop, .unreadable(text: nil))
        let total = await asked.urls.count
        XCTAssertEqual(total, 4, "three hops at most")
    }

    private actor Asked { var urls: [URL] = []; func add(_ url: URL) { urls.append(url) } }
}
