import XCTest
@testable import PeoplemapsCore

/// Straight segments laid out on a local grid so headings are exact: x east, y north, in metres.
private enum Grid {
    static func coordinate(_ x: Double, _ y: Double) -> Coordinate {
        Coordinate(lat: 47.6 + y / 111_195, lon: -122.3 + x / (111_195 * cos(47.6 * .pi / 180)))
    }
    /// An edge from (x0, y0) to (x1, y1).
    static func edge(_ id: Int, _ from: (Double, Double), _ to: (Double, Double), name: String, footway: String? = nil, highway: String = "residential") -> GraphEdge {
        var e = GraphEdge(id: id, from: id, to: id + 1, wayID: Int64(id), coordinates: [coordinate(from.0, from.1), coordinate(to.0, to.1)],
                          meters: hypot(to.0 - from.0, to.1 - from.1), modes: TravelMode.allCases, highway: highway, name: name)
        e.footway = footway
        return e
    }
    static func route(_ edges: [GraphEdge], factors: [Int: [Factor]] = [:], seconds: Double = 0) -> Route {
        var m = RouteMetrics(); m.meters = edges.reduce(0) { $0 + $1.meters }; m.seconds = seconds == 0 ? m.meters / 10 : seconds
        return Route(edgeIDs: edges.map(\.id), edgeMeters: edges.map(\.meters), coordinates: edges.flatMap(\.coordinates), metrics: m, streetNames: [],
                     junctionFactors: edges.indices.map { factors[$0] ?? [] }, edges: edges)
    }
    /// A heading change of `degrees` (positive = left) after a northbound first block, on a differently named street.
    static func turnRoute(_ degrees: Double, mode: TravelMode = .drive) -> NavigationPlan {
        let heading = degrees * .pi / 180   // from north, counter-clockwise positive
        let end = (-100 * sin(heading), 100 + 100 * cos(heading))
        return route([edge(0, (0, 0), (0, 100), name: "Main Street"), edge(1, (0, 100), end, name: "Oak Avenue")]).navigationPlan(mode: mode)
    }
}

final class NavigationPlanTests: XCTestCase {
    func testLeftTurnAtNamedJunction() {
        let plan = Grid.turnRoute(90)
        XCTAssertEqual(plan.steps.map(\.maneuver), [.depart, .turn(.left), .arrive])
        XCTAssertEqual(plan.steps[0].instruction, "Head north on Main St")
        XCTAssertEqual(plan.steps[1].instruction, "Turn left onto Oak Ave")
        XCTAssertEqual(plan.steps[2].instruction, "Arrive at destination")
        XCTAssertEqual(plan.steps[2].meters, 0)
        XCTAssertTrue(plan.steps[2].coordinates.isEmpty)
        XCTAssertEqual(plan.steps[0].meters, 100, accuracy: 0.5)
        XCTAssertEqual(plan.steps[1].meters, 100, accuracy: 0.5)
        XCTAssertEqual(plan.steps[0].seconds + plan.steps[1].seconds, plan.seconds, accuracy: 0.001)
    }

    func testTurnThresholds() {
        let expected: [(Double, Maneuver?)] = [
            (30, nil), (20, nil), (10, .arrive), (40, .turn(.slightLeft)), (-40, .turn(.slightRight)), (59, .turn(.slightLeft)), (65, .turn(.left)), (-90, .turn(.right)),
            (130, .turn(.left)), (140, .turn(.sharpLeft)), (-165, .turn(.sharpRight)), (175, .turn(.uTurn)), (-175, .turn(.uTurn))]
        for (degrees, want) in expected {
            let plan = Grid.turnRoute(degrees)
            let got = plan.steps.dropFirst().first!.maneuver
            if let want { XCTAssertEqual(got, want, "\(degrees) degrees") }
            else { XCTAssertEqual(got, .continueOnto, "\(degrees) degrees: a renamed near-straight road is a continue") }
        }
        XCTAssertEqual(Grid.turnRoute(-40).steps[1].instruction, "Turn slightly right onto Oak Ave")
        XCTAssertEqual(Grid.turnRoute(150).steps[1].instruction, "Make a sharp left onto Oak Ave")
        XCTAssertEqual(Grid.turnRoute(178).steps[1].instruction, "Make a U-turn")
    }

    func testUnnamedFootwayNeverCreatesAManeuver() {
        let edges = [Grid.edge(0, (0, 0), (0, 100), name: "Main Street"),
                     Grid.edge(1, (0, 100), (50, 100), name: "", footway: "sidewalk", highway: "footway"),
                     Grid.edge(2, (50, 100), (50, 200), name: "", highway: "service"),
                     Grid.edge(3, (50, 200), (50, 300), name: "Main Street")]
        let plan = Grid.route(edges).navigationPlan(mode: .walk)
        XCTAssertEqual(plan.steps.map(\.maneuver), [.depart, .arrive])
        XCTAssertEqual(plan.steps[0].meters, 350, accuracy: 0.5)
    }

    func testCloseTurnsAreBothKeptButShortContinuesAreDropped() {
        // Left onto Oak, 10 m later right onto Pine: turns are never merged away.
        let edges = [Grid.edge(0, (0, 0), (0, 100), name: "Main Street"), Grid.edge(1, (0, 100), (-10, 100), name: "Oak Avenue"),
                     Grid.edge(2, (-10, 100), (-10, 200), name: "Pine Street")]
        let drive = Grid.route(edges).navigationPlan(mode: .drive)
        XCTAssertEqual(drive.steps.map(\.maneuver), [.depart, .turn(.left), .turn(.right), .arrive])
        // A short "continue onto" (20 degree bend, 10 m before a turn) folds into the step before it, so the turn's step starts at the turn.
        let bend = Grid.edge(1, (0, 100), (-3.4, 109.4), name: "Oak Avenue")
        let after = Grid.edge(2, (-3.4, 109.4), (-103.4, 109.4), name: "Pine Street")
        let plan = Grid.route([Grid.edge(0, (0, 0), (0, 100), name: "Main Street"), bend, after]).navigationPlan(mode: .drive)
        XCTAssertEqual(plan.steps.map(\.maneuver), [.depart, .turn(.left), .arrive])
        XCTAssertEqual(plan.steps[0].coordinates.count, 3)
        XCTAssertEqual(plan.steps[0].street, "Oak Ave")
        XCTAssertEqual(plan.steps[1].coordinates.first, after.coordinates.first)
        XCTAssertEqual(plan.steps.reduce(0) { $0 + $1.meters }, plan.meters, accuracy: 0.001)
        // A longer one is kept.
        let long = Grid.route([Grid.edge(0, (0, 0), (0, 100), name: "Main Street"), Grid.edge(1, (0, 100), (-34, 194), name: "Oak Avenue"),
                               Grid.edge(2, (-34, 194), (-34, 294), name: "Pine Street")])
        XCTAssertEqual(long.navigationPlan(mode: .drive).steps.map(\.maneuver).first(where: { $0 != .depart }), .continueOnto)
    }

    func testContinueOntoVersusNoManeuver() {
        let renamed = Grid.route([Grid.edge(0, (0, 0), (0, 100), name: "Main Street"), Grid.edge(1, (0, 100), (-36, 199), name: "Roosevelt Way")])
        XCTAssertEqual(renamed.navigationPlan(mode: .drive).steps.map(\.maneuver), [.depart, .continueOnto, .arrive])
        XCTAssertEqual(renamed.navigationPlan(mode: .drive).steps[1].instruction, "Continue onto Roosevelt Way")
        // A rename on a near-straight road is silent, and becomes the street going forward.
        let straight = Grid.route([Grid.edge(0, (0, 0), (0, 100), name: "Main Street"), Grid.edge(1, (0, 100), (0, 200), name: "Roosevelt Way")])
        let silent = straight.navigationPlan(mode: .drive)
        XCTAssertEqual(silent.steps.map(\.maneuver), [.depart, .arrive])
        XCTAssertEqual(silent.steps[0].street, "Roosevelt Way")
        XCTAssertEqual(silent.steps[0].instruction, "Head north on Main St")
        // Unnamed start: the first named street is announced however straight.
        let unnamedStart = Grid.route([Grid.edge(0, (0, 0), (0, 100), name: ""), Grid.edge(1, (0, 100), (0, 200), name: "Roosevelt Way")])
        let p = unnamedStart.navigationPlan(mode: .walk)
        XCTAssertEqual(p.steps.map(\.maneuver), [.depart, .continueOnto, .arrive])
        XCTAssertEqual(p.steps[0].instruction, "Head north")
        XCTAssertEqual(p.steps[1].instruction, "Continue onto Roosevelt Way")
        // Same name resumed after an unnamed stretch: nothing to say.
        let resumed = Grid.route([Grid.edge(0, (0, 0), (0, 100), name: "Main Street"), Grid.edge(1, (0, 100), (0, 150), name: ""),
                                  Grid.edge(2, (0, 150), (0, 250), name: "Main Street")])
        XCTAssertEqual(resumed.navigationPlan(mode: .drive).steps.map(\.maneuver), [.depart, .arrive])
        // Same name across a bend: also nothing.
        let bend = Grid.route([Grid.edge(0, (0, 0), (0, 100), name: "Main Street"), Grid.edge(1, (0, 100), (-100, 100), name: "Main Street")])
        XCTAssertEqual(bend.navigationPlan(mode: .drive).steps.map(\.maneuver), [.depart, .arrive])
    }

    func testNameShortening() {
        XCTAssertEqual(NavigationBuilderProbe.shorten("1st Avenue North"), "1st Ave N")
        XCTAssertEqual(NavigationBuilderProbe.shorten("North 38th Street"), "N 38th St")
        XCTAssertEqual(NavigationBuilderProbe.shorten("West Highland Drive"), "W Highland Dr")
        XCTAssertEqual(NavigationBuilderProbe.shorten("Southwest Alaska Street"), "SW Alaska St")
        XCTAssertEqual(NavigationBuilderProbe.shorten("Eastlake Avenue East"), "Eastlake Ave E")
        XCTAssertEqual(NavigationBuilderProbe.shorten("Boulevard Place Road"), "Blvd Pl Rd")
        XCTAssertEqual(NavigationBuilderProbe.shorten("Northwest Market Street"), "NW Market St")
        XCTAssertEqual(NavigationBuilderProbe.shorten("Eastern West Way"), "Eastern West Way", "directionals only at the ends, whole words only")
        XCTAssertEqual(NavigationBuilderProbe.shorten("Queen Anne Avenue North"), "Queen Anne Ave N")
    }

    func testCalmNoteFromRecordedFactors() {
        let edges = [Grid.edge(0, (0, 0), (0, 100), name: "Main Street"), Grid.edge(1, (0, 100), (-100, 100), name: "Oak Avenue")]
        let plan = Grid.route(edges, factors: [1: [.turn, .leftAtSignal, .signal]]).navigationPlan(mode: .drive)
        XCTAssertEqual(plan.steps[1].calmNote, "Signalled left")
        XCTAssertNil(plan.steps[0].calmNote)
        XCTAssertNil(plan.steps[2].calmNote)
        XCTAssertNil(Grid.route(edges, factors: [1: [.turn]]).navigationPlan(mode: .drive).steps[1].calmNote)
        XCTAssertEqual(Grid.route(edges, factors: [1: [.stopSign, .signal]]).navigationPlan(mode: .drive).steps[1].calmNote, "Stop sign")
        XCTAssertEqual(Grid.route(edges, factors: [1: [.signal]]).navigationPlan(mode: .drive).steps[1].calmNote, "At a signal")
        XCTAssertEqual(Grid.route(edges, factors: [1: [.allWayStop, .stopSign]]).navigationPlan(mode: .drive).steps[1].calmNote, "All-way stop")
    }

    func testWalkingCrossingIsOneManeuverNotTwo() {
        let edges = [Grid.edge(0, (0, 0), (0, 100), name: "Main Street", footway: "sidewalk"),
                     Grid.edge(1, (0, 100), (0, 110), name: "", footway: "crossing", highway: "footway"),
                     Grid.edge(2, (0, 110), (0, 120), name: "", footway: "crossing", highway: "footway"),
                     Grid.edge(3, (0, 120), (0, 220), name: "Main Street", footway: "sidewalk")]
        for (factor, text, note) in [(Factor.signalCrossing, "Cross at the signal", "Signalled crossing"),
                                     (.markedCrossing, "Cross at the crosswalk", "Marked crossing"), (.unmarkedCrossing, "Cross the street", nil)] {
            let plan = Grid.route(edges, factors: [1: [factor]]).navigationPlan(mode: .walk)
            XCTAssertEqual(plan.steps.map(\.maneuver), [.depart, .cross, .arrive])
            XCTAssertEqual(plan.steps[1].instruction, text)
            XCTAssertEqual(plan.steps[1].calmNote, note)
        }
        XCTAssertEqual(Grid.route(edges).navigationPlan(mode: .walk).steps.map(\.maneuver), [.depart, .arrive], "no crossing factor, no maneuver")
        XCTAssertEqual(Grid.route(edges, factors: [1: [.sideStreetCrossing]]).navigationPlan(mode: .walk).steps.map(\.maneuver), [.depart, .arrive], "side streets are not announced")
        var named = edges; named[1].name = "Denny Way"; named[2].name = "Denny Way"
        XCTAssertEqual(Grid.route(named, factors: [1: [.unmarkedCrossing]]).navigationPlan(mode: .walk).steps[1].instruction, "Cross Denny Way")
    }

    func testRouteRecordsJunctionFactorsAndEdges() throws {
        let graph = try StreetGraph.bundled(), router = NativeRouter(graph: graph)
        let comparison = try router.compute(.init(origin: try XCTUnwrap(graph.places.first { $0.id == "node/693337509" }),
                                                  destination: try XCTUnwrap(graph.places.first { $0.id == "relation/1047789" }), mode: .drive, extraMinutes: 5))
        let route = comparison.fastest
        XCTAssertEqual(route.junctionFactors.count, route.edgeIDs.count)
        XCTAssertEqual(route.edges.map(\.id), route.edgeIDs)
        XCTAssertTrue(route.junctionFactors[0].isEmpty)
        XCTAssertTrue(route.junctionFactors.contains { !$0.isEmpty })
    }
}

/// Reaches the name shortener through a silently renamed street, so the tests use only the public surface.
private enum NavigationBuilderProbe {
    static func shorten(_ name: String) -> String {
        let plan = Grid.route([Grid.edge(0, (0, 0), (0, 100), name: "Start Road"), Grid.edge(1, (0, 100), (0, 200), name: name)]).navigationPlan(mode: .drive)
        return plan.steps[0].street
    }
}

/// Against the real bundled Seattle data.
final class NavigationSeattleTests: XCTestCase {
    private static let graph = try! StreetGraph.bundled()
    private static let router = NativeRouter(graph: graph)

    private func plan(for mode: TravelMode) throws -> (NavigationPlan, Route) {
        let place = { (id: String) in try XCTUnwrap(Self.graph.places.first { $0.id == id }) }
        let result = try Self.router.compute(.init(origin: try place("node/693337509"), destination: try place("relation/1047789"), mode: mode, extraMinutes: 5))
        let route = result.calmer ?? result.fastest
        return (route.navigationPlan(mode: mode), route)
    }
    private func print(_ plan: NavigationPlan, _ label: String) {
        Swift.print("--- \(label): \(plan.steps.count) steps, \(Int(plan.meters)) m, \(Int(plan.seconds)) s")
        for s in plan.steps {
            Swift.print(String(format: "  %-45@ %6.0f m %5.0f s  %@", s.instruction as NSString, s.meters, s.seconds, (s.calmNote.map { "[\($0)]" } ?? "") as NSString))
        }
    }

    func testDrivePlanFromKerryParkToGasWorks() throws {
        let (plan, route) = try plan(for: .drive)
        print(plan, "drive")
        XCTAssertEqual(plan.steps.first?.maneuver, .depart)
        XCTAssertEqual(plan.steps.last?.maneuver, .arrive)
        XCTAssertEqual(plan.steps.reduce(0) { $0 + $1.meters }, route.metrics.meters, accuracy: 1)
        XCTAssertEqual(plan.steps.reduce(0) { $0 + $1.seconds }, route.metrics.seconds, accuracy: 1)
        XCTAssertTrue(plan.steps.dropLast().allSatisfy { !$0.coordinates.isEmpty })
        XCTAssertTrue((4...15).contains(plan.steps.count), "\(plan.steps.count) steps")
        XCTAssertFalse(plan.steps.contains { ($0.calmNote ?? "").localizedCaseInsensitiveContains("safe") })
    }

    func testWalkPlanHasACrossing() throws {
        let (plan, route) = try plan(for: .walk)
        print(plan, "walk")
        XCTAssertEqual(plan.steps.first?.maneuver, .depart)
        XCTAssertEqual(plan.steps.last?.maneuver, .arrive)
        XCTAssertEqual(plan.steps.reduce(0) { $0 + $1.meters }, route.metrics.meters, accuracy: 1)
        XCTAssertTrue(plan.steps.contains { $0.maneuver == .cross })
    }
}
