import Foundation

public protocol RouteComputing: Sendable {
    func compare(_ request: RouteRequest) async throws -> RouteComparison
}

/// Owned, offline edge-state Dijkstra router. Small enough to audit; intentionally not navigation software.
public final class NativeRouter: RouteComputing, Sendable {
    public let graph: StreetGraph
    private let outgoing: [[Int]]
    private let incoming: [[Int]]
    private let restrictions: [Int: [TurnRestriction]]
    private let connectedNodes: [TravelMode: Set<Int>]

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
    }

    public func compare(_ request: RouteRequest) async throws -> RouteComparison {
        let worker = Task.detached(priority: .userInitiated) { try self.compute(request) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    public func compute(_ request: RouteRequest) throws -> RouteComparison {
        guard (0...20).contains(request.extraMinutes) else { throw RoutingError.invalidBudget }
        guard request.origin.id != request.destination.id, request.origin.coordinate.distance(to: request.destination.coordinate) >= 10 else { throw RoutingError.samePlace }
        guard graph.contains(request.origin.coordinate), graph.contains(request.destination.coordinate) else { throw RoutingError.outsideCoverage }
        let start = try snap(request.origin.coordinate, mode: request.mode, departing: true)
        let end = try snap(request.destination.coordinate, mode: request.mode, departing: false)
        guard start.node != end.node else { throw RoutingError.samePlace }
        let fastest = try shortest(from: start.node, to: end.node, mode: request.mode, weight: 0)
        var candidates = [fastest]
        if request.extraMinutes > 0 {
            for weight in [0.15, 0.4, 1.0, 2.5, 6.0, 15.0] {
                try Task.checkCancellation()
                let candidate = try shortest(from: start.node, to: end.node, mode: request.mode, weight: weight)
                if !candidates.contains(where: { $0.edgeIDs == candidate.edgeIDs }) { candidates.append(candidate) }
            }
        }
        let calmer = Self.selectCalmer(candidates: candidates, fastest: fastest, extraMinutes: request.extraMinutes)
        return RouteComparison(request: request, fastest: fastest, calmer: calmer, candidateCount: candidates.count,
                               originSnapMeters: start.distance, destinationSnapMeters: end.distance,
                               snappedOrigin: graph.nodes[start.node].coordinate, snappedDestination: graph.nodes[end.node].coordinate)
    }

    public static func selectCalmer(candidates: [Route], fastest: Route, extraMinutes: Int) -> Route? {
        let limit = fastest.metrics.seconds + Double(max(0, extraMinutes)) * 60
        return candidates.filter {
            $0.edgeIDs != fastest.edgeIDs && $0.metrics.seconds <= limit + 0.000_001
            && $0.metrics.discomfort < fastest.metrics.discomfort * 0.98
        }.min {
            if abs($0.metrics.discomfort - $1.metrics.discomfort) > 0.001 { return $0.metrics.discomfort < $1.metrics.discomfort }
            return $0.metrics.seconds < $1.metrics.seconds
        }
    }

    private func snap(_ point: Coordinate, mode: TravelMode, departing: Bool) throws -> (node: Int, distance: Double) {
        var best: (Int, Double)?
        for i in graph.nodes.indices {
            guard connectedNodes[mode]?.contains(i) == true else { continue }
            let usable = departing ? outgoing[i] : incoming[i]
            guard usable.contains(where: { graph.edges[$0].modes.contains(mode) && !graph.edges[$0].isHighway }) else { continue }
            let d = point.distance(to: graph.nodes[i].coordinate)
            if d <= 400, best == nil || d < best!.1 { best = (i, d) }
        }
        guard let best else { throw RoutingError.noConnection }
        return best
    }

    /// Snap to the main connected street network, rather than an isolated mapped driveway or campus loop.
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

    /// State includes incoming directed edge, so a turn restriction cannot be lost by visiting a node first.
    private func shortest(from start: Int, to destination: Int, mode: TravelMode, weight: Double) throws -> Route {
        let source = graph.edges.count
        var costs = Array(repeating: Double.infinity, count: source + 1)
        var parents = Array(repeating: -1, count: source + 1)
        costs[source] = 0
        var heap = MinHeap(); heap.push(.init(cost: 0, state: source))
        var visits = 0
        while let item = heap.pop() {
            if item.cost > costs[item.state] { continue }
            visits += 1
            if visits % 256 == 0 { try Task.checkCancellation() }
            let previous: GraphEdge? = item.state == source ? nil : graph.edges[item.state]
            let node = previous?.to ?? start
            if node == destination {
                var ids: [Int] = []; var state = item.state
                while state != source { ids.append(state); state = parents[state] }
                return route(ids: ids.reversed(), mode: mode)
            }
            for edgeID in outgoing[node] {
                let edge = graph.edges[edgeID]
                guard edge.modes.contains(mode), allowed(previous: previous, next: edge, mode: mode) else { continue }
                let turn = turnMetrics(previous: previous, next: edge, mode: mode)
                let cost = item.cost + Self.seconds(edge, mode: mode) + turn.seconds
                    + weight * (Self.discomfort(edge, mode: mode) + turn.discomfort)
                if cost < costs[edgeID] {
                    costs[edgeID] = cost; parents[edgeID] = item.state
                    heap.push(.init(cost: cost, state: edgeID))
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

    public static func seconds(_ edge: GraphEdge, mode: TravelMode) -> Double {
        let kph: Double
        if mode == .bike {
            kph = edge.isRough ? 11 : edge.facility == "sharedPath" ? 14 : 18
        } else {
            let defaults: [String: Double] = ["motorway":70, "motorway_link":32, "trunk":50, "trunk_link":28,
                "primary":35, "primary_link":22, "secondary":32, "secondary_link":20, "tertiary":28,
                "tertiary_link":18, "residential":22, "unclassified":22, "living_street":12, "service":12]
            let assumed = defaults[edge.highway] ?? 18
            var tagged: Double?
            if let s = edge.maxspeed, let value = Double(s.components(separatedBy: " ")[0]), value > 0 {
                tagged = s.contains("mph") ? value * 1.609344 : value
            }
            kph = max(5, min(assumed, (tagged ?? 160) * 0.8))
        }
        return edge.meters / (kph / 3.6)
    }

    public static func discomfort(_ edge: GraphEdge, mode: TravelMode) -> Double {
        let km = edge.meters / 1000
        if mode == .drive {
            // Residential distance discourages shortcutting. Highway entries are handled at transitions.
            return km * (edge.isResidential ? 65 : edge.highway == "service" ? 100 : edge.isHighway ? 35 : 12)
        }
        let base: Double = edge.hasCycleTrackTag ? 8 : edge.facility == "sharedPath" ? 20 : edge.facility == "lane" ? 32 : edge.isArterial ? 140 : edge.isResidential ? 35 : 65
        return km * (base + (edge.isRough ? 55 : 0) + (edge.surface == nil ? 8 : 0))
    }

    func turnMetrics(previous: GraphEdge?, next: GraphEdge, mode: TravelMode) -> RouteMetrics {
        var result = RouteMetrics()
        guard let previous else { return result }
        let a = previous.geometry[previous.geometry.count - 2], b = previous.geometry.last!, c = next.geometry[1]
        let scale = cos(b[1] * .pi / 180)
        let ux = (b[0] - a[0]) * scale, uy = b[1] - a[1]
        let vx = (c[0] - b[0]) * scale, vy = c[1] - b[1]
        let angle = atan2(ux * vy - uy * vx, ux * vx + uy * vy) * 180 / .pi
        let turn = abs(angle) > 35 && previous.wayID != next.wayID
        result.turns = turn ? 1 : 0
        result.arterialLefts = turn && angle > 35 && (previous.isArterial || next.isArterial) ? 1 : 0
        result.highwayEntries = !previous.isHighway && next.isHighway ? 1 : 0
        result.seconds = (turn ? (mode == .drive ? 5 : 2) : 0) + (graph.nodes[next.from].signal ? (mode == .drive ? 12 : 8) : 0)
        result.discomfort = mode == .drive ? Double(result.turns * 22 + result.arterialLefts * 65 + result.highwayEntries * 180) : Double(result.turns * 6 + result.arterialLefts * 25)
        return result
    }

    private func route(ids: [Int], mode: TravelMode) -> Route {
        var metrics = RouteMetrics(), coordinates: [Coordinate] = [], streets: [String] = []
        var previous: GraphEdge?
        for id in ids {
            let e = graph.edges[id], t = turnMetrics(previous: previous, next: e, mode: mode)
            metrics.meters += e.meters; metrics.seconds += Self.seconds(e, mode: mode) + t.seconds
            metrics.discomfort += Self.discomfort(e, mode: mode) + t.discomfort
            metrics.turns += t.turns; metrics.arterialLefts += t.arterialLefts; metrics.highwayEntries += t.highwayEntries
            if e.isResidential { metrics.residentialMeters += e.meters }
            if e.isArterial { metrics.arterialMeters += e.meters }
            if e.hasCycleTrackTag { metrics.cycleTrackMeters += e.meters }
            if e.surface == nil { metrics.unknownSurfaceMeters += e.meters }
            if e.incline == nil { metrics.unknownGradeMeters += e.meters }
            if e.isRough { metrics.roughMeters += e.meters }
            coordinates.append(contentsOf: previous == nil ? e.coordinates : Array(e.coordinates.dropFirst()))
            if !e.name.isEmpty && streets.last != e.name { streets.append(e.name) }
            previous = e
        }
        return Route(edgeIDs: ids, coordinates: coordinates, metrics: metrics, streetNames: streets)
    }
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
