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
    func favourite(at place: Place) -> Place? { saved.favourite(at: place) }
    func matching(_ query: String) -> [Place] { saved.matching(query) }
    func hasOwnName(_ place: Place) -> Bool { saved.hasOwnName(place) }
    func name(_ place: Place, _ name: String) -> Place {
        var named = place
        change { named = $0.name(place, name) }
        return named
    }

    private func change(_ body: (inout SavedPlaces) -> Void) {
        body(&saved)
        try? saved.save(to: url)
    }
}
