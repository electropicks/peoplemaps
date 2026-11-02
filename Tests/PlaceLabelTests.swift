import XCTest
@testable import PeoplemapsCore

final class PlaceLabelTests: XCTestCase {
    private var index: SearchIndex { SearchTests.index }
    private func north(_ c: Coordinate, _ meters: Double) -> Coordinate { Coordinate(lat: c.lat + meters / 111_000, lon: c.lon) }

    func testNeighbourhoodOnlyWhenWithin800mAndClearlyNearest() {
        XCTAssertEqual(Neighbourhoods.nearest(to: Coordinate(lat: 47.6475, lon: -122.3036)), "Montlake", "Montlake Playfield")
        XCTAssertEqual(Neighbourhoods.nearest(to: north(Coordinate(lat: 47.668, lon: -122.384), 700)), "Ballard")
        XCTAssertNil(Neighbourhoods.nearest(to: north(Coordinate(lat: 47.668, lon: -122.384), 1_000)), "1 km from the centroid")
        XCTAssertNil(Neighbourhoods.nearest(to: Coordinate(lat: 47.637, lon: -122.336)), "Lake Union, 1.0 km from Eastlake")
        // Midway between Westlake and South Lake Union: either would be a guess.
        XCTAssertNil(Neighbourhoods.nearest(to: Coordinate(lat: 47.628, lon: -122.3395)))
        XCTAssertNil(Neighbourhoods.nearest(to: Coordinate(lat: 48.5, lon: -122.3)))
    }

    func testDroppedPinOnAPlaceTakesItsName() throws {
        let kerry = try XCTUnwrap(index.place(id: "node/693337509"))
        let pin = index.droppedPin(at: kerry.coordinate)
        XCTAssertEqual(pin.name, "Kerry Park")
        XCTAssertTrue(pin.isDroppedPin)
        XCTAssertEqual(pin.id, Place.droppedPin(at: kerry.coordinate).id)
    }

    func testDroppedPinNearButNotOnAPlaceSaysNear() throws {
        // Nitro North: a pin on it and 10 m south take its name; 60 m south the closest thing is 40 to 50 m away.
        let nitro = try XCTUnwrap(index.place(id: "way/1137900798"))
        XCTAssertEqual(index.droppedPin(at: north(nitro.coordinate, -10)).name, "Amazon.com Nitro North")
        let pin = index.droppedPin(at: north(nitro.coordinate, -60))
        XCTAssertEqual(pin.name, "Near Budget Car Rental")
        XCTAssertTrue(pin.isDroppedPin)
        XCTAssertEqual(index.droppedPin(at: north(nitro.coordinate, -100)).name, "2201 7th Avenue", "an address within 15 m is named plainly")
    }

    func testDroppedPinFarFromEverythingStaysDropped() {
        let lake = Coordinate(lat: 47.637, lon: -122.336)
        XCTAssertNil(index.nearestAddress(to: lake, within: 50))
        XCTAssertNil(index.nearestPlace(to: lake, within: 50))
        let pin = index.droppedPin(at: lake)
        XCTAssertEqual(pin.name, "Dropped pin")
        XCTAssertEqual(pin.coordinate, lake)
    }

    func testNearestPlaceRespectsTheRadius() throws {
        let nitro = try XCTUnwrap(index.place(id: "way/1137900798"))
        XCTAssertEqual(index.nearestPlace(to: nitro.coordinate)?.id, nitro.id)
        XCTAssertNil(index.nearestPlace(to: Coordinate(lat: 47.637, lon: -122.336), within: 50), "Lake Union")
        XCTAssertNotEqual(index.nearestPlace(to: north(nitro.coordinate, -60), within: 50)?.id, nitro.id)
    }
}
