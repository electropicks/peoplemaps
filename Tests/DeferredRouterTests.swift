import XCTest
@testable import PeoplemapsCore

private struct CannedRouter: RouteComputing {
    func compare(_ request: RouteRequest) async throws -> RouteComparison {
        let route = Route(edgeIDs: [1], coordinates: [], metrics: RouteMetrics(), streetNames: [])
        return RouteComparison(request: request, fastest: route, calmer: nil, candidateCount: 1, originSnapMeters: 0, destinationSnapMeters: 0,
                               snappedOrigin: request.origin.coordinate, snappedDestination: request.destination.coordinate)
    }
}

final class DeferredRouterTests: XCTestCase {
    private static let request = RouteRequest(origin: Place(id: "a", name: "A", lat: 47.64, lon: -122.35, category: "test"),
                                       destination: Place(id: "b", name: "B", lat: 47.65, lon: -122.35, category: "test"), mode: .drive, extraMinutes: 5)

    private var request: RouteRequest { Self.request }

    func testLoadStartsWithoutAnyRequest() async {
        let started = DispatchSemaphore(value: 0)
        _ = DeferredRouter { started.signal(); return CannedRouter() }
        let ran = await Task.detached { arrived(started) }.value
        XCTAssertTrue(ran, "The router should build as soon as the app launches")
    }

    func testCompareStaysPendingUntilReleased() async throws {
        let release = DispatchSemaphore(value: 0)
        let router = DeferredRouter { release.wait(); return CannedRouter() }
        let done = Flag()
        let request = request
        let answer = Task { defer { done.set() }; return try await router.compare(request) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(done.value, "compare must wait for the router, not fail or guess")
        release.signal()
        let comparison = try await answer.value
        XCTAssertTrue(done.value)
        XCTAssertEqual(comparison.request, request)
        XCTAssertEqual(comparison.fastest.edgeIDs, [1])
    }

    func testLoadFailureReachesEveryRequest() async {
        let router = DeferredRouter { throw RoutingError.missingData }
        for _ in 0..<2 {
            do { _ = try await router.compare(request); XCTFail("Expected missing data") }
            catch { XCTAssertEqual(error as? RoutingError, .missingData) }
        }
    }

    func testCancellingARequestLeavesTheRouterForTheNext() async throws {
        let release = DispatchSemaphore(value: 0)
        let router = DeferredRouter { release.wait(); return CannedRouter() }
        let request = request
        let first = Task { try await router.compare(request) }
        first.cancel()
        release.signal()
        _ = try? await first.value
        let comparison = try await router.compare(request)
        XCTAssertEqual(comparison.fastest.edgeIDs, [1])
    }
}

private func arrived(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 5) == .success }

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set_ = false
    var value: Bool { lock.withLock { set_ } }
    func set() { lock.withLock { set_ = true } }
}

final class GraphHeaderTests: XCTestCase {
    func testHeaderMatchesTheDecodedGraph() throws {
        let header = try StreetGraph.bundledHeader()
        let graph = try StreetGraph.bundled()
        XCTAssertEqual(header.bounds, graph.bounds)
        XCTAssertEqual(header.nodes, graph.nodes.count)
        XCTAssertEqual(header.boundsOnly.bounds, graph.bounds)
        XCTAssertTrue(header.boundsOnly.nodes.isEmpty)
    }

    func testHeaderGraphKnowsCoverage() throws {
        let header = try StreetGraph.bundledHeader().boundsOnly
        let full = try StreetGraph.bundled()
        for c in [Coordinate(lat: 47.65, lon: -122.35), Coordinate(lat: 47.61, lon: -122.33), Coordinate(lat: 47.9, lon: -122.35), Coordinate(lat: 47.65, lon: -122.0)] {
            XCTAssertEqual(header.coverage.contains(c), full.coverage.contains(c))
        }
    }

    func testEdgeCountMatchesTheDecodedGraph() throws {
        XCTAssertEqual(try StreetGraph.bundledEdgeCount(), try StreetGraph.bundled().edges.count)
    }

    func testHeaderRejectsShortOrForeignData() {
        XCTAssertThrowsError(try StreetGraph.Header(Data(count: 63)))
        XCTAssertThrowsError(try StreetGraph.Header(Data(count: 64)))
        XCTAssertThrowsError(try GraphBinary.edgeCount(Data(count: 64)))
    }

    func testSearchOpensFromTheHeaderAlone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peoplemaps-header-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try SearchIndex.bundled(graphNodes: try StreetGraph.bundledHeader().nodes, directory: directory)
        XCTAssertFalse(index.search("fremont").isEmpty)
    }
}
