import Foundation

/// Recent destinations and favourites, kept on the device. A place is the same place when its ID and coordinates match.
public struct SavedPlaces: Codable, Equatable, Sendable {
    public static let recentLimit = 10

    /// Newest first.
    public private(set) var recents: [Place] = []
    /// In the order they were added.
    public private(set) var favourites: [Place] = []

    /// Keys of the favourites the user named. Optional so a file saved before names existed still reads.
    private var ownNames: Set<String>?

    public init() {}

    /// Our place ID plus coordinates to about a metre, so a pin dropped twice in one spot is one place. An address is not the
    /// place mapped at it, though both carry one OSM ID ("400 East Pine Street, Unit 100" and the centre in that unit).
    public static func key(_ place: Place) -> String {
        String(format: "%@@%.5f,%.5f", place.id, place.lat, place.lon) + (place.kind == .address ? "#address" : "")
    }

    public func isFavourite(_ place: Place) -> Bool { favourites.contains { Self.key($0) == Self.key(place) } }

    /// Moves the place to the front, dropping the oldest past the limit.
    public mutating func addRecent(_ place: Place) {
        recents.removeAll { Self.key($0) == Self.key(place) }
        recents.insert(place, at: 0)
        if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
    }

    public mutating func setFavourite(_ place: Place, _ on: Bool) {
        favourites.removeAll { Self.key($0) == Self.key(place) }
        if on { favourites.append(place) } else { ownNames?.remove(Self.key(place)) }
    }

    public mutating func toggleFavourite(_ place: Place) { setFavourite(place, !isFavourite(place)) }

    /// The favourite at this place, which may carry the user's own name for it.
    public func favourite(at place: Place) -> Place? { favourites.first { Self.key($0) == Self.key(place) } }

    /// Keeps the place as a favourite under the user's own name ("Kelley-Ross Pharmacy" for "400 East Pine Street"),
    /// in recents too, and returns it. What it was called stays as its address, so the card still says where it is.
    /// A blank name changes nothing.
    @discardableResult public mutating func name(_ place: Place, _ name: String) -> Place {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != place.name else { return place }
        // An address's own name is the whole of it ("..., Unit 100"); its `address` may be the building's.
        let whereItIs = place.kind == .address || (place.isDroppedPin && place.name != Place.pinName) ? place.name : place.address
        let address = hasOwnName(place) ? place.address : whereItIs
        ownNames = (ownNames ?? []).union([Self.key(place)])
        let named = Place(id: place.id, name: String(name.prefix(Self.nameLimit)), lat: place.lat, lon: place.lon, category: place.category,
                          kind: place.kind, address: address, source: place.source)
        if let at = favourites.firstIndex(where: { Self.key($0) == Self.key(place) }) { favourites[at] = named } else { favourites.append(named) }
        if let at = recents.firstIndex(where: { Self.key($0) == Self.key(place) }) { recents[at] = named }
        return named
    }
    public static let nameLimit = 60
    /// The user named this favourite.
    public func hasOwnName(_ place: Place) -> Bool { ownNames?.contains(Self.key(place)) ?? false }

    /// Favourites, then recents, whose name has each word of `query` at the start of one of its words, so a place
    /// saved under the user's own name is found by it. The index is searched separately.
    public func matching(_ query: String) -> [Place] {
        let words = SearchIndex.normalize(query).split(separator: " ")
        guard !words.isEmpty else { return [] }
        var seen = Set<String>()
        return (favourites + recents).filter { place in
            let name = SearchIndex.normalize(place.name).split(separator: " ")
            return words.allSatisfy { word in name.contains { $0.hasPrefix(word) } } && seen.insert(Self.key(place)).inserted
        }
    }

    /// Reads a saved file; a missing or unreadable one starts empty.
    public static func load(from url: URL) -> SavedPlaces {
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SavedPlaces.self, from: data) else { return SavedPlaces() }
        return saved
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
