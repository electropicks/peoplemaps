import PeoplemapsCore

/// Approximate neighbourhood centroids, enough to label a place; not boundaries.
enum Neighbourhoods {
    static let table: [(name: String, lat: Double, lon: Double)] = [
        ("Ballard", 47.668, -122.384), ("Fremont", 47.651, -122.350), ("Wallingford", 47.655, -122.335),
        ("Queen Anne", 47.637, -122.357), ("Westlake", 47.632, -122.343), ("South Lake Union", 47.624, -122.336),
        ("Eastlake", 47.637, -122.322), ("University District", 47.661, -122.313), ("Green Lake", 47.676, -122.326),
        ("Phinney Ridge", 47.672, -122.355), ("Capitol Hill", 47.623, -122.314), ("Interbay", 47.640, -122.378),
        ("Montlake", 47.643, -122.304),
    ]
    static let maxMeters = 1_500.0

    /// The nearest centroid within 1.5 km, else nil.
    static func nearest(to c: Coordinate) -> String? {
        table.map { ($0.name, c.distance(to: Coordinate(lat: $0.lat, lon: $0.lon))) }
            .filter { $0.1 <= maxMeters }.min { $0.1 < $1.1 }?.0
    }
}

extension Place {
    var categoryLabel: String {
        switch category { case "cafe": "Café"; default: category.prefix(1).uppercased() + category.dropFirst() }
    }
    /// "Category · Neighbourhood", or just the category outside every neighbourhood; coordinates for a dropped pin.
    var subtitle: String {
        if isDroppedPin { return coordinateLabel }
        return [categoryLabel, Neighbourhoods.nearest(to: coordinate)].compactMap { $0 }.joined(separator: " · ")
    }
    var symbol: String {
        switch category {
        case "park": "tree"; case "library": "books.vertical"; case "museum": "building.columns"
        case "cafe": "cup.and.saucer"; case "viewpoint": "eye"; case Place.pinCategory: "mappin"
        case Place.locationCategory: "location.fill"; default: "star"
        }
    }
}
