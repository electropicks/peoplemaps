import XCTest
@testable import PeoplemapsCore

final class SavedPlacesTests: XCTestCase {
    private func place(_ n: Int, lat: Double = 47.64) -> Place { Place(id: "node/\(n)", name: "Place \(n)", lat: lat, lon: -122.35, category: "park") }

    func testRecentsAreNewestFirstWithoutDuplicates() {
        var saved = SavedPlaces()
        saved.addRecent(place(1)); saved.addRecent(place(2)); saved.addRecent(place(1))
        XCTAssertEqual(saved.recents.map(\.id), ["node/1", "node/2"])
    }

    func testRecentsKeepOnlyTheLastTen() {
        var saved = SavedPlaces()
        for n in 1...13 { saved.addRecent(place(n)) }
        XCTAssertEqual(saved.recents.count, SavedPlaces.recentLimit)
        XCTAssertEqual(saved.recents.first?.id, "node/13")
        XCTAssertEqual(saved.recents.last?.id, "node/4")
    }

    func testSameIDAtAnotherSpotIsAnotherPlace() {
        var saved = SavedPlaces()
        saved.addRecent(place(1)); saved.addRecent(place(1, lat: 47.65))
        XCTAssertEqual(saved.recents.count, 2)
        saved.setFavourite(place(1), true)
        XCTAssertFalse(saved.isFavourite(place(1, lat: 47.65)))
    }

    func testNamingAnAddressKeepsItAsAFavouriteFoundByThatName() {
        var saved = SavedPlaces()
        let address = Place(id: "node/4400510992", name: "400 East Pine Street, Unit 100", lat: 47.61538, lon: -122.32660, category: "address", kind: .address)
        saved.addRecent(address)
        let named = saved.name(address, "  Kelley-Ross Pharmacy ")
        XCTAssertEqual(named.name, "Kelley-Ross Pharmacy")
        XCTAssertEqual(named.address, "400 East Pine Street, Unit 100")
        XCTAssertEqual(named.kind, .address)
        XCTAssertEqual(saved.favourites, [named])
        XCTAssertEqual(saved.recents, [named])
        XCTAssertEqual(saved.favourite(at: address), named)
        XCTAssertTrue(saved.hasOwnName(address))
        // The card may have filled in the building's address; the whole address is still what is kept.
        var other = SavedPlaces(), unit = address
        unit.address = "400 East Pine Street"
        XCTAssertEqual(other.name(unit, "Pharmacy").address, "400 East Pine Street, Unit 100")
        // A file saved before names existed still reads, and removing the favourite forgets the name was the user's.
        let old = try! JSONDecoder().decode(SavedPlaces.self, from: Data(#"{"recents":[],"favourites":[]}"#.utf8))
        XCTAssertFalse(old.hasOwnName(address))
        other.setFavourite(unit, false)
        XCTAssertFalse(other.hasOwnName(unit))
        XCTAssertEqual(saved.matching("kelley ross"), [named], "once, though it is a favourite and a recent")
        XCTAssertEqual(saved.matching("pharm kel"), [named])
        XCTAssertTrue(saved.matching("ross dress").isEmpty)
        XCTAssertTrue(saved.matching(" ").isEmpty)
        // The place mapped at that address shares its OSM ID and point, and is not the address.
        let centre = Place(id: address.id, name: "Seattle's LGBTQ+ Center", lat: address.lat, lon: address.lon, category: "social_facility", address: "400 East Pine Street")
        XCTAssertNil(saved.favourite(at: centre))
        XCTAssertFalse(saved.isFavourite(centre))
        // Renaming keeps the address, and a blank name changes nothing.
        let again = saved.name(named, "My pharmacy")
        XCTAssertEqual(again.address, "400 East Pine Street, Unit 100")
        XCTAssertEqual(saved.favourites.map(\.name), ["My pharmacy"])
        XCTAssertEqual(saved.name(again, "  ").name, "My pharmacy")
        // A pin named from what is near keeps that as where it is; a bare pin has nothing to keep.
        let pin = Place(id: "pin/47.62000,-122.32000", name: "Near 12 Example Street", lat: 47.62, lon: -122.32, category: Place.pinCategory)
        XCTAssertEqual(saved.name(pin, "Trailhead").address, "Near 12 Example Street")
        XCTAssertNil(saved.name(Place.droppedPin(at: Coordinate(lat: 47.63, lon: -122.33)), "Bench").address)
    }

    func testFavouritesToggleAndKeepTheirOrder() {
        var saved = SavedPlaces()
        saved.toggleFavourite(place(1)); saved.toggleFavourite(place(2)); saved.setFavourite(place(1), true)
        XCTAssertEqual(saved.favourites.map(\.id), ["node/2", "node/1"])
        saved.toggleFavourite(place(2))
        XCTAssertEqual(saved.favourites.map(\.id), ["node/1"])
        XCTAssertFalse(saved.isFavourite(place(2)))
    }

    func testSurvivesARoundTripThroughAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("saved.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var saved = SavedPlaces()
        saved.addRecent(place(1)); saved.addRecent(place(2)); saved.setFavourite(place(3), true)
        try saved.save(to: url)
        let loaded = SavedPlaces.load(from: url)
        XCTAssertEqual(loaded, saved)
        XCTAssertTrue(loaded.isFavourite(place(3)))
    }

    func testMissingOrCorruptFileStartsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(SavedPlaces.load(from: url), SavedPlaces())
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(SavedPlaces.load(from: url), SavedPlaces())
    }
}
