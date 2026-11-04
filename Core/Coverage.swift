import Foundation

/// Where a region's map applies: a polygon inside a bounding box. The bundled Seattle data covers its box; a county build ships
/// the polygon `Scripts/region_polygon.py` wrote (`Data/king-county-coverage.json`), so a point in the box but outside the
/// polygon, such as the Kitsap shore or Vashon next to King County, is outside coverage.
public struct Coverage: Sendable, Equatable {
    /// South, west, north, east.
    public let bounds: [Double]
    /// Exterior rings of (lon, lat) points; empty means the whole box.
    private let rings: [[Coordinate]]

    /// The box alone.
    public static func box(_ bounds: [Double]) -> Coverage { Coverage(box: bounds) }

    private init(box bounds: [Double]) { self.bounds = bounds; rings = [] }

    /// Rings must be closed (first point equals last) with at least three distinct points, and bounds must be S, W, N, E; anything else
    /// throws `missingData`, so a damaged polygon is refused rather than read as covering nothing, or trapping.
    public init(bounds: [Double], rings: [[Coordinate]]) throws {
        guard bounds.count == 4, rings.allSatisfy({ $0.count >= 4 && $0.first == $0.last }) else { throw RoutingError.missingData }
        self.bounds = bounds; self.rings = rings
    }

    /// From the polygon file: `{"bbox": [S, W, N, E], "rings": [[[lon, lat], ...], ...]}`, extra keys ignored.
    public init(polygonJSON data: Data) throws {
        struct File: Decodable { let bbox: [Double]; let rings: [[[Double]]] }
        let file = try JSONDecoder().decode(File.self, from: data)
        guard !file.rings.isEmpty, file.rings.allSatisfy({ $0.allSatisfy { $0.count == 2 } }) else { throw RoutingError.missingData }
        try self.init(bounds: file.bbox, rings: file.rings.map { $0.map { Coordinate(lat: $0[1], lon: $0[0]) } })
    }

    /// The polygon shipped with the data when there is one, else the box. A file that can't be read falls back to the box.
    public static func bundled(bounds: [Double]) -> Coverage {
        guard let url = Bundle.dataFile("seattle-coverage", "json"), let data = try? Data(contentsOf: url),
              let polygon = try? Coverage(polygonJSON: data) else { return .box(bounds) }
        return polygon
    }

    public func contains(_ c: Coordinate) -> Bool {
        guard bounds.count == 4, c.lat >= bounds[0], c.lat <= bounds[2], c.lon >= bounds[1], c.lon <= bounds[3] else { return false }
        return rings.isEmpty || rings.contains { Self.inside(c, $0) }
    }

    /// Even-odd ray cast to the east.
    private static func inside(_ c: Coordinate, _ ring: [Coordinate]) -> Bool {
        var hit = false
        for i in 1..<ring.count {
            let a = ring[i - 1], b = ring[i]
            if (a.lat > c.lat) != (b.lat > c.lat), c.lon < a.lon + (c.lat - a.lat) * (b.lon - a.lon) / (b.lat - a.lat) { hit.toggle() }
        }
        return hit
    }
}
