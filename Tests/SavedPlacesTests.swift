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
