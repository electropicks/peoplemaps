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
        let request = try request(5)
        let task = Task { try await Self.router.compare(request) }
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
