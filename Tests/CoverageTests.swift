import XCTest
@testable import PeoplemapsCore

final class CoverageTests: XCTestCase {
    /// An L: the box 0..2 by 0..2 less its top right quarter.
    private let l = Coverage(bounds: [0, 0, 2, 2], rings: [[[0, 0], [2, 0], [2, 1], [1, 1], [1, 2], [0, 2], [0, 0]].map { Coordinate(lat: $0[1], lon: $0[0]) }])

    func testBoxCoversItsBoundsAndNothingElse() {
        let box = Coverage.box([47.6, -122.4, 47.7, -122.3])
        XCTAssertTrue(box.contains(Coordinate(lat: 47.65, lon: -122.35)))
        XCTAssertTrue(box.contains(Coordinate(lat: 47.6, lon: -122.4)), "the edge is inside")
        XCTAssertFalse(box.contains(Coordinate(lat: 47.71, lon: -122.35)))
        XCTAssertFalse(box.contains(Coordinate(lat: 47.65, lon: -122.29)))
    }

    func testAPointInTheBoxButOutsideThePolygonIsOutside() {
        XCTAssertTrue(l.contains(Coordinate(lat: 0.5, lon: 0.5)))
        XCTAssertTrue(l.contains(Coordinate(lat: 0.5, lon: 1.5)))
        XCTAssertTrue(l.contains(Coordinate(lat: 1.5, lon: 0.5)))
        XCTAssertFalse(l.contains(Coordinate(lat: 1.5, lon: 1.5)), "the notch is inside the box")
        XCTAssertFalse(l.contains(Coordinate(lat: 2.5, lon: 0.5)), "outside the box")
    }

    func testTheKingCountyPolygonLeavesTheBoxCornersOut() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Data/king-county-coverage.json")
        let county = try Coverage(polygonJSON: Data(contentsOf: file))
        XCTAssertEqual(county.bounds, [47.04048, -122.60694, 47.82399, -121.0019])
        for (name, c) in [("Seattle", Coordinate(lat: 47.6062, lon: -122.3321)), ("Bellevue", Coordinate(lat: 47.6101, lon: -122.2015)),
                          ("Issaquah", Coordinate(lat: 47.5301, lon: -122.0326)), ("North Bend", Coordinate(lat: 47.4957, lon: -121.7868)),
                          ("Federal Way", Coordinate(lat: 47.3223, lon: -122.3126)), ("Bothell", Coordinate(lat: 47.7601, lon: -122.2054))] {
            XCTAssertTrue(county.contains(c), name)
        }
        for (name, c) in [("north east corner of the box", Coordinate(lat: 47.82, lon: -121.01)), ("south west corner of the box", Coordinate(lat: 47.05, lon: -122.60)),
                          ("south east corner of the box", Coordinate(lat: 47.05, lon: -121.01))] {
            XCTAssertTrue(c.lat >= county.bounds[0] && c.lat <= county.bounds[2] && c.lon >= county.bounds[1] && c.lon <= county.bounds[3], "\(name) is in the box")
            XCTAssertFalse(county.contains(c), name)
        }
    }

    func testPolygonJSONMustBeWellFormed() {
        XCTAssertThrowsError(try Coverage(polygonJSON: Data("{}".utf8)))
        XCTAssertThrowsError(try Coverage(polygonJSON: Data(#"{"bbox":[0,0,1,1],"rings":[]}"#.utf8)))
        XCTAssertThrowsError(try Coverage(polygonJSON: Data(#"{"bbox":[0,0,1],"rings":[[[0,0],[1,0],[1,1],[0,0]]]}"#.utf8)))
        XCTAssertNoThrow(try Coverage(polygonJSON: Data(#"{"bbox":[0,0,1,1],"rings":[[[0,0],[1,0],[1,1],[0,0]]],"osmRelation":1}"#.utf8)))
    }

    func testTheBundledSeattleDataCoversItsBox() throws {
        let graph = try StreetGraph.bundled()
        XCTAssertEqual(graph.coverage, .box(graph.bounds))
        XCTAssertTrue(graph.coverage.contains(Coordinate(lat: 47.65, lon: -122.35)))
        XCTAssertFalse(graph.coverage.contains(Coordinate(lat: 47.9, lon: -122.35)))
    }

    func testRoutingRefusesAPlaceOutsideThePolygonEvenInsideTheBox() throws {
        // A graph whose coverage is the L: the router must use it, not the box.
        let g = Fixture.graph()
        let notched = StreetGraph(bounds: [47.6, -122.4, 47.7, -122.3], nodes: g.nodes, edges: g.edges, restrictions: [], places: [],
                                  coverage: Coverage(bounds: [47.6, -122.4, 47.7, -122.3], rings: [[(47.6, -122.4), (47.6, -122.3), (47.65, -122.3), (47.65, -122.35), (47.7, -122.35), (47.7, -122.4), (47.6, -122.4)]
                                      .map { Coordinate(lat: $0.0, lon: $0.1) }]))
        let router = NativeRouter(graph: notched)
        let inside = Place(id: "a", name: "A", lat: 47.64, lon: -122.35, category: "x"), notch = Place(id: "b", name: "B", lat: 47.68, lon: -122.32, category: "x")
        XCTAssertThrowsError(try router.compute(RouteRequest(origin: inside, destination: notch, mode: .drive, extraMinutes: 0))) {
            XCTAssertEqual($0 as? RoutingError, .outsideCoverage)
        }
        XCTAssertThrowsError(try router.compute(RouteRequest(origin: notch, destination: inside, mode: .drive, extraMinutes: 0))) {
            XCTAssertEqual($0 as? RoutingError, .startOutsideCoverage)
        }
    }

    func testCanSnapTellsARoadPlaceFromOneOffTheNetwork() throws {
        let router = NativeRouter(graph: try StreetGraph.bundled())
        let fremont = Place(id: "a", name: "Fremont", lat: 47.6513, lon: -122.3500, category: "x")
        let bay = Place(id: "b", name: "Water, inside the box", lat: 47.6200, lon: -122.3880, category: "x")
        for mode in TravelMode.allCases {
            XCTAssertTrue(router.canSnap(fremont, mode: mode), "\(mode)")
            XCTAssertFalse(router.canSnap(bay, mode: mode), "\(mode)")
        }
        XCTAssertTrue(router.graph.coverage.contains(bay.coordinate), "inside coverage, but with no road route to it")
    }

    func testTheProtocolDefaultAndDeferredRouterForwardCanSnap() async throws {
        struct Plain: RouteComputing { func compare(_ request: RouteRequest) async throws -> RouteComparison { throw RoutingError.noConnection } }
        let place = Place(id: "a", name: "A", lat: 47.65, lon: -122.35, category: "x")
        let plain = await Plain().canSnap(place, mode: .drive)
        XCTAssertTrue(plain, "routers that can't tell say yes")
        let bay = Place(id: "b", name: "B", lat: 47.6200, lon: -122.3880, category: "x")
        let deferred = DeferredRouter { NativeRouter(graph: try StreetGraph.bundled()) }
        let answer = await deferred.canSnap(bay, mode: .drive)
        XCTAssertFalse(answer)
    }
}
