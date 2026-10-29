import Foundation
import Observation
import PeoplemapsCore

/// Recents and favourites for the UI, written to Application Support after every change.
@MainActor @Observable
final class SavedPlacesStore {
    private(set) var saved: SavedPlaces
    private let url: URL

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var name = "saved-places.json"
        #if DEBUG
        // UI tests get their own file, emptied at launch unless a test checks that something survives a relaunch.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") {
            name = "saved-places-uitests.json"
            if !arguments.contains("--keep-saved") { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        }
        #endif
        url = folder.appendingPathComponent(name)
        saved = SavedPlaces.load(from: url)
    }

    var recents: [Place] { saved.recents }
    var favourites: [Place] { saved.favourites }
    func isFavourite(_ place: Place) -> Bool { saved.isFavourite(place) }

    /// Current location is never saved: it means somewhere else next time.
    func addRecent(_ place: Place) { guard !place.isCurrentLocation else { return }; change { $0.addRecent(place) } }
    func toggleFavourite(_ place: Place) { change { $0.toggleFavourite(place) } }
    func removeFavourite(_ place: Place) { change { $0.setFavourite(place, false) } }

    private func change(_ body: (inout SavedPlaces) -> Void) {
        body(&saved)
        try? saved.save(to: url)
    }
}

extension Place {
    static let pinCategory = "dropped pin", locationCategory = "current location"

    /// A long-press on the map. Named "Dropped pin" until the index can give the nearest address.
    static func droppedPin(at c: Coordinate) -> Place {
        Place(id: String(format: "pin/%.5f,%.5f", c.lat, c.lon), name: "Dropped pin", lat: c.lat, lon: c.lon, category: pinCategory)
    }
    /// Where the device was when the user picked it; the router snaps it to the nearest street for the mode.
    static func currentLocation(at c: Coordinate) -> Place {
        Place(id: "current-location", name: "Current location", lat: c.lat, lon: c.lon, category: locationCategory)
    }
    var isDroppedPin: Bool { category == Self.pinCategory }
    var isCurrentLocation: Bool { category == Self.locationCategory }
    /// "47.62950° N, 122.35990° W"
    var coordinateLabel: String {
        String(format: "%.5f° %@, %.5f° %@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
    }
}
