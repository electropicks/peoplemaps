import XCTest
@testable import PeoplemapsCore

final class RoutingTests: XCTestCase {
    private func edge(id: Int = 0, from: Int = 0, to: Int = 1, way: Int64 = 10,
                      meters: Double = 100, highway: String = "residential", facility: String = "none",
                      surface: String? = "asphalt", geometry: [[Double]] = [[-122.36,47.64],[-122.35,47.64]]) -> GraphEdge {
        GraphEdge(id: id, from: from, to: to, wayID: way, geometry: geometry, meters: meters,
                  modes: [.drive,.bike], highway: highway, name: "Test Street", surface: surface,
                  maxspeed: nil, incline: nil, facility: facility)
    }
    private func route(id: Int, seconds: Double, cost: Double) -> Route {
        var m = RouteMetrics(); m.seconds = seconds; m.discomfort = cost
        return Route(edgeIDs: [id], coordinates: [], metrics: m, streetNames: [])
    }
    private func graph(restrictions: [TurnRestriction] = []) -> StreetGraph {
        StreetGraph(schemaVersion: 1, bounds: [47.6,-122.4,47.7,-122.3], nodes: [
            GraphNode(osmID: 1,lat: 47.64,lon: -122.36,signal: false),
            GraphNode(osmID: 2,lat: 47.64,lon: -122.35,signal: false),
            GraphNode(osmID: 3,lat: 47.65,lon: -122.35,signal: false)
        ], edges: [edge(), edge(id:1,from:1,to:2,way:20,highway:"primary",geometry:[[-122.35,47.64],[-122.35,47.65]])], restrictions: restrictions, places: [])
    }
    func testHardBudgetUsesUnroundedSeconds() {
        let fast = route(id:0,seconds:600,cost:100)
        XCTAssertNil(NativeRouter.selectCalmer(candidates:[route(id:1,seconds:720.01,cost:1)],fastest:fast,extraMinutes:2))
        XCTAssertNotNil(NativeRouter.selectCalmer(candidates:[route(id:1,seconds:720,cost:1)],fastest:fast,extraMinutes:2))
    }
    func testZeroBudgetCannotReturnSlowerRoute() {
        let f=route(id:0,seconds:100,cost:100)
        XCTAssertNil(NativeRouter.selectCalmer(candidates:[route(id:1,seconds:100.1,cost:20)],fastest:f,extraMinutes:0))
    }
    func testLowestComfortCostWithinBudgetWins() {
        let f=route(id:0,seconds:100,cost:100)
        let c=NativeRouter.selectCalmer(candidates:[route(id:1,seconds:150,cost:50),route(id:2,seconds:160,cost:20),route(id:3,seconds:400,cost:1)],fastest:f,extraMinutes:2)
        XCTAssertEqual(c?.edgeIDs,[2])
    }
    func testSameRouteAndNegligibleImprovementAreNotAlternatives() {
        let f=route(id:0,seconds:100,cost:100)
        XCTAssertNil(NativeRouter.selectCalmer(candidates:[f,route(id:1,seconds:101,cost:99)],fastest:f,extraMinutes:5))
    }
    func testCyclingPrefersTrackTagsAndPenalizesRoughSurface() {
        XCTAssertLessThan(NativeRouter.discomfort(edge(facility:"track"),mode:.bike),NativeRouter.discomfort(edge(highway:"primary"),mode:.bike))
        XCTAssertGreaterThan(NativeRouter.discomfort(edge(surface:"gravel"),mode:.bike),NativeRouter.discomfort(edge(surface:"asphalt"),mode:.bike))
    }
    func testDrivingDiscouragesResidentialShortcutting() {
        XCTAssertGreaterThan(NativeRouter.discomfort(edge(),mode:.drive),NativeRouter.discomfort(edge(highway:"tertiary"),mode:.drive))
    }
    func testUnknownSurfaceIsNotTreatedAsKnownPavement() {
        XCTAssertGreaterThan(NativeRouter.discomfort(edge(surface:nil),mode:.bike),NativeRouter.discomfort(edge(surface:"asphalt"),mode:.bike))
    }
    func testModeledSpeedIsFiniteAndPositive() {
        for mode in TravelMode.allCases { XCTAssertGreaterThan(NativeRouter.seconds(edge(),mode:mode),0) }
    }
    func testNoTurnRestrictionAppliesOnlyToItsMode() {
        let r=TurnRestriction(via:1,fromWay:10,toWay:20,kind:"no_left_turn",mode:.drive,osmID:99)
        let g=graph(restrictions:[r]), router=NativeRouter(graph:graph(restrictions:[r]))
        XCTAssertFalse(router.allowed(previous:g.edges[0],next:g.edges[1],mode:.drive))
        XCTAssertTrue(router.allowed(previous:g.edges[0],next:g.edges[1],mode:.bike))
    }
    func testOnlyTurnRestrictionBlocksOtherWays() {
        let r=TurnRestriction(via:1,fromWay:10,toWay:30,kind:"only_right_turn",mode:.drive,osmID:99)
        let g=graph(restrictions:[r])
        XCTAssertFalse(NativeRouter(graph:g).allowed(previous:g.edges[0],next:g.edges[1],mode:.drive))
    }
    func testSameWayNoUTurnAllowsContinuation() {
        let r=TurnRestriction(via:1,fromWay:10,toWay:10,kind:"no_u_turn",mode:.drive,osmID:99)
        let router=NativeRouter(graph:graph(restrictions:[r]))
        XCTAssertTrue(router.allowed(previous:edge(),next:edge(id:1,from:1,to:2),mode:.drive))
        XCTAssertFalse(router.allowed(previous:edge(),next:edge(id:1,from:1,to:0),mode:.drive))
    }
    func testArterialLeftComesFromGeometryNotInventedProtection() {
        let g=graph(),router=NativeRouter(graph:graph())
        let m=router.turnMetrics(previous:g.edges[0],next:g.edges[1],mode:.drive)
        XCTAssertEqual(m.turns,1);XCTAssertEqual(m.arterialLefts,1)
    }
    func testMissingGraphIsRejected() {
        XCTAssertThrowsError(try StreetGraph(schemaVersion:99,bounds:[],nodes:[],edges:[],restrictions:[],places:[]).validate())
    }
    func testOutsideCoverageAndSamePlaceAreExplicitErrors() {
        let router=NativeRouter(graph:graph())
        let a=Place(id:"a",name:"A",lat:47.64,lon:-122.36,category:"test")
        let outside=Place(id:"b",name:"B",lat:48,lon:-122.35,category:"test")
        XCTAssertThrowsError(try router.compute(.init(origin:a,destination:outside,mode:.drive,extraMinutes:5))) { XCTAssertEqual($0 as? RoutingError,.outsideCoverage) }
        XCTAssertThrowsError(try router.compute(.init(origin:a,destination:a,mode:.drive,extraMinutes:5))) { XCTAssertEqual($0 as? RoutingError,.samePlace) }
    }
    func testNoConnectionIsAnErrorNotAStraightLine() {
        let router=NativeRouter(graph:graph())
        let a=Place(id:"a",name:"A",lat:47.65,lon:-122.35,category:"test")
        let b=Place(id:"b",name:"B",lat:47.64,lon:-122.36,category:"test")
        XCTAssertThrowsError(try router.compute(.init(origin:a,destination:b,mode:.drive,extraMinutes:5)))
    }
    func testInvalidBudgetRejected() {
        let a=Place(id:"a",name:"A",lat:47.64,lon:-122.36,category:"test")
        XCTAssertThrowsError(try NativeRouter(graph:graph()).compute(.init(origin:a,destination:a,mode:.drive,extraMinutes:-1))) { XCTAssertEqual($0 as? RoutingError,.invalidBudget) }
    }
    func testBundledSeattleRoutesAreContinuousLegalAndWithinBudget() throws {
        let g=try StreetGraph.bundled(),router=NativeRouter(graph:try StreetGraph.bundled())
        let a=try XCTUnwrap(g.places.first{$0.id=="way/37056567"})
        let b=try XCTUnwrap(g.places.first{$0.id=="relation/1047789"})
        for mode in TravelMode.allCases {
            let result=try router.compute(.init(origin:a,destination:b,mode:mode,extraMinutes:5))
            for route in [result.fastest,result.calmer].compactMap({$0}) {
                XCTAssertGreaterThan(route.metrics.meters,1000)
                XCTAssertLessThanOrEqual(route.metrics.seconds,result.fastest.metrics.seconds+300.000001)
                for (first,second) in zip(route.edgeIDs,route.edgeIDs.dropFirst()) {
                    XCTAssertEqual(g.edges[first].to,g.edges[second].from)
                    XCTAssertTrue(router.allowed(previous:g.edges[first],next:g.edges[second],mode:mode))
                }
                XCTAssertTrue(route.edgeIDs.allSatisfy{g.edges[$0].modes.contains(mode)})
            }
        }
    }
    func testPlaceSearchIsBoundedAndCaseInsensitive() throws {
        let g=try StreetGraph.bundled()
        XCTAssertEqual(g.search("gAs WoRkS").first?.name,"Gas Works Park")
        XCTAssertTrue(g.search("unfindableXYZ").isEmpty)
        XCTAssertTrue(g.places.allSatisfy{g.contains($0.coordinate)})
    }
    func testMuseumSnapsToConnectedNetworkForBothModes() throws {
        let g=try StreetGraph.bundled(),router=NativeRouter(graph:try StreetGraph.bundled())
        let a=try XCTUnwrap(g.places.first{$0.id=="way/37058377"})
        let b=try XCTUnwrap(g.places.first{$0.id=="way/160545994"})
        for mode in TravelMode.allCases {
            let c=try router.compute(.init(origin:a,destination:b,mode:mode,extraMinutes:2))
            XCTAssertLessThan(c.destinationSnapMeters,100)
            XCTAssertGreaterThan(c.fastest.metrics.meters,3000)
        }
    }
    func testCancelledSearchStopsBeforeReturning() async throws {
        let g=try StreetGraph.bundled(),router=NativeRouter(graph:try StreetGraph.bundled())
        let a=try XCTUnwrap(g.places.first{$0.id=="node/693337509"})
        let b=try XCTUnwrap(g.places.first{$0.id=="relation/1047789"})
        let task=Task { try await router.compare(.init(origin:a,destination:b,mode:.drive,extraMinutes:10)) }
        task.cancel()
        do { _=try await task.value; XCTFail("Cancelled routing returned a route") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

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
