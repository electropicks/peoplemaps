import Foundation

/// Approximate neighbourhood centroids, enough to label a place; not boundaries.
public enum Neighbourhoods {
    public static let table: [(name: String, lat: Double, lon: Double)] = [
        ("Ballard", 47.668, -122.384), ("Fremont", 47.651, -122.350), ("Wallingford", 47.655, -122.335),
        ("Queen Anne", 47.637, -122.357), ("Westlake", 47.632, -122.343), ("South Lake Union", 47.624, -122.336),
        ("Eastlake", 47.637, -122.322), ("University District", 47.661, -122.313), ("Green Lake", 47.676, -122.326),
        ("Phinney Ridge", 47.672, -122.355), ("Capitol Hill", 47.623, -122.314), ("Interbay", 47.640, -122.378),
        ("Montlake", 47.643, -122.304),
    ]
    public static let maxMeters = 800.0
    /// The runner-up must be at least this many times farther, or the point sits between two and neither is honest.
    public static let clearMargin = 1.5

    /// The nearest centroid when it is within 800 m and clearly nearer than any other, else nil: with centroids
    /// only, a label that might be wrong is left off.
    public static func nearest(to c: Coordinate) -> String? {
        let ranked = table.map { ($0.name, c.distance(to: Coordinate(lat: $0.lat, lon: $0.lon))) }.sorted { $0.1 < $1.1 }
        guard let first = ranked.first, first.1 <= maxMeters, ranked.count < 2 || ranked[1].1 >= clearMargin * first.1 else { return nil }
        return first.0
    }
}

extension Place {
    public static let pinCategory = "dropped pin", locationCategory = "current location", pinName = "Dropped pin"

    /// A long-press on the map with no name; `SearchIndex.droppedPin(at:)` names it from the nearest address or place.
    public static func droppedPin(at c: Coordinate) -> Place {
        Place(id: String(format: "pin/%.5f,%.5f", c.lat, c.lon), name: pinName, lat: c.lat, lon: c.lon, category: pinCategory)
    }
    /// Where the device was when the user picked it; the router snaps it to the nearest street for the mode.
    public static func currentLocation(at c: Coordinate) -> Place {
        Place(id: "current-location", name: "Current location", lat: c.lat, lon: c.lon, category: locationCategory)
    }
    public var isDroppedPin: Bool { category == Self.pinCategory }
    public var isCurrentLocation: Bool { category == Self.locationCategory }
    /// "47.62950° N, 122.35990° W"
    public var coordinateLabel: String {
        String(format: "%.5f° %@, %.5f° %@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
    }
}
