import Foundation

public protocol RouteComputing: Sendable {
    func compare(_ request: RouteRequest) async throws -> RouteComparison
    /// Whether a place can be routed to and from by this mode: the main network has a usable road node for it, for leaving and for
    /// arriving: the node the search index stored for the place, or one within 400 m. False for Vashon, the Kitsap shore and the like,
    /// which sit inside coverage but off the road network.
    func canSnap(_ place: Place, mode: TravelMode) async -> Bool
}

extension RouteComputing {
    public func canSnap(_ place: Place, mode: TravelMode) async -> Bool { true }
}

public struct RouteMetrics: Sendable {
    public var meters = 0.0
    public var seconds = 0.0
    public var breakdown = Breakdown()
    public var stress: Double { breakdown.stress }
    public init() {}
}

public struct Route: Sendable, Identifiable {
    public let edgeIDs: [Int]
    public let edgeMeters: [Double]
    public let coordinates: [Coordinate]
    public let metrics: RouteMetrics
    public let streetNames: [String]
    /// Parallel to `edgeIDs`: the factors (amount > 0) recorded on arriving at each edge; empty for the first.
    public let junctionFactors: [[Factor]]
    /// The directed edges travelled, parallel to `edgeIDs`.
    public let edges: [GraphEdge]
    public init(edgeIDs: [Int], edgeMeters: [Double] = [], coordinates: [Coordinate], metrics: RouteMetrics, streetNames: [String],
                junctionFactors: [[Factor]] = [], edges: [GraphEdge] = []) {
        self.edgeIDs = edgeIDs; self.edgeMeters = edgeMeters; self.coordinates = coordinates; self.metrics = metrics; self.streetNames = streetNames
        self.junctionFactors = junctionFactors; self.edges = edges
    }
    public var id: String { edgeIDs.map(String.init).joined(separator: "-") }
    public var minutes: Int { max(1, Int(ceil(metrics.seconds / 60))) }
    public var duration: String { "\(minutes) min" }
    public var distance: String { DistanceFormat.distance(metrics.meters) }
}

/// What the router actually knows when it offers no calmer route. Each case claims only what it compared.
public enum NoCalmerFinding: Sendable, Equatable {
    /// Extra time is None, so only the fastest search ran.
    case notChecked
    /// Every search, including those favouring calm, found this one route.
    case onlyRoute
    /// A long trip, so fewer alternatives were searched; none of those compared is clearly calmer for its time, and none past the limit is calmer.
    case fewerChecked(routes: Int)
    /// Other routes were compared and none has less stress.
    case calmestCompared(routes: Int)
    /// Routes with less stress exist, but only beyond the limit.
    case calmerTakesLonger(limitMinutes: Int)
    /// Routes inside the limit have less stress, but too little for their time, and none beyond it does better. This route is not the calmest, so it isn't called that.
    case tooLittleGain
    /// Routes inside the limit gain too little, but one beyond it is clearly calmer and would be offered with more time.
    case clearlyCalmerTakesLonger(limitMinutes: Int)

    public var title: String {
        switch self {
        case .notChecked: "Fastest route only"
        case .onlyRoute, .calmestCompared: "Already the calmest we found"
        case .fewerChecked: "Best of the routes we checked"
        case .calmerTakesLonger: "Calmest we found within this extra time"
        case .tooLittleGain: "Best balance we found"
        case .clearlyCalmerTakesLonger: "Best balance within this extra time"
        }
    }
    public var detail: String {
        switch self {
        case .notChecked: "Extra time is None, so nothing else was checked."
        case .onlyRoute: "By our estimates, every search found this route."
        case let .calmestCompared(routes): "Calmest of \(routes) routes compared, by our estimates."
        case let .fewerChecked(routes): "This is a long trip, so we checked fewer alternatives (\(routes) \(routes == 1 ? "route" : "routes") compared). By our estimates, none is clearly calmer for its time."
        case let .calmerTakesLonger(minutes): "By our estimates, calmer routes take \(minutes)+ min more."
        case .tooLittleGain: "By our estimates, other routes gain too little."
        case let .clearlyCalmerTakesLonger(minutes): "By our estimates, a clearly calmer route takes \(minutes)+ min more."
        }
    }
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
    /// Meaningful only when `calmer` is nil.
    public let noCalmer: NoCalmerFinding
    /// Drive time on the fastest route's freeway edges, worked out once here: the calm score reads it on every view update.
    /// The same for both routes, like the trip time. Zero for walk and bike.
    let fastestFreewaySeconds: Double
    public init(request: RouteRequest, fastest: Route, calmer: Route?, candidateCount: Int, originSnapMeters: Double,
                destinationSnapMeters: Double, snappedOrigin: Coordinate, snappedDestination: Coordinate, noCalmer: NoCalmerFinding = .notChecked) {
        self.request = request; self.fastest = fastest; self.calmer = calmer; self.candidateCount = candidateCount
        self.originSnapMeters = originSnapMeters; self.destinationSnapMeters = destinationSnapMeters
        self.snappedOrigin = snappedOrigin; self.snappedDestination = snappedDestination; self.noCalmer = noCalmer
        fastestFreewaySeconds = request.mode == .drive ? fastest.edges.filter(\.isFreeway).reduce(0) { $0 + StressModel.seconds($1, mode: .drive) } : 0
    }

    public var extraSeconds: Double { max(0, (calmer?.metrics.seconds ?? fastest.metrics.seconds) - fastest.metrics.seconds) }
    /// Worked out from the displayed minutes, so the cards always add up.
    public var extraTimeLabel: String {
        guard let calmer, extraSeconds >= 1 else { return "No extra time" }
        let shown = calmer.minutes - fastest.minutes
        return shown <= 0 ? "<1 min extra" : "+\(shown) min"
    }

    /// The biggest differences between the two routes, benefits first, then what the calmer route costs you.
    /// Ranked as the person's preferences weigh them; the amounts are always the real counts and distances.
    public var reasons: [String] {
        guard let calmer else { return [noCalmer.detail] }
        let f = fastest.metrics.breakdown, c = calmer.metrics.breakdown
        let scale = FactorScale(request.preferences, mode: request.mode)
        let diffs = Factor.allCases.filter { !$0.isUnknown }.map { (factor: $0, cost: (f[$0].cost - c[$0].cost) * (scale?[$0] ?? 1), amount: f[$0].amount - c[$0].amount) }
            .filter { $0.factor.isNoticeable(abs($0.amount)) }
        let gains = diffs.filter { $0.cost > 0 }.sorted { $0.cost > $1.cost }.prefix(3).map { $0.factor.change(abs($0.amount), more: false) }
        let costs = diffs.filter { $0.cost < 0 }.sorted { $0.cost < $1.cost }.prefix(2).map { "Tradeoff: " + $0.factor.change(abs($0.amount), more: true) }
        return (gains.isEmpty ? ["Fewer small hassles spread across the whole route"] : gains) + costs
    }

    /// Drive routes that use a road tagged as a toll: mentioned, never priced, and no estimate of what it costs. Named where the
    /// road has a name ("Fastest route: uses a toll road (Evergreen Point Floating Bridge). Tolls aren't in the estimate.").
    public var tollNotes: [String] { [tollNote(calmer: false), tollNote(calmer: true)].compactMap { $0 } }

    /// The toll note for one route, to show where the route is chosen: nil off a drive trip, with no calmer route, or with no toll.
    /// A name is shown only if it reads as a road name: OSM names one Colman Dock approach way "15".
    public func tollNote(calmer isCalmer: Bool) -> String? {
        guard request.mode == .drive, let route = isCalmer ? calmer : fastest else { return nil }
        let tolled = route.edges.filter(\.toll)
        guard !tolled.isEmpty else { return nil }
        var names: [String] = []
        for name in tolled.map(\.name) where Self.isRoadName(name) && !names.contains(name) { names.append(name) }
        let which = names.isEmpty ? "" : " (\(names.prefix(2).joined(separator: ", ")))"
        return "\(isCalmer ? "Calmer" : "Fastest") route: uses a toll road\(which). Tolls aren't in the estimate."
    }

    /// A letter and at least three characters: not "15", not empty.
    static func isRoadName(_ name: String) -> Bool { name.count >= 3 && name.contains { $0.isLetter } }

    /// Gaps in the map data large enough to mention.
    public var caveats: [String] {
        [fastest, calmer].compactMap { $0 }.flatMap { route in
            [Factor.unknownSurface, .unknownSidewalk].compactMap { factor -> String? in
                let meters = route.metrics.breakdown[factor].amount
                guard meters > route.metrics.meters * 0.1 else { return nil }
                // Sidewalk is reported once, as a share of the route: a distance reads as a lot on a long drive or walk.
                return factor == .unknownSidewalk ? "sidewalk data is missing for about \(Self.roundedShare(meters / route.metrics.meters)) of it" : factor.describe(meters)
            }.map { "\(route.edgeIDs == fastest.edgeIDs ? "Fastest" : "Calmer") route: \($0)." }
        }
    }
}

extension RouteComparison {
    /// "40%": to the nearest 5%.
    static func roundedShare(_ share: Double) -> String { "\(min(100, Int((share * 20).rounded()) * 5))%" }
}

extension Factor {
    func isNoticeable(_ amount: Double) -> Bool {
        self == .climb ? amount >= 5 : isExposure ? amount >= 100 : amount >= 0.5
    }
    func change(_ amount: Double, more: Bool) -> String {
        let text = describe(amount)
        if self == .climb { return text.replacingOccurrences(of: " of climbing", with: more ? " more climbing" : " less climbing") }
        if isExposure, let unit = text.range(of: " mi ") ?? text.range(of: " ft ") {
            return text.replacingCharacters(in: unit, with: text[unit].dropLast() + (more ? " more " : " less "))
        }
        let n = text.prefix { $0 != " " }
        return "\(n) \(more ? "more" : "fewer")\(text.dropFirst(n.count))"
    }
}

/// How much searching one request may do, so a phone's memory and a very long walk or ride cannot run away with it.
public struct SearchLimits: Sendable, Equatable {
    /// Searches running at once. Each owns a buffer set the size of the graph (about 19 MB measured at all-Seattle scale),
    /// and an iPhone 15 has 6 cores but a jetsam limit near 3 GB for the whole app, so phones take three: the 7 searches of a
    /// request then run in three waves and hold about 60 MB, not 130.
    public var concurrentSearches: Int
    /// Straight-line distance beyond which a walk or bike request runs two calmer searches instead of six,
    /// and beyond `farFactor` times it, one. The fastest search and at least one calmer search always run.
    public var longMeters: [TravelMode: Double]
    public static let farFactor = 2.5

    public init(concurrentSearches: Int, longMeters: [TravelMode: Double]) {
        self.concurrentSearches = max(1, concurrentSearches); self.longMeters = longMeters
    }

    #if os(iOS)
    public static let standard = SearchLimits(concurrentSearches: 3, longMeters: [.walk: 12_000, .bike: 25_000])
    #else
    public static let standard = SearchLimits(concurrentSearches: 8, longMeters: [.walk: 12_000, .bike: 25_000])
    #endif
    public static let unbounded = SearchLimits(concurrentSearches: 8, longMeters: [:])

    /// The calmer-search weights to run for a trip of `meters` in a straight line.
    func weights(_ all: [Double], mode: TravelMode, meters: Double) -> [Double] {
        guard let long = longMeters[mode], meters > long, all.count > 2 else { return all }
        return meters > long * Self.farFactor ? [all[all.count / 2]] : [all[all.count / 2 - 1], all[all.count - 2]]
    }
}

/// Owned, offline edge-state Dijkstra router. Small enough to audit; intentionally not navigation software.
public final class NativeRouter: RouteComputing, Sendable {
    public let graph: StreetGraph
    private let outgoing: Adjacency
    private let incoming: Adjacency
    private let restrictions: [Int: [TurnRestriction]]
    /// Nodes in the largest strongly connected part of each mode's network.
    let connectedNodes: [TravelMode: [Bool]]
    private let grid: NodeGrid
    private let signalized: [Bool]
    private let legs: [Int]
    /// Flat copies of what the search reads per edge and node, so it rarely touches a `GraphEdge`.
    private let edgeFrom: [Int32], edgeTo: [Int32], edgeWay: [Int64], modeBits: [UInt8]
    private let nodePoints: [Coordinate]
    private let pedestrianSignal: [Bool]
    private let restricted: [Bool]
    /// Arterials (way and class) meeting at each node, in rows of `arterialStart[node]..<arterialStart[node + 1]`.
    private let arterialStart: [Int32], arterialWay: [Int64], arterialRoad: [RoadClass]
    private let edgeSeconds: [TravelMode: [Double]]
    private let edgeStress: [TravelMode: [Double]]
    /// The part of `edgeStress` each preference option accounts for, kept only for edges where it's nonzero.
    private let edgeOptionStress: [TravelMode: OptionShares]
    private let buffers = BufferPool()
    let limits: SearchLimits

    /// Searches trading time against stress; each extra weight finds another point on the time/stress curve.
    static let weights = [0.25, 0.5, 1, 2, 4, 8]

    public init(graph: StreetGraph, limits: SearchLimits = .standard) {
        self.graph = graph
        self.limits = limits
        let nodeCount = graph.nodes.count
        let out = Adjacency(nodes: nodeCount, edges: graph.edges, node: \.from)
        let inc = Adjacency(nodes: nodeCount, edges: graph.edges, node: \.to)
        outgoing = out; incoming = inc
        restrictions = Dictionary(grouping: graph.restrictions, by: \.via)
        let bits = graph.edges.map { $0.modes.reduce(0) { $0 | $1.bit } }
        modeBits = bits
        let components = parallelMap(TravelMode.allCases.count) { Self.largestStrongComponent(nodes: nodeCount, outgoing: out, incoming: inc, edges: graph.edges, modeBits: bits, mode: TravelMode.allCases[$0]) }
        connectedNodes = Dictionary(uniqueKeysWithValues: zip(TravelMode.allCases, components))
        edgeFrom = graph.edges.map { Int32($0.from) }; edgeTo = graph.edges.map { Int32($0.to) }; edgeWay = graph.edges.map(\.wayID)
        let points = graph.nodes.map(\.coordinate)
        nodePoints = points; pedestrianSignal = graph.nodes.map(\.pedestrianSignal); grid = NodeGrid(points)
        var restricted = Array(repeating: false, count: nodeCount)
        for r in graph.restrictions { restricted[r.via] = true }
        self.restricted = restricted
        let roads = parallelChunks(graph.edges.count) { range in range.map { i -> RoadInfo in
            let e = graph.edges[i]
            return RoadInfo(isRoad: e.isRoad, road: e.roadClass)
        } }
        // Road legs: distinct road neighbours of each node.
        var links: [UInt64] = []
        var arterials = Array(repeating: [(way: Int64, road: RoadClass)](), count: nodeCount)
        var lit = graph.nodes.map(\.signal)
        for e in graph.edges where roads[e.id].isRoad {
            links.append(UInt64(e.from) << 32 | UInt64(e.to)); links.append(UInt64(e.to) << 32 | UInt64(e.from))
            if let road = roads[e.id].road, road >= .arterial {
                for n in [e.from, e.to] where !arterials[n].contains(where: { $0.way == e.wayID }) { arterials[n].append((e.wayID, road)) }
            }
            if e.meters < 30, graph.nodes[e.from].signal { lit[e.to] = true }  // signal mapped just before the junction
        }
        signalized = lit
        links.sort()
        var legCounts = Array(repeating: 0, count: nodeCount)
        for (i, link) in links.enumerated() where i == 0 || link != links[i - 1] { legCounts[Int(link >> 32)] += 1 }
        legs = legCounts
        arterialStart = arterials.reduce(into: [0]) { $0.append($0.last! + Int32($1.count)) }
        arterialWay = arterials.flatMap { $0.map(\.way) }; arterialRoad = arterials.flatMap { $0.map(\.road) }
        let onRoad = legCounts.map { $0 > 0 }
        var seconds: [TravelMode: [Double]] = [:], stress: [TravelMode: [Double]] = [:]
        var parts: [TravelMode: OptionShares] = [:]
        for mode in TravelMode.allCases {
            seconds[mode] = parallelChunks(graph.edges.count) { $0.map { StressModel.seconds(graph.edges[$0], mode: mode) } }
            let chunks = parallelMap((graph.edges.count + Self.chunk - 1) / Self.chunk) { c -> (totals: [Double], shares: OptionShares) in
                var split = OptionSplit(), shares = OptionShares(), totals: [Double] = []
                for i in c * Self.chunk..<min(graph.edges.count, (c + 1) * Self.chunk) {
                    let e = graph.edges[i]
                    for k in split.costs.indices { split.costs[k] = 0 }
                    totals.append(StressModel.exposure(e, mode: mode, arrivesAtRoad: onRoad[e.to], into: &split))
                    for (k, cost) in split.costs.enumerated() where cost != 0 { shares.options.append(UInt8(k)); shares.costs.append(cost) }
                    shares.start.append(Int32(shares.costs.count))
                }
                return (totals, shares)
            }
            stress[mode] = chunks.flatMap(\.totals)
            var shares = OptionShares()
            for part in chunks {
                let base = Int32(shares.costs.count)
                shares.start.append(contentsOf: part.shares.start.dropFirst().map { $0 + base })
                shares.options.append(contentsOf: part.shares.options); shares.costs.append(contentsOf: part.shares.costs)
            }
            parts[mode] = shares
        }
        edgeSeconds = seconds; edgeStress = stress; edgeOptionStress = parts
    }

    private static let chunk = 8192

    /// Per-edge exposure stress for one request: the precomputed costs, with each preferred option's share rescaled on lookup.
    private func exposure(mode: TravelMode, scale: FactorScale?) -> Exposure {
        Exposure(base: edgeStress[mode]!, shares: scale == nil ? nil : edgeOptionStress[mode]!,
                 extra: RoutePreferences.Option.allCases.map { (scale?.multiplier($0) ?? 1) - 1 })
    }

    public func compare(_ request: RouteRequest) async throws -> RouteComparison {
        let cancel = CancelFlag()
        let worker = Task.detached(priority: .userInitiated) { try self.compute(request, cancel: cancel) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel(); cancel.cancel() })
    }

    public func compute(_ request: RouteRequest) throws -> RouteComparison { try compute(request, cancel: CancelFlag()) }

    func compute(_ request: RouteRequest, cancel: CancelFlag, snapLimit: Int = 3) throws -> RouteComparison {
        guard (0...20).contains(request.extraMinutes) else { throw RoutingError.invalidBudget }
        guard request.origin.id != request.destination.id, request.origin.coordinate.distance(to: request.destination.coordinate) >= 10 else { throw RoutingError.samePlace }
        guard graph.coverage.contains(request.origin.coordinate) else { throw RoutingError.startOutsideCoverage }
        guard graph.coverage.contains(request.destination.coordinate) else { throw RoutingError.outsideCoverage }
        // A stop can snap to a stretch that only a banned turn leads into or out of. On noConnection, try the next nearest usable
        // nodes (within the same 400 m), a few at most, nearest pairs first.
        let starts = try snapCandidates(request.origin, mode: request.mode, departing: true, limit: snapLimit)
        let ends = try snapCandidates(request.destination, mode: request.mode, departing: false, limit: snapLimit)
        let pairs = starts.indices.flatMap { i in ends.indices.map { (i, $0) } }.sorted { ($0.0 + $0.1, $0.0) < ($1.0 + $1.1, $1.0) }
        guard starts[0].node != ends[0].node else { throw RoutingError.samePlace }
        for (i, j) in pairs where starts[i].node != ends[j].node {
            do { return try compute(request, start: starts[i], end: ends[j], cancel: cancel) }
            catch RoutingError.noConnection { try cancel.check() }
        }
        throw RoutingError.noConnection
    }

    private func compute(_ request: RouteRequest, start: (node: Int, distance: Double), end: (node: Int, distance: Double), cancel: CancelFlag) throws -> RouteComparison {
        let stress = exposure(mode: request.mode, scale: nil)
        let transitions = TransitionCache()
        let scale = FactorScale(request.preferences, mode: request.mode)
        let weights = request.extraMinutes > 0 ? limits.weights(Self.weights, mode: request.mode, meters: nodePoints[start.node].distance(to: nodePoints[end.node])) : []
        let bounded = weights.count < Self.weights.count && !weights.isEmpty
        let scaled = scale == nil || weights.isEmpty ? stress : exposure(mode: request.mode, scale: scale)
        // The fastest route and the base weights don't depend on each other, so they run side by side; candidates keep weight order.
        let found = Found(count: 1 + weights.count)
        parallelFor(found.count, limit: limits.concurrentSearches) { i in
            found.set(i, Result {
                try shortest(from: start.node, to: end.node, mode: request.mode, weight: i == 0 ? 0 : weights[i - 1], stress: i == 0 ? stress : scaled,
                             scale: i == 0 ? nil : scale, transitions: transitions, cancel: cancel)
            })
        }
        let routes = try found.routes()
        let fastest = routes[0]
        var candidates = [fastest]
        func add(_ candidate: Route) { if !candidates.contains(where: { $0.edgeIDs == candidate.edgeIDs }) { candidates.append(candidate) } }
        routes.dropFirst().forEach(add)
        let weighed: (Route) -> Double = { scale?.stress($0.metrics.breakdown) ?? $0.metrics.stress }
        if var weight = weights.last {
            let limit = fastest.metrics.seconds + Double(request.extraMinutes) * 60 + 0.000_001
            var withinLimit: Bool { candidates.dropFirst().contains(where: { $0.metrics.seconds <= limit }) }
            if bounded {
                // The two lightest weights were dropped. While nothing calmer is offered, try them, 0.5 then 0.25 (or, when Avoid
                // pushed every detour past the budget, one step closer still to the fastest route).
                let retries = scale != nil && !withinLimit ? [Self.weights[0] / 2] : [Self.weights[1], Self.weights[0]]
                for retry in retries where Self.selectCalmer(candidates: candidates, fastest: fastest, extraMinutes: request.extraMinutes, stress: weighed) == nil {
                    try cancel.check()
                    add(try shortest(from: start.node, to: end.node, mode: request.mode, weight: retry, stress: scaled, scale: scale, transitions: transitions, cancel: cancel))
                }
            } else {
                // Avoid can make even the lightest weight detour past the budget; then look closer to the fastest route.
                while scale != nil, weight > Self.weights[0] / 4, !withinLimit {
                    weight = min(weight, Self.weights[0]) / 2
                    try cancel.check()
                    add(try shortest(from: start.node, to: end.node, mode: request.mode, weight: weight, stress: scaled, scale: scale, transitions: transitions, cancel: cancel))
                }
            }
        }
        let calmer = Self.selectCalmer(candidates: candidates, fastest: fastest, extraMinutes: request.extraMinutes, stress: weighed)
        return RouteComparison(request: request, fastest: fastest, calmer: calmer, candidateCount: candidates.count,
                               originSnapMeters: start.distance, destinationSnapMeters: end.distance,
                               snappedOrigin: graph.nodes[start.node].coordinate, snappedDestination: graph.nodes[end.node].coordinate,
                               noCalmer: Self.noCalmerFinding(candidates: candidates, fastest: fastest, extraMinutes: request.extraMinutes, stress: weighed, bounded: bounded))
    }

    /// Stress a slower route must remove per extra second to be worth it: 15 equivalent seconds per extra minute.
    /// A quarter of the stress model's own one-for-one rate, which is the bias for calm (Docs/STRESS_MODEL.md).
    static let stressPerExtraSecond = 0.25

    /// Stress saved net of the extra time.
    private static func worth(_ route: Route, fastest: Route, stress: (Route) -> Double) -> Double {
        stress(fastest) - stress(route) - stressPerExtraSecond * (route.metrics.seconds - fastest.metrics.seconds)
    }

    /// Meaningfully different, meaningfully calmer and worth its time, whatever the time budget.
    private static func isClearlyCalmer(_ route: Route, fastest: Route, stress: (Route) -> Double) -> Bool {
        let base = stress(fastest), own = stress(route)
        return route.edgeIDs != fastest.edgeIDs && own < base * 0.95 && base - own >= 30 && worth(route, fastest: fastest, stress: stress) > 0
    }

    /// The clearly calmer candidate within the time budget that saves the most stress net of its extra time.
    /// Netting means each further minute must also earn its place.
    /// `stress` is how the person weighs a route; by default the model's own total.
    public static func selectCalmer(candidates: [Route], fastest: Route, extraMinutes: Int,
                                    stress: (Route) -> Double = { $0.metrics.stress }) -> Route? {
        let limit = fastest.metrics.seconds + Double(max(0, extraMinutes)) * 60
        return candidates.filter { $0.metrics.seconds <= limit + 0.000_001 && isClearlyCalmer($0, fastest: fastest, stress: stress) }
            .max { worth($0, fastest: fastest, stress: stress) < worth($1, fastest: fastest, stress: stress) }
    }

    /// What the candidates show when `selectCalmer` offered none.
    /// When `bounded`, fewer searches ran, so findings that say nothing calmer exists become `fewerChecked`.
    /// A calmer route that was found past the limit is still reported, as it is for any request.
    public static func noCalmerFinding(candidates: [Route], fastest: Route, extraMinutes: Int,
                                       stress: (Route) -> Double = { $0.metrics.stress }, bounded: Bool = false) -> NoCalmerFinding {
        let found = plainFinding(candidates: candidates, fastest: fastest, extraMinutes: extraMinutes, stress: stress)
        switch found {
        case .notChecked, .calmerTakesLonger, .clearlyCalmerTakesLonger: return found
        default: return bounded ? .fewerChecked(routes: candidates.count) : found
        }
    }

    private static func plainFinding(candidates: [Route], fastest: Route, extraMinutes: Int, stress: (Route) -> Double) -> NoCalmerFinding {
        guard extraMinutes > 0 else { return .notChecked }
        let others = candidates.filter { $0.edgeIDs != fastest.edgeIDs }
        guard !others.isEmpty else { return .onlyRoute }
        let calmer = others.filter { stress($0) < stress(fastest) }
        guard !calmer.isEmpty else { return .calmestCompared(routes: others.count + 1) }
        let limit = fastest.metrics.seconds + Double(extraMinutes) * 60
        guard calmer.contains(where: { $0.metrics.seconds <= limit + 0.000_001 }) else { return .calmerTakesLonger(limitMinutes: extraMinutes) }
        let clearlyBeyond = calmer.contains { $0.metrics.seconds > limit + 0.000_001 && isClearlyCalmer($0, fastest: fastest, stress: stress) }
        return clearlyBeyond ? .clearlyCalmerTakesLonger(limitMinutes: extraMinutes) : .tooLittleGain
    }

    func junction(at node: Int, previous: GraphEdge, next: GraphEdge) -> Junction {
        junction(at: node, previousWay: previous.wayID, nextWay: next.wayID)
    }

    private func junction(at node: Int, previousWay: Int64, nextWay: Int64) -> Junction {
        var crossed: RoadClass?
        for k in Int(arterialStart[node])..<Int(arterialStart[node + 1]) where arterialWay[k] != previousWay && arterialWay[k] != nextWay {
            if crossed == nil || arterialRoad[k] > crossed! { crossed = arterialRoad[k] }
        }
        return Junction(signalized: signalized[node], pedestrianSignal: pedestrianSignal[node], legs: legs[node], crossedArterial: crossed)
    }

    func snap(_ place: Place, mode: TravelMode, departing: Bool) throws -> (node: Int, distance: Double) {
        try snapCandidates(place, mode: mode, departing: departing, limit: 1)[0]
    }

    /// See `RouteComputing.canSnap`. Uses the same snapping a route does, so a true answer means a search can start and end here.
    public func canSnap(_ place: Place, mode: TravelMode) -> Bool {
        (try? snapCandidates(place, mode: mode, departing: true, limit: 1)) != nil && (try? snapCandidates(place, mode: mode, departing: false, limit: 1)) != nil
    }

    /// Usable nodes for a stop, best first: the node the search index stored for the place (`place.snap`), when still valid, with no
    /// distance limit because the importer chose it; then the nearest others within 400 m (lowest id on a tie).
    func snapCandidates(_ place: Place, mode: TravelMode, departing: Bool, limit: Int = 3) throws -> [(node: Int, distance: Double)] {
        guard let connected = connectedNodes[mode] else { throw RoutingError.noConnection }
        let point = place.coordinate
        func usable(_ i: Int) -> Bool {
            (departing ? outgoing : incoming).row(i).contains(where: { graph.edges[Int($0)].modes.contains(mode) && !graph.edges[Int($0)].isHighway })
        }
        var found: [(node: Int, distance: Double)] = []
        if let i = place.snap[mode], graph.nodes.indices.contains(i), connected[i], usable(i) { found.append((i, point.distance(to: nodePoints[i]))) }
        var near: [(node: Int, distance: Double)] = []
        grid.forEachNode(within: 400, of: point) { i in
            guard connected[i] else { return }
            let d = point.distance(to: nodePoints[i])
            guard d <= 400, usable(i) else { return }
            near.append((i, d))
        }
        near.sort { ($0.distance, $0.node) < ($1.distance, $1.node) }
        for candidate in near where found.count < limit && !found.contains(where: { $0.node == candidate.node }) { found.append(candidate) }
        guard !found.isEmpty else { throw RoutingError.noConnection }
        return Array(found.prefix(limit))
    }

    /// Snap to the main connected network, rather than an isolated mapped driveway or campus loop.
    /// Kosaraju, iterative to avoid stack overflow. Turn restrictions are still enforced during search.
    private static func largestStrongComponent(nodes: Int, outgoing: Adjacency, incoming: Adjacency, edges: [GraphEdge], modeBits: [UInt8], mode: TravelMode) -> [Bool] {
        let bit = mode.bit
        var visited = Array(repeating: false, count: nodes), order: [Int] = []
        // A pending node is pushed as itself, and again as its complement once its neighbours are done.
        for root in 0..<nodes where !visited[root] {
            var stack = [root]
            while let top = stack.popLast() {
                if top < 0 { order.append(~top); continue }
                if visited[top] { continue }
                visited[top] = true
                stack.append(~top)
                for id in outgoing.row(top) where modeBits[Int(id)] & bit != 0 {
                    let next = edges[Int(id)].to
                    if !visited[next] { stack.append(next) }
                }
            }
        }
        visited = Array(repeating: false, count: nodes)
        var largest: [Int] = []
        for root in order.reversed() where !visited[root] {
            var component: [Int] = [], stack = [root]
            while let node = stack.popLast() {
                if visited[node] { continue }
                visited[node] = true
                component.append(node)
                for id in incoming.row(node) where modeBits[Int(id)] & bit != 0 {
                    let next = edges[Int(id)].from
                    if !visited[next] { stack.append(next) }
                }
            }
            if component.count > largest.count { largest = component }
        }
        var member = Array(repeating: false, count: nodes)
        for node in largest { member[node] = true }
        return member
    }

    /// Fastest plausible travel speed per mode in m/s, for the A* lower bound on remaining time.
    private static func topSpeed(_ mode: TravelMode) -> Double {
        switch mode { case .walk: 1.4; case .bike: 32 / 3.6; case .drive: StressModel.driveTopMph * 0.447_04 }
    }

    /// A* over edge states: the state includes the incoming directed edge, so a turn restriction cannot be lost
    /// by visiting a node first. Minimizes seconds + weight × stress; weight 0 is the fastest route.
    /// Straight-line distance at top speed never overestimates, and stress is never negative, so results are exact.
    /// `stress` is the per-edge exposure for this request and `scale` its preference multipliers for junction costs.
    private func shortest(from start: Int, to destination: Int, mode: TravelMode, weight: Double, stress: Exposure, scale: FactorScale?,
                          transitions: TransitionCache, cancel: CancelFlag) throws -> Route {
        let ids = try graph.edges.withUnsafeBufferPointer {
            try search($0, from: start, to: destination, mode: mode, weight: weight, stress: stress, scale: scale, transitions: transitions, cancel: cancel)
        }
        return route(ids: ids, mode: mode)
    }

    /// The edge ids of the best path; `edges` is `graph.edges`, borrowed so the loop never copies an edge.
    private func search(_ edges: UnsafeBufferPointer<GraphEdge>, from start: Int, to destination: Int, mode: TravelMode, weight: Double,
                        stress: Exposure, scale: FactorScale?, transitions: TransitionCache, cancel: CancelFlag) throws -> [Int] {
        let source = edges.count, bit = mode.bit
        let seconds = edgeSeconds[mode]!
        let target = nodePoints[destination], speed = Self.topSpeed(mode)
        func remaining(_ node: Int) -> Double { nodePoints[node].distance(to: target) / speed }
        let state = buffers.take(size: source + 1); defer { buffers.give(state) }
        let reached = state.begin(), closed = reached + 1
        let stamp = state.stamp, costs = state.cost, parents = state.parent
        stamp[source] = reached; costs[source] = 0; parents[source] = -1
        var heap = MinHeap(); heap.push(.init(cost: remaining(start), state: source))
        var visits = 0, none = NoRecord(), scaled = ScaledRecord(scale: scale ?? .identity)
        let multipliers = RoutePreferences.Option.allCases.map { scale?.multiplier($0) ?? 1 } + [1]
        while let item = heap.pop() {
            if stamp[item.state] == closed { continue }
            stamp[item.state] = closed
            visits += 1
            if visits % 256 == 0 { try cancel.check() }
            let previous = item.state == source ? -1 : item.state
            let node = previous < 0 ? start : Int(edgeTo[previous])
            if node == destination {
                var ids: [Int] = []; var state = item.state
                while state != source { ids.append(state); state = Int(parents[state]) }
                return ids.reversed()
            }
            for k in Int(outgoing.start[node])..<Int(outgoing.start[node + 1]) {
                let edgeID = Int(outgoing.edges[k])
                guard modeBits[edgeID] & bit != 0 else { continue }
                if previous >= 0, !allowed(previousFrom: Int(edgeFrom[previous]), previousWay: edgeWay[previous], nextFrom: node,
                                           nextTo: Int(edgeTo[edgeID]), nextWay: edgeWay[edgeID], mode: mode) { continue }
                var cost = costs[item.state] + seconds[edgeID] + weight * stress[edgeID]
                if previous >= 0 {
                    let key = previous << 32 | edgeID
                    var t = transitions.entry(key) ?? TransitionCost()
                    func j() -> Junction { junction(at: node, previousWay: edgeWay[previous], nextWay: edgeWay[edgeID]) }
                    if t.seconds.isNaN || (weight > 0 && t.count == TransitionCost.unknown) {
                        if t.seconds.isNaN {
                            t.seconds = StressModel.transitionSeconds(previous: edges[previous], next: edges[edgeID], turned: StressModel.isTurn(previous: edges[previous], next: edges[edgeID]), junction: j(), mode: mode)
                        }
                        if weight > 0 {
                            var log = AdditionLog()
                            _ = StressModel.transition(previous: edges[previous], next: edges[edgeID], junction: j(), mode: mode, into: &log)
                            t.record(log)
                        }
                        transitions.store(key, t)
                    }
                    cost += t.seconds
                    if weight > 0 {
                        if t.count == TransitionCost.overflow {
                            if scale != nil {
                                scaled.total = 0
                                _ = StressModel.transition(previous: edges[previous], next: edges[edgeID], junction: j(), mode: mode, into: &scaled)
                                cost += weight * scaled.total
                            } else {
                                cost += weight * StressModel.transition(previous: edges[previous], next: edges[edgeID], junction: j(), mode: mode, into: &none)
                            }
                        } else {
                            var total = 0.0
                            if scale != nil {
                                for i in 0..<Int(t.count) { total += t.costs[i] * multipliers[Int(t.options[i])] }
                            } else {
                                for i in 0..<Int(t.count) { total += t.costs[i] }
                            }
                            cost += weight * total
                        }
                    }
                }
                let seen = stamp[edgeID] >= reached
                if !seen || cost < costs[edgeID] {
                    if !seen { stamp[edgeID] = reached }
                    costs[edgeID] = cost; parents[edgeID] = Int32(item.state)
                    heap.push(.init(cost: cost + remaining(Int(edgeTo[edgeID])), state: edgeID))
                }
            }
        }
        throw RoutingError.noConnection
    }

    func allowed(previous: GraphEdge?, next: GraphEdge, mode: TravelMode) -> Bool {
        guard let previous else { return true }
        return allowed(previousFrom: previous.from, previousWay: previous.wayID, nextFrom: next.from, nextTo: next.to, nextWay: next.wayID, mode: mode)
    }

    private func allowed(previousFrom: Int, previousWay: Int64, nextFrom: Int, nextTo: Int, nextWay: Int64, mode: TravelMode) -> Bool {
        // No immediate U-turns, including explicit only_u_turn cases; conservative POC policy.
        if previousFrom == nextTo { return false }
        guard restricted[nextFrom] else { return true }
        for r in restrictions[nextFrom] ?? [] where r.mode == mode && r.fromWay == previousWay {
            if r.kind.hasPrefix("only_"), r.toWay != nextWay { return false }
            if r.kind.hasPrefix("no_"), r.toWay == nextWay {
                // OSM same-way no_u_turn should not prohibit continuation along that way.
                if r.kind == "no_u_turn" && previousFrom != nextTo { continue }
                return false
            }
        }
        return true
    }

    /// Full accounting for a found route: time, every stress factor, and whole-route factors.
    func route(ids: [Int], mode: TravelMode) -> Route {
        var metrics = RouteMetrics(), coordinates: [Coordinate] = [], streets: [String] = [], stops: [Double] = []
        var previous: GraphEdge?
        var events: [[Factor]] = []
        let onRoad = { (node: Int) in self.legs[node] > 0 }
        for id in ids {
            let e = graph.edges[id]
            var arrival: [Factor] = []
            defer { events.append(arrival) }
            if let previous {
                let j = junction(at: e.from, previous: previous, next: e)
                var here = Breakdown()
                _ = StressModel.transition(previous: previous, next: e, junction: j, mode: mode, into: &here)
                metrics.seconds += StressModel.transitionSeconds(previous: previous, next: e, turned: StressModel.isTurn(previous: previous, next: e), junction: j, mode: mode)
                let stopping: [Factor] = [.stopSign, .allWayStop, .signal, .unsignalledLeft, .unsignalledCrossing, .unsignalledRight]
                if stopping.contains(where: { here[$0].amount > 0 }) { stops.append(metrics.meters) }
                arrival = Factor.allCases.filter { here[$0].amount > 0 }
                metrics.breakdown.merge(here)
            }
            var along = Breakdown()
            _ = StressModel.exposure(e, mode: mode, arrivesAtRoad: onRoad(e.to), into: &along)
            // A marked crossing edge carries its own crossing cost; record it so navigation can name the crossing.
            arrival += [Factor.signalCrossing, .markedCrossing, .unmarkedCrossing, .sideStreetCrossing].filter { along[$0].amount > 0 && !arrival.contains($0) }
            metrics.breakdown.merge(along)
            metrics.meters += e.meters; metrics.seconds += StressModel.seconds(e, mode: mode)
            coordinates.append(contentsOf: previous == nil ? e.coordinates : Array(e.coordinates.dropFirst()))
            if !e.name.isEmpty && streets.last != e.name { streets.append(e.name) }
            previous = e
        }
        StressModel.pathFactors(edges: ids.map { graph.edges[$0] }, stops: stops, mode: mode, into: &metrics.breakdown)
        return Route(edgeIDs: ids, edgeMeters: ids.map { graph.edges[$0].meters }, coordinates: coordinates, metrics: metrics, streetNames: streets,
                     junctionFactors: events, edges: ids.map { graph.edges[$0] })
    }
}

extension Breakdown {
    mutating func merge(_ other: Breakdown) {
        for (factor, tally) in other.tallies { add(factor, amount: tally.amount, cost: tally.cost) }
    }
}

private extension TravelMode {
    var bit: UInt8 { switch self { case .walk: 1; case .bike: 2; case .drive: 4 } }
}

/// Edge ids by node in compressed rows, each in ascending edge id: edge `e` of node `n` is `edges[start[n]..<start[n + 1]]`.
private struct Adjacency {
    let start: [Int32]
    let edges: [Int32]

    init(nodes: Int, edges all: [GraphEdge], node: (GraphEdge) -> Int) {
        var start = [Int32](repeating: 0, count: nodes + 1)
        for e in all { start[node(e) + 1] += 1 }
        for i in 0..<nodes { start[i + 1] += start[i] }
        var fill = start, list = [Int32](repeating: 0, count: all.count)
        for e in all { let n = node(e); list[Int(fill[n])] = Int32(e.id); fill[n] += 1 }
        self.start = start; edges = list
    }
    func row(_ node: Int) -> ArraySlice<Int32> { edges[Int(start[node])..<Int(start[node + 1])] }
}

/// Exposure stress per edge for one request. With preferences, each edge's option shares are rescaled as it is read.
private struct Exposure {
    let base: [Double]
    let shares: OptionShares?
    let extra: [Double]
    subscript(edge: Int) -> Double {
        var stress = base[edge]
        guard let shares else { return stress }
        for k in Int(shares.start[edge])..<Int(shares.start[edge + 1]) { stress += extra[Int(shares.options[k])] * shares.costs[k] }
        return stress
    }
}

/// The part of each edge's exposure stress that each preference option accounts for, in edge order; edge `e` owns entries `start[e]..<start[e + 1]`.
private struct OptionShares {
    var start: [Int32] = [0]
    var options: [UInt8] = []
    var costs: [Double] = []
}

/// What the importer-built graph says about an edge as a road, worked out once for all edges.
private struct RoadInfo {
    let isRoad: Bool
    let road: RoadClass?
}

/// Where concurrent searches leave their results, by position.
private final class Found: @unchecked Sendable {
    let count: Int
    private let lock = NSLock()
    private var results: [Result<Route, Error>?]
    init(count: Int) { self.count = count; results = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ result: Result<Route, Error>) { lock.lock(); results[i] = result; lock.unlock() }
    /// The routes in order, or the first error in that order.
    func routes() throws -> [Route] { try results.map { try $0!.get() } }
}

private struct MinHeap {
    struct Item { let cost: Double; let state: Int }
    private var items: [Item] = []
    mutating func push(_ item: Item) {
        items.append(item); var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            guard items[i].cost < items[p].cost else { break }
            items.swapAt(i, p); i = p
        }
    }
    mutating func pop() -> Item? {
        guard !items.isEmpty else { return nil }
        if items.count == 1 { return items.removeLast() }
        let first = items[0]; items[0] = items.removeLast(); var i = 0
        while 2 * i + 1 < items.count {
            var child = 2 * i + 1
            if child + 1 < items.count && items[child + 1].cost < items[child].cost { child += 1 }
            guard items[child].cost < items[i].cost else { break }
            items.swapAt(child, i); i = child
        }
        return first
    }
}
