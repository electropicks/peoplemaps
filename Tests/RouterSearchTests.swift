import XCTest
@testable import PeoplemapsCore

final class RouterSearchTests: XCTestCase {
    private static let graph = try! StreetGraph.bundled()
    private static let router = NativeRouter(graph: graph)
    private func request(_ budget: Int) throws -> RouteRequest {
        let places = Self.graph.places
        let a = try XCTUnwrap(places.first { $0.id == "way/37056567" }), b = try XCTUnwrap(places.first { $0.id == "relation/1047789" })
        return RouteRequest(origin: a, destination: b, mode: .walk, extraMinutes: budget)
    }

    func testACancelledRequestThrowsCancellation() throws {
        let cancel = CancelFlag(); cancel.cancel()
        for budget in [0, 5] {
            XCTAssertThrowsError(try Self.router.compute(try request(budget), cancel: cancel)) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        }
    }

    func testCancellingTheTaskStopsAnAsyncCompare() async throws {
        let router = Self.router, request = try request(5)
        let task = Task.detached { try await router.compare(request) }
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled compare should throw") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    func testConcurrentRequestsMatchOneAtATime() throws {
        let request = try request(5)
        let alone = try Self.router.compute(request)
        nonisolated(unsafe) var results = [RouteComparison?](repeating: nil, count: 6)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: results.count) { i in
            let c = try? Self.router.compute(request)
            lock.lock(); results[i] = c; lock.unlock()
        }
        for c in results {
            let c = try XCTUnwrap(c)
            XCTAssertEqual(c.fastest.edgeIDs, alone.fastest.edgeIDs)
            XCTAssertEqual(c.calmer?.edgeIDs, alone.calmer?.edgeIDs)
            XCTAssertEqual(c.candidateCount, alone.candidateCount)
        }
    }
}

/// The router's init-time structures against the plain algorithms they replaced.
final class RouterIndexTests: XCTestCase {
    private static let graph = try! StreetGraph.bundled()
    private static let router = NativeRouter(graph: graph)

    /// Kosaraju over sets, as the router first did it.
    private func largestComponent(_ mode: TravelMode) -> Set<Int> {
        let g = Self.graph
        var out = Array(repeating: [Int](), count: g.nodes.count), inc = out
        for e in g.edges { out[e.from].append(e.id); inc[e.to].append(e.id) }
        var visited = Set<Int>(), order: [Int] = []
        for root in g.nodes.indices where !visited.contains(root) {
            var stack: [(Int, Bool)] = [(root, false)]
            while let (node, expanded) = stack.popLast() {
                if expanded { order.append(node); continue }
                if !visited.insert(node).inserted { continue }
                stack.append((node, true))
                for id in out[node] where g.edges[id].modes.contains(mode) { if !visited.contains(g.edges[id].to) { stack.append((g.edges[id].to, false)) } }
            }
        }
        visited.removeAll()
        var largest = Set<Int>()
        for root in order.reversed() where !visited.contains(root) {
            var component = Set<Int>(), stack = [root]
            while let node = stack.popLast() {
                if !visited.insert(node).inserted { continue }
                component.insert(node)
                for id in inc[node] where g.edges[id].modes.contains(mode) { if !visited.contains(g.edges[id].from) { stack.append(g.edges[id].from) } }
            }
            if component.count > largest.count { largest = component }
        }
        return largest
    }

    func testConnectedNodesMatchTheSetBasedComponent() {
        for mode in TravelMode.allCases {
            let members = Self.router.connectedNodes[mode]!
            XCTAssertEqual(Set(members.indices.filter { members[$0] }), largestComponent(mode), "\(mode)")
        }
    }

    /// The nearest usable node within 400 m by scanning every node, lowest id on a tie.
    func testGridSnapMatchesAFullScan() {
        let g = Self.graph
        var usable: [TravelMode: (out: [Bool], in: [Bool])] = [:]
        for mode in TravelMode.allCases {
            var o = Array(repeating: false, count: g.nodes.count), i = o
            for e in g.edges where e.modes.contains(mode) && !e.isHighway { o[e.from] = true; i[e.to] = true }
            usable[mode] = (o, i)
        }
        var state: UInt64 = 7
        func random() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(1 << 53) }
        let b = g.bounds
        var found = 0, failed = 0
        for n in 0..<150 {
            // Half the points sit on a node, to hit exact ties and zero distances.
            let point = n % 2 == 0 ? g.nodes[Int(random() * Double(g.nodes.count))].coordinate
                : Coordinate(lat: b[0] + random() * (b[2] - b[0]), lon: b[1] + random() * (b[3] - b[1]))
            let place = Place(id: "p\(n)", name: "P", lat: point.lat, lon: point.lon, category: "test")
            for mode in TravelMode.allCases {
                let connected = Self.router.connectedNodes[mode]!
                for departing in [true, false] {
                    var best: (Int, Double)?
                    for i in g.nodes.indices where connected[i] {
                        let d = point.distance(to: g.nodes[i].coordinate)
                        guard d <= 400, best == nil || d < best!.1, (departing ? usable[mode]!.out : usable[mode]!.in)[i] else { continue }
                        best = (i, d)
                    }
                    let got = try? Self.router.snap(place, mode: mode, departing: departing)
                    XCTAssertEqual(got?.node, best?.0, "\(point) \(mode) \(departing)")
                    XCTAssertEqual(got?.distance, best?.1)
                    if best != nil { found += 1 } else { failed += 1 }
                }
            }
        }
        XCTAssertGreaterThan(found, 100); XCTAssertGreaterThan(failed, 10, "Some points should be too far from any node")
    }
}
