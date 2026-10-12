import Foundation

public enum TravelMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case drive, bike
    public var id: String { rawValue }
    public var title: String { self == .drive ? "Drive" : "Cycle" }
    public var icon: String { self == .drive ? "car.fill" : "bicycle" }
}

public struct Coordinate: Hashable, Sendable {
    public let lat: Double
    public let lon: Double
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
    public func distance(to other: Coordinate) -> Double {
        let x = (other.lon - lon) * .pi / 180 * cos((lat + other.lat) * .pi / 360)
        let y = (other.lat - lat) * .pi / 180
        return hypot(x, y) * 6_371_000
    }
}

public struct Place: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let lat: Double
    public let lon: Double
    public let category: String
    public var coordinate: Coordinate { .init(lat: lat, lon: lon) }
    public var shortName: String {
        name.replacingOccurrences(of: "The Seattle Public Library - ", with: "")
            .replacingOccurrences(of: " Branch", with: " Library")
    }
    public init(id: String, name: String, lat: Double, lon: Double, category: String) {
        self.id = id; self.name = name; self.lat = lat; self.lon = lon; self.category = category
    }
}

public struct GraphNode: Decodable, Sendable {
    public let osmID: Int64
    public let lat: Double
    public let lon: Double
    public let signal: Bool
    public var coordinate: Coordinate { .init(lat: lat, lon: lon) }
}

public struct GraphEdge: Decodable, Sendable {
    public let id: Int
    public let from: Int
    public let to: Int
    public let wayID: Int64
    public let geometry: [[Double]] // GeoJSON order: longitude, latitude
    public let meters: Double
    public let modes: [TravelMode]
    public let highway: String
    public let name: String
    public let surface: String?
    public let maxspeed: String?
    public let incline: String?
    public let facility: String
    public var isArterial: Bool { ["primary", "secondary", "trunk", "primary_link", "secondary_link", "trunk_link"].contains(highway) }
    public var isHighway: Bool { highway.hasPrefix("motorway") || highway.hasPrefix("trunk") }
    public var isResidential: Bool { ["residential", "living_street"].contains(highway) }
    public var hasCycleTrackTag: Bool { ["cycleway", "track"].contains(facility) }
    public var isRough: Bool { ["gravel", "fine_gravel", "unpaved", "dirt", "ground", "cobblestone", "sett", "sand"].contains(surface ?? "") }
    public var coordinates: [Coordinate] { geometry.map { .init(lat: $0[1], lon: $0[0]) } }
}

public struct TurnRestriction: Decodable, Sendable {
    public let via: Int
    public let fromWay: Int64
    public let toWay: Int64
    public let kind: String
    public let mode: TravelMode
    public let osmID: Int64
}

public struct StreetGraph: Decodable, Sendable {
    public let schemaVersion: Int
    public let bounds: [Double]
    public let nodes: [GraphNode]
    public let edges: [GraphEdge]
    public let restrictions: [TurnRestriction]
    public let places: [Place]

    public static func bundled() throws -> StreetGraph {
        guard let url = Bundle.module.url(forResource: "seattle-graph", withExtension: "json") else { throw RoutingError.missingData }
        let graph = try JSONDecoder().decode(StreetGraph.self, from: Data(contentsOf: url))
        try graph.validate()
        return graph
    }
    public static var mapURL: URL? { Bundle.module.url(forResource: "seattle-map", withExtension: "geojson") }

    public func validate() throws {
        guard schemaVersion == 1, bounds.count == 4, !nodes.isEmpty,
              edges.enumerated().allSatisfy({ index, edge in
                  edge.id == index && nodes.indices.contains(edge.from) && nodes.indices.contains(edge.to)
                  && edge.meters.isFinite && edge.meters > 0 && edge.geometry.count >= 2
                  && edge.geometry.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) })
              }), restrictions.allSatisfy({ nodes.indices.contains($0.via) }) else { throw RoutingError.missingData }
    }
    public func search(_ query: String) -> [Place] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? places : places.filter { $0.shortName.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query) }
    }
    public func contains(_ c: Coordinate) -> Bool { c.lat >= bounds[0] && c.lat <= bounds[2] && c.lon >= bounds[1] && c.lon <= bounds[3] }
}

public struct RouteRequest: Hashable, Sendable {
    public let origin: Place
    public let destination: Place
    public let mode: TravelMode
    public let extraMinutes: Int
    public init(origin: Place, destination: Place, mode: TravelMode, extraMinutes: Int) {
        self.origin = origin; self.destination = destination; self.mode = mode; self.extraMinutes = extraMinutes
    }
}

public struct RouteMetrics: Sendable {
    public var meters = 0.0
    public var seconds = 0.0
    public var discomfort = 0.0
    public var turns = 0
    public var arterialLefts = 0
    public var highwayEntries = 0
    public var residentialMeters = 0.0
    public var arterialMeters = 0.0
    public var cycleTrackMeters = 0.0
    public var unknownSurfaceMeters = 0.0
    public var roughMeters = 0.0
    public var unknownGradeMeters = 0.0
}

public struct Route: Sendable, Identifiable {
    public let edgeIDs: [Int]
    public let coordinates: [Coordinate]
    public let metrics: RouteMetrics
    public let streetNames: [String]
    public var id: String { edgeIDs.map(String.init).joined(separator: "-") }
    public var duration: String { "\(max(1, Int(ceil(metrics.seconds / 60)))) min" }
    public var distance: String { String(format: "%.1f km", metrics.meters / 1000) }
}

public struct RouteComparison: Sendable {
    public let request: RouteRequest
    public let fastest: Route
    public let calmer: Route?
    public let candidateCount: Int
    public let originSnapMeters: Double
    public let destinationSnapMeters: Double
    public let snappedOrigin: Coordinate
    public let snappedDestination: Coordinate
    public var extraSeconds: Double { max(0, (calmer?.metrics.seconds ?? fastest.metrics.seconds) - fastest.metrics.seconds) }
    public var extraTimeLabel: String {
        extraSeconds < 1 ? "No extra time" : extraSeconds < 60 ? "<1 min extra" : "+\(Int(ceil(extraSeconds / 60))) min"
    }
    public var reasons: [String] {
        guard let calmer else { return ["No distinct route with a lower comfort cost was found within your time budget."] }
        let f = fastest.metrics, c = calmer.metrics
        var result: [String] = []
        if request.mode == .drive {
            if c.turns < f.turns { result.append("\(f.turns - c.turns) fewer \(f.turns - c.turns == 1 ? "turn" : "turns") across the route") }
            if c.highwayEntries < f.highwayEntries { result.append("\(f.highwayEntries - c.highwayEntries) fewer highway \(f.highwayEntries - c.highwayEntries == 1 ? "entry" : "entries")") }
            if c.arterialLefts < f.arterialLefts { result.append("\(f.arterialLefts - c.arterialLefts) fewer \(f.arterialLefts - c.arterialLefts == 1 ? "left turn" : "left turns") at arterial junctions; turn protection unknown") }
            if f.residentialMeters - c.residentialMeters > 100 { result.append("\(Self.km(f.residentialMeters - c.residentialMeters)) less on residential streets") }
            if c.turns > f.turns { result.append("Tradeoff: \(c.turns - f.turns) more \(c.turns - f.turns == 1 ? "turn" : "turns")") }
            if c.residentialMeters - f.residentialMeters > 100 { result.append("Tradeoff: \(Self.km(c.residentialMeters - f.residentialMeters)) more on residential streets") }
        } else {
            if c.cycleTrackMeters - f.cycleTrackMeters > 100 { result.append("\(Self.km(c.cycleTrackMeters - f.cycleTrackMeters)) more with cycleway or track tags") }
            if f.arterialMeters - c.arterialMeters > 100 { result.append("\(Self.km(f.arterialMeters - c.arterialMeters)) less on arterial roads") }
            if f.roughMeters - c.roughMeters > 100 { result.append("\(Self.km(f.roughMeters - c.roughMeters)) less with rough-surface tags") }
            if c.roughMeters - f.roughMeters > 100 { result.append("Tradeoff: \(Self.km(c.roughMeters - f.roughMeters)) more with rough-surface tags") }
            if c.turns > f.turns { result.append("Tradeoff: \(c.turns - f.turns) more turns") }
        }
        if result.isEmpty { result.append("Lower combined cost across mapped road types and turns; no single large difference") }
        return result
    }
    private static func km(_ meters: Double) -> String { String(format: "%.1f km", meters / 1000) }
}

public enum RoutingError: Error, LocalizedError, Equatable, Sendable {
    case missingData, outsideCoverage, samePlace, noConnection, invalidBudget
    public var errorDescription: String? {
        switch self {
        case .missingData: "The Seattle dataset could not be loaded. Rebuild the app with its bundled data."
        case .outsideCoverage: "This place is outside the Seattle demo area. Choose a place from the offline list."
        case .samePlace: "Choose two different places to compare routes."
        case .noConnection: "No connected route was found in this extract. Try another nearby place or travel mode."
        case .invalidBudget: "Choose an extra-time budget from 0 to 20 minutes."
        }
    }
}
