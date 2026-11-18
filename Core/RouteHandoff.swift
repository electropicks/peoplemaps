import Foundation

/// A route handed to another navigation app, which then guides with its own router. Google Maps and Apple Maps take stops, not a
/// line, so a calmer route travels as stops on the streets where it leaves the fastest one; between stops the other app picks its own
/// roads. Nothing comes back from the other app (`Docs/NAVIGATION.md`, "Handing a route to another app").
public struct RouteHandoff: Sendable, Equatable {
    public enum Target: Sendable, CaseIterable { case googleMaps, appleMaps }

    /// Nil starts the other app from the device's own location.
    public let origin: Coordinate?
    public let destination: Coordinate
    public let mode: TravelMode
    public let stops: [Coordinate]

    /// Tested in November 2026: 3 or 4 stops kept our calmer drives in both apps, and every stop shows as an errand there, so drives
    /// get 4. Bike routes needed Google's full 9 to keep most of the calmer streets.
    public static func maxStops(for mode: TravelMode) -> Int { mode == .drive ? 4 : 9 }
    /// Shorter stretches are left to the other app: a stop on them adds a stop without changing its route.
    static let minimumStretch = 80.0
    static let closeEnough = 500.0

    public init(origin: Coordinate?, destination: Coordinate, mode: TravelMode, stops: [Coordinate]) {
        self.origin = origin; self.destination = destination; self.mode = mode; self.stops = stops
    }

    /// The calmer route is pinned where it leaves the fastest; the fastest, or the only route, goes as start and destination alone.
    public init(comparison: RouteComparison, calmerChosen: Bool) {
        let request = comparison.request
        let limit = Self.maxStops(for: request.mode)
        let stops = calmerChosen ? comparison.calmer.map { Self.stops(on: $0, leaving: comparison.fastest, limit: limit) } ?? [] : []
        self.init(origin: request.origin.isCurrentLocation ? nil : request.origin.coordinate, destination: request.destination.coordinate,
                  mode: request.mode, stops: stops)
    }

    /// Whether the target keeps the stops: Apple Maps gives no directions at all for walking or cycling with a stop, so there it gets
    /// the destination only and picks the whole route itself.
    public func keepsStops(in target: Target) -> Bool { !stops.isEmpty && (target == .googleMaps || mode == .drive) }

    public func url(for target: Target) -> URL {
        let stops = keepsStops(in: target) ? self.stops : []
        var items: [URLQueryItem]
        var components: URLComponents
        switch target {
        case .googleMaps:
            // The universal link: the `comgooglemaps://` scheme drops waypoints. Without the app it opens in the browser.
            components = URLComponents(string: "https://www.google.com/maps/dir/")!
            items = [URLQueryItem(name: "api", value: "1")]
            if let origin { items.append(URLQueryItem(name: "origin", value: Self.text(origin))) }
            items.append(URLQueryItem(name: "destination", value: Self.text(destination)))
            items.append(URLQueryItem(name: "travelmode", value: ["walk": "walking", "bike": "bicycling", "drive": "driving"][mode.rawValue]))
            if !stops.isEmpty { items.append(URLQueryItem(name: "waypoints", value: stops.map(Self.text).joined(separator: "|"))) }
        case .appleMaps:
            // Unified Maps URLs (iOS 18.4).
            components = URLComponents(string: "https://maps.apple.com/directions")!
            items = []
            if let origin { items.append(URLQueryItem(name: "source", value: Self.text(origin))) }
            items.append(URLQueryItem(name: "destination", value: Self.text(destination)))
            items += stops.map { URLQueryItem(name: "waypoint", value: Self.text($0)) }
            items.append(URLQueryItem(name: "mode", value: ["walk": "walking", "bike": "cycling", "drive": "driving"][mode.rawValue]))
        }
        components.queryItems = items
        // `|` is legal in a query, but Google documents it escaped.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "|", with: "%7C")
        return components.url!
    }

    /// Up to `limit` stops on `route`'s line. Each splits the longest gap left between the ends and the stops so far: at the middle
    /// of a stretch of one street where `route` leaves `other`, the one nearest the gap's middle, or at the gap's middle when none lies
    /// in it. Gaps of `closeEnough` or less are left alone: across them the other app's shortest way is ours. In testing, stops only at
    /// those stretches let Apple Maps leave a calmer drive along a street both of our routes share.
    public static func stops(on route: Route, leaving other: Route, limit: Int) -> [Coordinate] {
        let shared = Set(other.edges.map(\.wayID))
        var stretches: [(start: Double, end: Double, name: String)] = []
        var offset = 0.0, previousShared = true
        for edge in route.edges {
            let end = offset + RouteLine.length(edge.coordinates), isShared = shared.contains(edge.wayID)
            if !isShared {
                if !previousShared, let last = stretches.last, last.name == edge.name { stretches[stretches.count - 1].end = end }
                else { stretches.append((offset, end, edge.name)) }
            }
            previousShared = isShared; offset = end
        }
        guard !stretches.isEmpty else { return [] }
        let middles = stretches.filter { $0.end - $0.start >= minimumStretch }.map { ($0.start + $0.end) / 2 }
        var chosen: [Double] = []
        while chosen.count < limit {
            let ends = [0] + chosen.sorted() + [offset]
            guard let gap = zip(ends, ends.dropFirst()).max(by: { $0.1 - $0.0 < $1.1 - $1.0 }), gap.1 - gap.0 > closeEnough else { break }
            let middle = (gap.0 + gap.1) / 2
            chosen.append(middles.filter { $0 > gap.0 && $0 < gap.1 }.min { abs($0 - middle) < abs($1 - middle) } ?? middle)
        }
        return chosen.sorted().compactMap { RouteLine.split(route.coordinates, atMeters: $0).passed.last }
    }

    static func text(_ c: Coordinate) -> String { String(format: "%.6f,%.6f", c.lat, c.lon) }
}

extension Route {
    /// The whole line as a GPX 1.1 track, for apps that follow a track (OsmAnd) or build cues from one (bike apps).
    public func gpx(name: String, mode: TravelMode) -> String {
        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let type = ["walk": "walking", "bike": "cycling", "drive": "driving"][mode.rawValue]!
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="PeopleMaps" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>\(escaped(name))</name><desc>From PeopleMaps. Times are estimates. Map data © OpenStreetMap contributors.</desc></metadata>
          <trk><name>\(escaped(name))</name><type>\(type)</type><trkseg>

        """
        for c in coordinates { out += String(format: "    <trkpt lat=\"%.6f\" lon=\"%.6f\"/>\n", c.lat, c.lon) }
        out += "  </trkseg></trk>\n</gpx>\n"
        return out
    }
}
