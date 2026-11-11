import XCTest
@testable import PeoplemapsCore

final class SharedLinkTests: XCTestCase {
    private let needle = Coordinate(lat: 47.6205, lon: -122.3493)
    private func place(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> SharedStop? {
        guard case let .place(stop) = SharedLink.parse(text) else { XCTFail("not a place: \(String(describing: SharedLink.parse(text)))", file: file, line: line); return nil }
        return stop
    }

    func testOrdinarySearchTextIsNotALink() {
        for text in ["", "coffee", "3400 Fremont Ave N", "400 E Pine St\nSte 100\nSeattle, WA  98122\nUnited States", "3400, 2", "47, -122",
                     "https://example.com/maps/place/x", "https://www.google.com/search?q=maps"] {
            XCTAssertNil(SharedLink.parse(text), text)
        }
    }

    func testPastedCoordinates() {
        XCTAssertEqual(place("47.6205, -122.3493"), SharedStop(coordinate: needle))
        XCTAssertEqual(place(" 47.6205 -122.3493\n"), SharedStop(coordinate: needle))
        XCTAssertEqual(place("47.6205° N, 122.3493° W"), SharedStop(coordinate: needle))
        XCTAssertNil(SharedLink.parse("91.5, 10.5"), "not a latitude")
    }

    func testAppleUnifiedPlace() {
        let stop = place("https://maps.apple.com/place?address=400%20Broad%20St,%20Seattle,%20WA%2098109&coordinate=47.6205,-122.3493&name=Space%20Needle&place-id=I1234&map=explore")
        XCTAssertEqual(stop, SharedStop(name: "Space Needle", address: "400 Broad St, Seattle, WA 98109", coordinate: needle))
    }

    func testAppleLegacyPlace() {
        XCTAssertEqual(place("https://maps.apple.com/?address=400+Broad+St&ll=47.6205,-122.3493&q=Space+Needle&t=m"),
                       SharedStop(name: "Space Needle", address: "400 Broad St", coordinate: needle))
        XCTAssertEqual(place("maps://?q=47.6205,-122.3493"), SharedStop(coordinate: needle))
        XCTAssertEqual(place("http://maps.apple.com/?q=Gas+Works+Park&sll=47.649,-122.349"), SharedStop(name: "Gas Works Park"), "sll is the search centre, not the place")
    }

    func testAppleDirectionsWithWaypoints() {
        let link = SharedLink.parse("https://maps.apple.com/directions?source=47.6062,-122.3321&destination=Gas%20Works%20Park&waypoint=47.6205,-122.3493&waypoint=3400%20Fremont%20Ave%20N&mode=cycling")
        XCTAssertEqual(link, .route(origin: SharedStop(coordinate: Coordinate(lat: 47.6062, lon: -122.3321)),
                                    stops: [SharedStop(coordinate: needle), SharedStop(name: "3400 Fremont Ave N"), SharedStop(name: "Gas Works Park")], mode: .bike))
        XCTAssertEqual(SharedLink.parse("https://maps.apple.com/?daddr=Gas+Works+Park&dirflg=w"),
                       .route(origin: nil, stops: [SharedStop(name: "Gas Works Park")], mode: .walk))
        XCTAssertEqual(SharedLink.parse("https://maps.apple.com/directions?destination=Gas%20Works%20Park&mode=transit"),
                       .route(origin: nil, stops: [SharedStop(name: "Gas Works Park")], mode: nil), "no transit here")
    }

    func testShortLinksNeedExpandingAndKeepTheirText() {
        XCTAssertEqual(SharedLink.parse("https://maps.apple/p/U8rE9v8n8iVZjr"), .short(URL(string: "https://maps.apple/p/U8rE9v8n8iVZjr")!, text: nil))
        XCTAssertEqual(SharedLink.parse("Space Needle\n400 Broad St\nhttps://maps.app.goo.gl/AbCdEf123?g_st=ic"),
                       .short(URL(string: "https://maps.app.goo.gl/AbCdEf123?g_st=ic")!, text: "Space Needle, 400 Broad St"))
        XCTAssertEqual(SharedLink.parse("https://goo.gl/maps/AbCdEf"), .short(URL(string: "https://goo.gl/maps/AbCdEf")!, text: nil))
        XCTAssertNil(SharedLink.parse("https://goo.gl/AbCdEf"), "not a maps link")
        XCTAssertNil(SharedLink.parse("http://maps.apple/p/U8rE9v8n8iVZjr"), "https only")
        XCTAssertNil(SharedLink.parse("https://maps.apple.evil.example/p/x"))
    }

    func testGooglePlaceTakesThePinNotTheView() {
        let stop = place("https://www.google.com/maps/place/Space+Needle/@47.6215,-122.3510,17z/data=!3m1!4b1!4m6!3m5!1s0x5490151f:0x4fb!8m2!3d47.6205!4d-122.3493!16zL20vMGJ0?entry=ttu")
        XCTAssertEqual(stop, SharedStop(name: "Space Needle", coordinate: needle))
        let viewOnly = place("https://www.google.com/maps/place/Space+Needle/@47.6215,-122.351,17z")
        XCTAssertEqual(viewOnly, SharedStop(name: "Space Needle", coordinate: Coordinate(lat: 47.6215, lon: -122.351), exact: false))
        XCTAssertEqual(place("https://www.google.com/maps/place/47.6205,-122.3493"), SharedStop(coordinate: needle))
    }

    func testGoogleSearchAndQueryForms() {
        XCTAssertEqual(place("https://www.google.com/maps/search/?api=1&query=47.6205%2C-122.3493"), SharedStop(coordinate: needle))
        XCTAssertEqual(place("https://www.google.com/maps/search/?api=1&query=Kelley-Ross+Pharmacy&query_place_id=ChIJabc"), SharedStop(name: "Kelley-Ross Pharmacy"))
        XCTAssertEqual(place("https://maps.google.com/?q=47.6205,-122.3493"), SharedStop(coordinate: needle))
        XCTAssertEqual(place("https://www.google.com/maps/search/coffee/@47.65,-122.35,15z"), SharedStop(name: "coffee"), "a search's view is not a place")
        XCTAssertEqual(place("comgooglemaps://?q=Gas+Works+Park"), SharedStop(name: "Gas Works Park"))
    }

    func testGoogleDirections() {
        XCTAssertEqual(SharedLink.parse("https://www.google.com/maps/dir/?api=1&origin=Pike+Place+Market&destination=Gas+Works+Park&waypoints=47.6205,-122.3493%7CFremont+Troll&travelmode=bicycling"),
                       .route(origin: SharedStop(name: "Pike Place Market"),
                              stops: [SharedStop(coordinate: needle), SharedStop(name: "Fremont Troll"), SharedStop(name: "Gas Works Park")], mode: .bike))
        XCTAssertEqual(SharedLink.parse("https://www.google.com/maps/dir/Pike+Place+Market/Space+Needle,+400+Broad+St/47.6456,-122.3344/@47.63,-122.35,13z/data=!3m1!4b1!4m2!4m1!3e0"),
                       .route(origin: SharedStop(name: "Pike Place Market"),
                              stops: [SharedStop(name: "Space Needle, 400 Broad St"), SharedStop(coordinate: Coordinate(lat: 47.6456, lon: -122.3344))], mode: nil))
        XCTAssertEqual(SharedLink.parse("https://www.google.com/maps/dir//Gas+Works+Park/@47.64,-122.33,15z"),
                       .route(origin: nil, stops: [SharedStop(name: "Gas Works Park")], mode: nil), "an empty first stop is where the person is")
    }

    func testWazeOpenStreetMapAndGeo() {
        XCTAssertEqual(place("https://waze.com/ul?ll=47.6205%2C-122.3493&navigate=yes"), SharedStop(coordinate: needle))
        XCTAssertEqual(place("https://ul.waze.com/ul?q=Gas%20Works%20Park"), SharedStop(name: "Gas Works Park"))
        XCTAssertEqual(place("https://www.openstreetmap.org/?mlat=47.6205&mlon=-122.3493#map=17/47.6200/-122.3500"), SharedStop(coordinate: needle))
        XCTAssertEqual(place("https://www.openstreetmap.org/#map=17/47.6205/-122.3493"), SharedStop(coordinate: needle, exact: false))
        XCTAssertEqual(place("geo:47.6205,-122.3493"), SharedStop(coordinate: needle))
        XCTAssertEqual(place("geo:47.6205,-122.3493,120;u=35?z=17"), SharedStop(coordinate: needle))
        XCTAssertEqual(place("geo:0,0?q=47.6205,-122.3493(Space%20Needle)"), SharedStop(name: "Space Needle", coordinate: needle))
        XCTAssertEqual(place("geo:0,0?q=400+Broad+St"), SharedStop(name: "400 Broad St"))
    }

    func testAKnownMapsHostWeCannotReadSaysSo() {
        XCTAssertEqual(SharedLink.parse("Dinner https://maps.apple.com/guides?user=abc"), .unreadable(text: "Dinner"))
        XCTAssertEqual(SharedLink.parse("https://www.google.com/maps/contrib/123"), .unreadable(text: nil))
    }
}
