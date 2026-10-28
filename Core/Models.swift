import Foundation

public enum TravelMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case walk, bike, drive
    public var id: String { rawValue }
    public var title: String { switch self { case .walk: "Walk"; case .bike: "Cycle"; case .drive: "Drive" } }
    public var icon: String { switch self { case .walk: "figure.walk"; case .bike: "bicycle"; case .drive: "car.fill" } }
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
    public let osm: Int64
    public let lat: Double
    public let lon: Double
    /// Metres above sea level from the bundled USGS ground model; interpolated on bridges and in tunnels.
    public let z: Double
    public let signal: Bool
    public let pedestrianSignal: Bool
    public var coordinate: Coordinate { .init(lat: lat, lon: lon) }
    public init(osm: Int64, lat: Double, lon: Double, z: Double = 0, signal: Bool = false, pedestrianSignal: Bool = false) {
        self.osm = osm; self.lat = lat; self.lon = lon; self.z = z; self.signal = signal; self.pedestrianSignal = pedestrianSignal
    }
    enum CodingKeys: CodingKey { case osm, lat, lon, z, signal, pedestrianSignal }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(osm: try c.decode(Int64.self, forKey: .osm), lat: try c.decode(Double.self, forKey: .lat),
                  lon: try c.decode(Double.self, forKey: .lon), z: try c.decode(Double.self, forKey: .z),
                  signal: try c.decodeIfPresent(Bool.self, forKey: .signal) ?? false,
                  pedestrianSignal: try c.decodeIfPresent(Bool.self, forKey: .pedestrianSignal) ?? false)
    }
}

/// The traffic control a directed approach meets at the end of its edge.
public enum TrafficControl: String, Codable, Sendable { case signal, stop, allstop, yield }

/// The busiest road class involved: local streets, arterials, and busy arterials (4+ lanes or 35+ mph).
public enum RoadClass: String, Codable, Sendable, Comparable {
    case local, arterial, busy
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    private var rank: Int { switch self { case .local: 0; case .arterial: 1; case .busy: 2 } }
}

public struct Crossing: Codable, Sendable, Equatable {
    /// signal, marked or unmarked; nil when the map doesn't say.
    public let control: String?
    /// The road being crossed; nil when it couldn't be matched.
    public let road: RoadClass?
    public init(control: String?, road: RoadClass?) { self.control = control; self.road = road }
}

/// One direction of travel along a segment. Built from the bundled graph's undirected segments.
public struct GraphEdge: Sendable {
    public var id: Int
    public var from: Int
    public var to: Int
    public var wayID: Int64
    public var coordinates: [Coordinate]
    public var meters: Double
    public var modes: [TravelMode]
    public var highway: String
    public var name: String
    public var surface: String?
    public var maxspeed: String?
    public var lanes: Int?
    /// Sidewalk status of a road: separate, yes, no; nil when unknown.
    public var sidewalk: String?
    public var parkedBothSides: Bool?
    public var movableBridge = false
    /// OSM footway kind (sidewalk, crossing, ...) for footway edges.
    public var footway: String?
    public var steps: Int?
    public var crossing: Crossing?
    /// For sidewalks: the class of the road they run beside.
    public var besideRoad: RoadClass?
    public var facility = "none"
    /// Metres of ascent and descent in this direction of travel.
    public var climb = 0.0
    public var descent = 0.0
    /// Percent grade over the last 30 m arriving at `to`, uphill positive; nil when the ground model is implausible.
    public var approachGrade: Double?
    public var control: TrafficControl?
    public var leftTurnLane: Bool?
    public var twoWayForDriving = false

    public init(id: Int, from: Int, to: Int, wayID: Int64, coordinates: [Coordinate], meters: Double, modes: [TravelMode],
                highway: String, name: String = "", surface: String? = nil, maxspeed: String? = nil, lanes: Int? = nil) {
        self.id = id; self.from = from; self.to = to; self.wayID = wayID; self.coordinates = coordinates; self.meters = meters
        self.modes = modes; self.highway = highway; self.name = name; self.surface = surface; self.maxspeed = maxspeed; self.lanes = lanes
    }

    public var isHighway: Bool { highway.hasPrefix("motorway") || highway.hasPrefix("trunk") }
    public var isArterial: Bool { ["primary", "secondary", "tertiary"].contains(highway.replacingOccurrences(of: "_link", with: "")) }
    public var isResidential: Bool { ["residential", "living_street"].contains(highway) }
    public var isRoad: Bool { isHighway || isArterial || ["residential", "unclassified", "living_street", "service"].contains(highway) }
    public var hasCycleTrackTag: Bool { ["cycleway", "track"].contains(facility) }
    public var isRough: Bool { ["gravel", "fine_gravel", "unpaved", "dirt", "ground", "cobblestone", "sett", "sand"].contains(surface ?? "") }
    /// Posted speed in mph, if mapped.
    public var speedLimitMph: Double? {
        guard let s = maxspeed, let value = Double(s.components(separatedBy: " ")[0]), value > 0 else { return nil }
        return s.contains("mph") ? value : value / 1.609_344
    }
    /// Road class for stress purposes; nil for paths and service roads.
    public var roadClass: RoadClass? {
        if isHighway { return .busy }
        if isArterial { return (lanes ?? 2) >= 4 || (speedLimitMph ?? 0) >= 35 ? .busy : .arterial }
        return ["residential", "unclassified"].contains(highway) ? .local : nil
    }
}

public struct TurnRestriction: Decodable, Sendable {
    public let via: Int
    public let fromWay: Int64
    public let toWay: Int64
    public let kind: String
    public let mode: TravelMode
    public let osmID: Int64
    public init(via: Int, fromWay: Int64, toWay: Int64, kind: String, mode: TravelMode, osmID: Int64) {
        self.via = via; self.fromWay = fromWay; self.toWay = toWay; self.kind = kind; self.mode = mode; self.osmID = osmID
    }
}

public struct StreetGraph: Sendable {
    public let bounds: [Double]
    public let nodes: [GraphNode]
    public let edges: [GraphEdge]
    public let restrictions: [TurnRestriction]
    public let places: [Place]

    public init(bounds: [Double], nodes: [GraphNode], edges: [GraphEdge], restrictions: [TurnRestriction], places: [Place]) {
        self.bounds = bounds; self.nodes = nodes; self.edges = edges; self.restrictions = restrictions; self.places = places
    }

    public static func bundled() throws -> StreetGraph {
        guard let url = Bundle.module.url(forResource: "seattle-graph", withExtension: "json") else { throw RoutingError.missingData }
        let file = try JSONDecoder().decode(GraphFile.self, from: Data(contentsOf: url))
        guard file.schemaVersion == 2 else { throw RoutingError.missingData }
        let graph = file.graph()
        try graph.validate()
        return graph
    }
    public static var mapURL: URL? { Bundle.module.url(forResource: "seattle-map", withExtension: "geojson") }

    public func validate() throws {
        guard bounds.count == 4, !nodes.isEmpty,
              edges.enumerated().allSatisfy({ index, edge in
                  edge.id == index && nodes.indices.contains(edge.from) && nodes.indices.contains(edge.to)
                  && edge.meters.isFinite && edge.meters > 0 && edge.coordinates.count >= 2
              }), restrictions.allSatisfy({ nodes.indices.contains($0.via) }) else { throw RoutingError.missingData }
    }
    /// Ranked: name starts with the query, then a word of the name does, then the name contains it, then the category matches. Ties are alphabetical.
    public func search(_ query: String) -> [Place] {
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if q.isEmpty { return places }
        var ranked: [(rank: Int, name: String, place: Place)] = []
        for place in places {
            let name = fold(place.shortName)
            let rank: Int
            if name.hasPrefix(q) { rank = 0 }
            else if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { rank = 1 }
            else if name.contains(q) { rank = 2 }
            else if fold(place.category).contains(q) { rank = 3 }
            else { continue }
            ranked.append((rank, name, place))
        }
        ranked.sort { ($0.rank, $0.name, $0.place.id) < ($1.rank, $1.name, $1.place.id) }
        return ranked.map(\.place)
    }
    public func contains(_ c: Coordinate) -> Bool { c.lat >= bounds[0] && c.lat <= bounds[2] && c.lon >= bounds[1] && c.lon <= bounds[3] }
}

/// On-disk schema v2: undirected segments with per-direction attributes, written by Scripts/import_osm.py.
private struct GraphFile: Decodable {
    struct Direction: Decodable {
        let modes: [TravelMode]
        let facility: String?
        let control: TrafficControl?
        let approachGrade: Double?
        let leftTurnLane: Bool?
    }
    struct Segment: Decodable {
        let way: Int64, a: Int, b: Int, g: [Double], m: Double, hw: String, n: Int, up: Double, down: Double
        let lanes: Int?, maxspeed: String?, surface: String?, sidewalk: String?, parkedBothSides: Bool?
        let movableBridge: Bool?, footway: String?, steps: Int?, crossing: Crossing?, besideRoad: RoadClass?
        let f: Direction?, r: Direction?
    }
    let schemaVersion: Int
    let bounds: [Double]
    let names: [String]
    let nodes: [GraphNode]
    let segments: [Segment]
    let restrictions: [TurnRestriction]
    let places: [Place]

    func graph() -> StreetGraph {
        var edges: [GraphEdge] = []
        edges.reserveCapacity(segments.count * 2)
        for s in segments {
            let points = stride(from: 0, to: s.g.count - 1, by: 2).map { Coordinate(lat: s.g[$0 + 1], lon: s.g[$0]) }
            let twoWay = (s.f?.modes.contains(.drive) ?? false) && (s.r?.modes.contains(.drive) ?? false)
            for (direction, forward) in [(s.f, true), (s.r, false)] {
                guard let direction, !direction.modes.isEmpty else { continue }
                var e = GraphEdge(id: edges.count, from: forward ? s.a : s.b, to: forward ? s.b : s.a, wayID: s.way,
                                  coordinates: forward ? points : points.reversed(), meters: s.m, modes: direction.modes,
                                  highway: s.hw, name: names[s.n], surface: s.surface, maxspeed: s.maxspeed, lanes: s.lanes)
                e.sidewalk = s.sidewalk; e.parkedBothSides = s.parkedBothSides; e.movableBridge = s.movableBridge ?? false
                e.footway = s.footway; e.steps = s.steps; e.crossing = s.crossing; e.besideRoad = s.besideRoad
                e.facility = direction.facility ?? "none"; e.control = direction.control
                e.approachGrade = direction.approachGrade; e.leftTurnLane = direction.leftTurnLane
                e.climb = forward ? s.up : s.down; e.descent = forward ? s.down : s.up; e.twoWayForDriving = twoWay
                edges.append(e)
            }
        }
        return StreetGraph(bounds: bounds, nodes: nodes, edges: edges, restrictions: restrictions, places: places)
    }
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
