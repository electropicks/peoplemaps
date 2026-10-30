import Foundation

public protocol RouteComputing: Sendable {
    func compare(_ request: RouteRequest) async throws -> RouteComparison
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
    public var distance: String { String(format: "%.1f km", metrics.meters / 1000) }

    /// Share of this route's length that also lies on `other`.
    func overlap(with other: Route) -> Double {
        guard metrics.meters > 0, edgeMeters.count == edgeIDs.count else { return 0 }
        let shared = Set(other.edgeIDs)
        return zip(edgeIDs, edgeMeters).filter { shared.contains($0.0) }.reduce(0) { $0 + $1.1 } / metrics.meters
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
    public init(request: RouteRequest, fastest: Route, calmer: Route?, candidateCount: Int, originSnapMeters: Double,
                destinationSnapMeters: Double, snappedOrigin: Coordinate, snappedDestination: Coordinate) {
        self.request = request; self.fastest = fastest; self.calmer = calmer; self.candidateCount = candidateCount
        self.originSnapMeters = originSnapMeters; self.destinationSnapMeters = destinationSnapMeters
        self.snappedOrigin = snappedOrigin; self.snappedDestination = snappedDestination
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
        guard let calmer else { return ["No calmer route was found within your extra time. This one is already the easiest the map can see."] }
        let f = fastest.metrics.breakdown, c = calmer.metrics.breakdown
        let scale = FactorScale(request.preferences, mode: request.mode)
        let diffs = Factor.allCases.filter { !$0.isUnknown }.map { (factor: $0, cost: (f[$0].cost - c[$0].cost) * (scale?[$0] ?? 1), amount: f[$0].amount - c[$0].amount) }
            .filter { $0.factor.isNoticeable(abs($0.amount)) }
        let gains = diffs.filter { $0.cost > 0 }.sorted { $0.cost > $1.cost }.prefix(3).map { $0.factor.change(abs($0.amount), more: false) }
        let costs = diffs.filter { $0.cost < 0 }.sorted { $0.cost < $1.cost }.prefix(2).map { "Tradeoff: " + $0.factor.change(abs($0.amount), more: true) }
        return (gains.isEmpty ? ["Fewer small hassles spread across the whole route"] : gains) + costs
    }

    /// Gaps in the map data large enough to mention.
    public var caveats: [String] {
        [fastest, calmer].compactMap { $0 }.flatMap { route in
            [Factor.unknownSurface, .unknownSidewalk].compactMap { factor -> String? in
                let meters = route.metrics.breakdown[factor].amount
                return meters > route.metrics.meters * 0.1 ? factor.describe(meters) : nil
            }.map { "\(route.edgeIDs == fastest.edgeIDs ? "Fastest" : "Calmer") route: \($0)." }
        }
    }
}

extension Factor {
    func isNoticeable(_ amount: Double) -> Bool {
        self == .climb ? amount >= 5 : isExposure ? amount >= 100 : amount >= 0.5
    }
    func change(_ amount: Double, more: Bool) -> String {
        let text = describe(amount)
        if self == .climb { return text.replacingOccurrences(of: " of climbing", with: more ? " more climbing" : " less climbing") }
        if isExposure { return text.replacingOccurrences(of: " km ", with: more ? " km more " : " km less ") }
        let n = text.prefix { $0 != " " }
        return "\(n) \(more ? "more" : "fewer")\(text.dropFirst(n.count))"
    }
}

/// Owned, offline edge-state Dijkstra router. Small enough to audit; intentionally not navigation software.
public final class NativeRouter: RouteComputing, Sendable {
    public let graph: StreetGraph
    private let outgoing: [[Int]]
    private let incoming: [[Int]]
    private let restrictions: [Int: [TurnRestriction]]
    private let connectedNodes: [TravelMode: Set<Int>]
    private let signalized: [Bool]
    private let legs: [Int]
    private let arterialsAt: [Int: [(way: Int64, road: RoadClass)]]
    private let edgeSeconds: [TravelMode: [Double]]
    private let edgeStress: [TravelMode: [Double]]
    /// The part of `edgeStress` each preference option accounts for, kept only for edges where it's nonzero.
    private let edgeOptionStress: [TravelMode: OptionShares]
    private let buffers = BufferPool()

    /// Searches trading time against stress; each extra weight finds another point on the time/stress curve.
    static let weights = [0.25, 0.5, 1, 2, 4, 8]

    public init(graph: StreetGraph) {
        self.graph = graph
        var out = Array(repeating: [Int](), count: graph.nodes.count)
        var inc = out
        for e in graph.edges { out[e.from].append(e.id); inc[e.to].append(e.id) }
        outgoing = out; incoming = inc
        restrictions = Dictionary(grouping: graph.restrictions, by: \.via)
        connectedNodes = Dictionary(uniqueKeysWithValues: TravelMode.allCases.map { mode in
            (mode, Self.largestStrongComponent(graph: graph, outgoing: out, incoming: inc, mode: mode))
        })
        var neighbours = Array(repeating: Set<Int>(), count: graph.nodes.count)
        var arterials: [Int: [(way: Int64, road: RoadClass)]] = [:]
        var lit = graph.nodes.map(\.signal)
        for e in graph.edges where e.isRoad {
            neighbours[e.from].insert(e.to); neighbours[e.to].insert(e.from)
            if let road = e.roadClass, road >= .arterial {
                for n in [e.from, e.to] where !(arterials[n]?.contains { $0.way == e.wayID } ?? false) { arterials[n, default: []].append((e.wayID, road)) }
            }
            if e.meters < 30, graph.nodes[e.from].signal { lit[e.to] = true }  // signal mapped just before the junction
        }
        signalized = lit
        legs = neighbours.map(\.count)
        arterialsAt = arterials
        let onRoad = (0..<graph.nodes.count).map { !neighbours[$0].isEmpty }
        var seconds: [TravelMode: [Double]] = [:], stress: [TravelMode: [Double]] = [:]
        var parts: [TravelMode: OptionShares] = [:]
        for mode in TravelMode.allCases {
            var split = OptionSplit(), shares = OptionShares()
            seconds[mode] = graph.edges.map { StressModel.seconds($0, mode: mode) }
            stress[mode] = graph.edges.map { e in
                for i in split.costs.indices { split.costs[i] = 0 }
                let total = StressModel.exposure(e, mode: mode, arrivesAtRoad: onRoad[e.to], into: &split)
                for (i, cost) in split.costs.enumerated() where cost != 0 { shares.options.append(UInt8(i)); shares.costs.append(cost) }
                shares.start.append(Int32(shares.costs.count))
                return total
            }
            parts[mode] = shares
        }
        edgeSeconds = seconds; edgeStress = stress; edgeOptionStress = parts
    }

    /// Per-edge exposure stress for one request: the precomputed costs, with each preferred option's share rescaled on lookup.
    private func exposure(mode: TravelMode, scale: FactorScale?) -> Exposure {
        Exposure(base: edgeStress[mode]!, shares: scale == nil ? nil : edgeOptionStress[mode]!,
                 extra: RoutePreferences.Option.allCases.map { (scale?.multiplier($0) ?? 1) - 1 })
    }

    public func compare(_ request: RouteRequest) async throws -> RouteComparison {
        let worker = Task.detached(priority: .userInitiated) { try self.compute(request) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    public func compute(_ request: RouteRequest) throws -> RouteComparison {
        guard (0...20).contains(request.extraMinutes) else { throw RoutingError.invalidBudget }
        guard request.origin.id != request.destination.id, request.origin.coordinate.distance(to: request.destination.coordinate) >= 10 else { throw RoutingError.samePlace }
        guard graph.contains(request.origin.coordinate), graph.contains(request.destination.coordinate) else { throw RoutingError.outsideCoverage }
        let start = try snap(request.origin, mode: request.mode, departing: true)
        let end = try snap(request.destination, mode: request.mode, departing: false)
        guard start.node != end.node else { throw RoutingError.samePlace }
        let stress = exposure(mode: request.mode, scale: nil)
        let fastest = try shortest(from: start.node, to: end.node, mode: request.mode, weight: 0, stress: stress, scale: nil)
        var candidates = [fastest]
        let scale = FactorScale(request.preferences, mode: request.mode)
        if request.extraMinutes > 0 {
            let scaled = scale == nil ? stress : exposure(mode: request.mode, scale: scale)
            var weights = Self.weights[...]
            let limit = fastest.metrics.seconds + Double(request.extraMinutes) * 60 + 0.000_001
            while let weight = weights.popFirst() {
                try Task.checkCancellation()
                let candidate = try shortest(from: start.node, to: end.node, mode: request.mode, weight: weight, stress: scaled, scale: scale)
                if !candidates.contains(where: { $0.edgeIDs == candidate.edgeIDs }) { candidates.append(candidate) }
                // Avoid can make even the lightest weight detour past the budget; then look closer to the fastest route.
                if weights.isEmpty, scale != nil, weight > Self.weights[0] / 4, !candidates.dropFirst().contains(where: { $0.metrics.seconds <= limit }) {
                    weights.append(min(weight, Self.weights[0]) / 2)
                }
            }
        }
        let calmer = Self.selectCalmer(candidates: candidates, fastest: fastest, extraMinutes: request.extraMinutes,
                                       stress: { scale?.stress($0.metrics.breakdown) ?? $0.metrics.stress })
        return RouteComparison(request: request, fastest: fastest, calmer: calmer, candidateCount: candidates.count,
                               originSnapMeters: start.distance, destinationSnapMeters: end.distance,
                               snappedOrigin: graph.nodes[start.node].coordinate, snappedDestination: graph.nodes[end.node].coordinate)
    }

    /// The least stressful candidate within the time budget, if it is meaningfully calmer and meaningfully different.
    /// `stress` is how the person weighs a route; by default the model's own total.
    public static func selectCalmer(candidates: [Route], fastest: Route, extraMinutes: Int,
                                    stress: (Route) -> Double = { $0.metrics.stress }) -> Route? {
        let limit = fastest.metrics.seconds + Double(max(0, extraMinutes)) * 60
        let base = stress(fastest)
        return candidates.map { (route: $0, stress: stress($0)) }.filter {
            $0.route.edgeIDs != fastest.edgeIDs && $0.route.metrics.seconds <= limit + 0.000_001
            && $0.stress < base * 0.95 && base - $0.stress >= 30 && $0.route.overlap(with: fastest) < 0.9
        }.min {
            if abs($0.stress - $1.stress) > 0.001 { return $0.stress < $1.stress }
            return $0.route.metrics.seconds < $1.route.metrics.seconds
        }?.route
    }

    func junction(at node: Int, previous: GraphEdge, next: GraphEdge) -> Junction {
        Junction(signalized: signalized[node], pedestrianSignal: graph.nodes[node].pedestrianSignal, legs: legs[node],
                 crossedArterial: arterialsAt[node]?.filter { $0.way != previous.wayID && $0.way != next.wayID }.map(\.road).max())
    }

    private func snap(_ place: Place, mode: TravelMode, departing: Bool) throws -> (node: Int, distance: Double) {
        guard let connected = connectedNodes[mode] else { throw RoutingError.noConnection }
        let point = place.coordinate
        // The search index stores the node the importer picked; use it when it is still a valid start or end here.
        if let i = place.snap[mode], graph.nodes.indices.contains(i), connected.contains(i),
           (departing ? outgoing[i] : incoming[i]).contains(where: { graph.edges[$0].modes.contains(mode) && !graph.edges[$0].isHighway }) {
            return (i, point.distance(to: graph.nodes[i].coordinate))
        }
        var best: (Int, Double)?
        for i in graph.nodes.indices where connected.contains(i) {
            let d = point.distance(to: graph.nodes[i].coordinate)
            guard d <= 400, best == nil || d < best!.1 else { continue }
            let usable = departing ? outgoing[i] : incoming[i]
            if usable.contains(where: { graph.edges[$0].modes.contains(mode) && !graph.edges[$0].isHighway }) { best = (i, d) }
        }
        guard let best else { throw RoutingError.noConnection }
        return best
    }

    /// Snap to the main connected network, rather than an isolated mapped driveway or campus loop.
    /// Kosaraju, iterative to avoid stack overflow. Turn restrictions are still enforced during search.
    private static func largestStrongComponent(graph: StreetGraph, outgoing: [[Int]], incoming: [[Int]], mode: TravelMode) -> Set<Int> {
        var visited = Set<Int>(), order: [Int] = []
        for root in graph.nodes.indices where !visited.contains(root) {
            var stack: [(Int, Bool)] = [(root, false)]
            while let (node, expanded) = stack.popLast() {
                if expanded { order.append(node); continue }
                if !visited.insert(node).inserted { continue }
                stack.append((node, true))
                for id in outgoing[node] where graph.edges[id].modes.contains(mode) {
                    let next = graph.edges[id].to
                    if !visited.contains(next) { stack.append((next, false)) }
                }
            }
        }
        visited.removeAll(keepingCapacity: true)
        var largest = Set<Int>()
        for root in order.reversed() where !visited.contains(root) {
            var component = Set<Int>(), stack = [root]
            while let node = stack.popLast() {
                if !visited.insert(node).inserted { continue }
                component.insert(node)
                for id in incoming[node] where graph.edges[id].modes.contains(mode) {
                    let next = graph.edges[id].from
                    if !visited.contains(next) { stack.append(next) }
                }
            }
            if component.count > largest.count { largest = component }
        }
        return largest
    }

    /// Fastest plausible travel speed per mode in m/s, for the A* lower bound on remaining time.
    private static func topSpeed(_ mode: TravelMode) -> Double {
        switch mode { case .walk: 1.4; case .bike: 32 / 3.6; case .drive: 70 / 3.6 }
    }

    /// A* over edge states: the state includes the incoming directed edge, so a turn restriction cannot be lost
    /// by visiting a node first. Minimizes seconds + weight × stress; weight 0 is the fastest route.
    /// Straight-line distance at top speed never overestimates, and stress is never negative, so results are exact.
    /// `stress` is the per-edge exposure for this request and `scale` its preference multipliers for junction costs.
    private func shortest(from start: Int, to destination: Int, mode: TravelMode, weight: Double, stress: Exposure, scale: FactorScale?) throws -> Route {
        let source = graph.edges.count
        let seconds = edgeSeconds[mode]!
        let target = graph.nodes[destination].coordinate, speed = Self.topSpeed(mode)
        func remaining(_ node: Int) -> Double { graph.nodes[node].coordinate.distance(to: target) / speed }
        let search = buffers.take(size: source + 1); defer { buffers.give(search) }
        let reached = search.begin(), closed = reached + 1
        let stamp = search.stamp, costs = search.cost, parents = search.parent
        stamp[source] = reached; costs[source] = 0; parents[source] = -1
        var heap = MinHeap(); heap.push(.init(cost: remaining(start), state: source))
        var visits = 0, none = NoRecord(), scaled = ScaledRecord(scale: scale ?? .identity)
        while let item = heap.pop() {
            if stamp[item.state] == closed { continue }
            stamp[item.state] = closed
            visits += 1
            if visits % 256 == 0 { try Task.checkCancellation() }
            let previous: GraphEdge? = item.state == source ? nil : graph.edges[item.state]
            let node = previous?.to ?? start
            if node == destination {
                var ids: [Int] = []; var state = item.state
                while state != source { ids.append(state); state = Int(parents[state]) }
                return route(ids: ids.reversed(), mode: mode)
            }
            for edgeID in outgoing[node] {
                let edge = graph.edges[edgeID]
                guard edge.modes.contains(mode), allowed(previous: previous, next: edge, mode: mode) else { continue }
                var cost = costs[item.state] + seconds[edgeID] + weight * stress[edgeID]
                if let previous {
                    let j = junction(at: node, previous: previous, next: edge)
                    cost += StressModel.transitionSeconds(previous: previous, next: edge, turned: StressModel.isTurn(previous: previous, next: edge), junction: j, mode: mode)
                    if weight > 0 {
                        if scale != nil {
                            scaled.total = 0
                            _ = StressModel.transition(previous: previous, next: edge, junction: j, mode: mode, into: &scaled)
                            cost += weight * scaled.total
                        } else {
                            cost += weight * StressModel.transition(previous: previous, next: edge, junction: j, mode: mode, into: &none)
                        }
                    }
                }
                let seen = stamp[edgeID] >= reached
                if !seen || cost < costs[edgeID] {
                    if !seen { stamp[edgeID] = reached }
                    costs[edgeID] = cost; parents[edgeID] = Int32(item.state)
                    heap.push(.init(cost: cost + remaining(edge.to), state: edgeID))
                }
            }
        }
        throw RoutingError.noConnection
    }

    func allowed(previous: GraphEdge?, next: GraphEdge, mode: TravelMode) -> Bool {
        guard let previous else { return true }
        // No immediate U-turns, including explicit only_u_turn cases; conservative POC policy.
        if previous.from == next.to { return false }
        for r in restrictions[next.from] ?? [] where r.mode == mode && r.fromWay == previous.wayID {
            if r.kind.hasPrefix("only_"), r.toWay != next.wayID { return false }
            if r.kind.hasPrefix("no_"), r.toWay == next.wayID {
                // OSM same-way no_u_turn should not prohibit continuation along that way.
                if r.kind == "no_u_turn" && previous.from != next.to { continue }
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
