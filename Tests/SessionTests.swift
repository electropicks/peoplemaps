import XCTest
@testable import PeoplemapsCore

private actor ControlledRouter: RouteComputing {
    var calls:[CheckedContinuation<RouteComparison,Error>]=[]
    func compare(_ request:RouteRequest) async throws -> RouteComparison {
        try await withCheckedThrowingContinuation { calls.append($0) }
    }
    var count:Int { calls.count }
    func fail(_ index:Int) { calls[index].resume(throwing:RoutingError.noConnection) }
    func succeed(_ index:Int,request:RouteRequest) {
        let route=Route(edgeIDs:[1],coordinates:[],metrics:RouteMetrics(),streetNames:[])
        calls[index].resume(returning:RouteComparison(request:request,fastest:route,calmer:nil,candidateCount:1,
            originSnapMeters:0,destinationSnapMeters:0,snappedOrigin:request.origin.coordinate,snappedDestination:request.destination.coordinate))
    }
}

@MainActor final class SessionTests:XCTestCase {
    private var request:RouteRequest {
        let a=Place(id:"a",name:"A",lat:47.64,lon:-122.35,category:"test")
        let b=Place(id:"b",name:"B",lat:47.65,lon:-122.35,category:"test")
        return .init(origin:a,destination:b,mode:.drive,extraMinutes:5)
    }
    private func waitForCalls(_ n:Int,router:ControlledRouter) async {
        for _ in 0..<1000 { if await router.count >= n { return }; await Task.yield() }
        XCTFail("Router did not receive request")
    }
    func testCancelCannotBeOverwrittenByLateError() async {
        let router=ControlledRouter()
        let subject=RouteSession(router:router);subject.start(request)
        await waitForCalls(1,router:router);subject.cancel();await router.fail(0)
        for _ in 0..<20 { await Task.yield() }
        guard case .cancelled=subject.state else { return XCTFail("Cancelled comparison was overwritten") }
        XCTAssertNil(subject.comparison)
    }
    func testRepeatedRequestSuppressesStaleFailureAndCanRetry() async {
        let router=ControlledRouter()
        let session=RouteSession(router:router);session.start(request)
        await waitForCalls(1,router:router);session.start(request)
        await waitForCalls(2,router:router);await router.fail(0)
        for _ in 0..<20 { await Task.yield() }
        guard case .loading=session.state else { return XCTFail("Stale result replaced current request") }
        await router.fail(1)
        for _ in 0..<20 { await Task.yield() }
        guard case .failed=session.state else { return XCTFail("Error state missing") }
        session.start(request);await waitForCalls(3,router:router)
        guard case .loading=session.state else { return XCTFail("Retry not loading") }
        session.cancel();await router.fail(2)
        XCTAssertNil(session.comparison)
    }
    func testStaleSuccessCannotReplaceNewRequest() async {
        let router=ControlledRouter()
        let subject=RouteSession(router:router)
        subject.start(request);await waitForCalls(1,router:router)
        let newer=RouteRequest(origin:request.destination,destination:request.origin,mode:.bike,extraMinutes:2)
        subject.start(newer);await waitForCalls(2,router:router)
        await router.succeed(1,request:newer)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(subject.comparison?.request,newer)
        await router.succeed(0,request:request)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(subject.comparison?.request,newer)
        XCTAssertNotNil(subject.comparison)
    }
}
