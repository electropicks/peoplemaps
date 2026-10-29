import Foundation

/// Recent destinations and favourites, kept on the device. A place is the same place when its ID and coordinates match.
public struct SavedPlaces: Codable, Equatable, Sendable {
    public static let recentLimit = 10

    /// Newest first.
    public private(set) var recents: [Place] = []
    /// In the order they were added.
    public private(set) var favourites: [Place] = []

    public init() {}

    /// Our place ID plus coordinates to about a metre, so a pin dropped twice in one spot is one place.
    public static func key(_ place: Place) -> String { String(format: "%@@%.5f,%.5f", place.id, place.lat, place.lon) }

    public func isFavourite(_ place: Place) -> Bool { favourites.contains { Self.key($0) == Self.key(place) } }

    /// Moves the place to the front, dropping the oldest past the limit.
    public mutating func addRecent(_ place: Place) {
        recents.removeAll { Self.key($0) == Self.key(place) }
        recents.insert(place, at: 0)
        if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
    }

    public mutating func setFavourite(_ place: Place, _ on: Bool) {
        favourites.removeAll { Self.key($0) == Self.key(place) }
        if on { favourites.append(place) }
    }

    public mutating func toggleFavourite(_ place: Place) { setFavourite(place, !isFavourite(place)) }

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
