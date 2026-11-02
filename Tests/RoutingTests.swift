import XCTest
@testable import PeoplemapsCore

/// Synthetic streets around one junction at node 1: node 0 is south, 2 is west, 3 is north, 4 is east.
enum Fixture {
    static let points = [Coordinate(lat: 47.640, lon: -122.350), Coordinate(lat: 47.641, lon: -122.350),
                         Coordinate(lat: 47.641, lon: -122.352), Coordinate(lat: 47.642, lon: -122.350),
                         Coordinate(lat: 47.641, lon: -122.348)]
    static func edge(id: Int = 0, from: Int, to: Int, way: Int64, highway: String = "residential",
                     modes: [TravelMode] = TravelMode.allCases, meters: Double = 100) -> GraphEdge {
        GraphEdge(id: id, from: from, to: to, wayID: way, coordinates: [points[from], points[to]], meters: meters,
                  modes: modes, highway: highway, name: "Street \(way)", surface: "asphalt")
    }
    static let northbound = edge(from: 0, to: 1, way: 10)
    static let westArterial = edge(id: 1, from: 1, to: 2, way: 20, highway: "primary")
    static let eastArterial = edge(id: 2, from: 1, to: 4, way: 21, highway: "primary")
    static let continueNorth = edge(id: 3, from: 1, to: 3, way: 11)
    static func graph(restrictions: [TurnRestriction] = []) -> StreetGraph {
        StreetGraph(bounds: [47.6, -122.4, 47.7, -122.3], nodes: points.enumerated().map { GraphNode(osm: Int64($0.offset), lat: $0.element.lat, lon: $0.element.lon) },
                    edges: [northbound, westArterial, eastArterial, continueNorth], restrictions: restrictions, places: [])
    }
    static func route(id: Int, seconds: Double, stress: Double, meters: Double = 1000) -> Route {
        var m = RouteMetrics(); m.seconds = seconds; m.meters = meters
        m.breakdown.add(.turn, amount: 1, cost: stress)
        return Route(edgeIDs: [id], edgeMeters: [meters], coordinates: [], metrics: m, streetNames: [])
    }
}

final class SelectionTests: XCTestCase {
    func testHardBudgetUsesUnroundedSeconds() {
        let fast = Fixture.route(id: 0, seconds: 600, stress: 500)
        XCTAssertNil(NativeRouter.selectCalmer(candidates: [Fixture.route(id: 1, seconds: 720.01, stress: 10)], fastest: fast, extraMinutes: 2))
        XCTAssertNotNil(NativeRouter.selectCalmer(candidates: [Fixture.route(id: 1, seconds: 720, stress: 10)], fastest: fast, extraMinutes: 2))
    }
    func testZeroBudgetCannotReturnSlowerRoute() {
        let fast = Fixture.route(id: 0, seconds: 100, stress: 500)
        XCTAssertNil(NativeRouter.selectCalmer(candidates: [Fixture.route(id: 1, seconds: 100.1, stress: 20)], fastest: fast, extraMinutes: 0))
    }
    func testLeastStressfulWithinBudgetWins() {
        let fast = Fixture.route(id: 0, seconds: 100, stress: 500)
        let picked = NativeRouter.selectCalmer(candidates: [Fixture.route(id: 1, seconds: 150, stress: 300), Fixture.route(id: 2, seconds: 160, stress: 100),
                                                             Fixture.route(id: 3, seconds: 400, stress: 1)], fastest: fast, extraMinutes: 2)
        XCTAssertEqual(picked?.edgeIDs, [2])
    }
    func testFurtherMinutesMustEarnTheirPlace() {
        // Twilight to Microsoft Café by car with a 10 minute limit: 6 more minutes for 17 less stress.
        let fast = Fixture.route(id: 0, seconds: 750, stress: 1087)
        let nearly = Fixture.route(id: 1, seconds: 762, stress: 606), slow = Fixture.route(id: 2, seconds: 1140, stress: 589)
        XCTAssertEqual(NativeRouter.selectCalmer(candidates: [nearly, slow], fastest: fast, extraMinutes: 10)?.edgeIDs, [1])
        XCTAssertEqual(NativeRouter.selectCalmer(candidates: [slow, nearly], fastest: fast, extraMinutes: 10)?.edgeIDs, [1])
    }
    func testTenMinutesForATinyGainIsNotOffered() {
        let fast = Fixture.route(id: 0, seconds: 600, stress: 1000)
        XCTAssertNil(NativeRouter.selectCalmer(candidates: [Fixture.route(id: 1, seconds: 1200, stress: 850)], fastest: fast, extraMinutes: 10),
                     "10 minutes must remove more than 150 equivalent seconds")
        XCTAssertNotNil(NativeRouter.selectCalmer(candidates: [Fixture.route(id: 1, seconds: 1200, stress: 849)], fastest: fast, extraMinutes: 10))
    }
    func testCalmerRouteThatCostsOnlySecondsIsOffered() {
        let fast = Fixture.route(id: 0, seconds: 900, stress: 1104)
        XCTAssertEqual(NativeRouter.selectCalmer(candidates: [Fixture.route(id: 1, seconds: 925, stress: 696)], fastest: fast, extraMinutes: 10)?.edgeIDs, [1])
    }
    func testSmallOrNegligibleImprovementsAreNotAlternatives() {
        let fast = Fixture.route(id: 0, seconds: 100, stress: 500)
        XCTAssertNil(NativeRouter.selectCalmer(candidates: [fast, Fixture.route(id: 1, seconds: 101, stress: 490)], fastest: fast, extraMinutes: 5))
    }
    func testThirtySecondFloorHoldsOnItsOwn() {
        let fast = Fixture.route(id: 0, seconds: 100, stress: 200)
        func offered(_ stress: Double) -> Bool {
            NativeRouter.selectCalmer(candidates: [Fixture.route(id: 1, seconds: 101, stress: stress)], fastest: fast, extraMinutes: 5) != nil
        }
        XCTAssertFalse(offered(175), "25 less clears the 5% floor and the price, but not the 30 floor")
        XCTAssertTrue(offered(170))
    }
    func testFivePercentFloorHoldsOnItsOwn() {
        let fast = Fixture.route(id: 0, seconds: 100, stress: 1000)
        func offered(_ stress: Double) -> Bool {
            NativeRouter.selectCalmer(candidates: [Fixture.route(id: 1, seconds: 101, stress: stress)], fastest: fast, extraMinutes: 5) != nil
        }
        XCTAssertFalse(offered(960), "40 less clears the 30 floor and the price, but not the 5% floor")
        XCTAssertFalse(offered(950), "Exactly 5% is not under the floor")
        XCTAssertTrue(offered(949))
    }
    func testNearlyIdenticalPathCountsOnlyWhenItIsMeaningfullyCalmer() {
        func route(_ ids: [Int], stress: Double) -> Route {
            var m = RouteMetrics(); m.meters = 1000; m.seconds = ids == [1, 2, 3] ? 100 : 110; m.breakdown.add(.turn, amount: 1, cost: stress)
            return Route(edgeIDs: ids, edgeMeters: [450, 450, 100], coordinates: [], metrics: m, streetNames: [])
        }
        let fast = route([1, 2, 3], stress: 500)
        XCTAssertEqual(NativeRouter.selectCalmer(candidates: [route([1, 2, 4], stress: 100)], fastest: fast, extraMinutes: 5)?.edgeIDs, [1, 2, 4],
                       "One block different is a real choice when that block is the stressful one")
        XCTAssertNil(NativeRouter.selectCalmer(candidates: [route([1, 2, 4], stress: 480)], fastest: fast, extraMinutes: 5),
                     "One block different with no meaningful stress difference is not")
        XCTAssertNil(NativeRouter.selectCalmer(candidates: [route([1, 2, 3], stress: 100)], fastest: fast, extraMinutes: 5),
                     "A literally identical route is not an alternative")
    }
    func testNoCalmerFindingClaimsOnlyWhatWasCompared() {
        let fast = Fixture.route(id: 0, seconds: 600, stress: 500)
        func finding(_ candidates: [Route], extra: Int = 10) -> NoCalmerFinding {
            let all = [fast] + candidates
            XCTAssertNil(NativeRouter.selectCalmer(candidates: all, fastest: fast, extraMinutes: extra))
            return NativeRouter.noCalmerFinding(candidates: all, fastest: fast, extraMinutes: extra)
        }
        XCTAssertEqual(finding([], extra: 0), .notChecked, "None runs only the fastest search")
        XCTAssertEqual(finding([]), .onlyRoute)
        XCTAssertEqual(finding([Fixture.route(id: 1, seconds: 650, stress: 500), Fixture.route(id: 2, seconds: 700, stress: 600)]), .calmestCompared(routes: 3))
        XCTAssertEqual(finding([Fixture.route(id: 1, seconds: 1300, stress: 100)]), .calmerTakesLonger(limitMinutes: 10))
        XCTAssertEqual(finding([Fixture.route(id: 1, seconds: 610, stress: 490)]), .tooLittleGain, "Calmer, but under the 30 and 5% floors")
        XCTAssertEqual(finding([Fixture.route(id: 1, seconds: 1200, stress: 400)]), .tooLittleGain, "Calmer, but not worth 10 minutes")
        let small = Fixture.route(id: 1, seconds: 610, stress: 490)
        XCTAssertEqual(finding([small, Fixture.route(id: 2, seconds: 1300, stress: 100)]), .clearlyCalmerTakesLonger(limitMinutes: 10),
                       "A small gain inside the limit must not hide a clear one past it")
        XCTAssertEqual(finding([small, Fixture.route(id: 2, seconds: 1300, stress: 400)]), .tooLittleGain, "Past the limit, but not worth its time")
        XCTAssertEqual(finding([small, Fixture.route(id: 2, seconds: 1300, stress: 490)]), .tooLittleGain, "Past the limit, but under the floors")
    }
    func testBoundedSearchNeverClaimsTheSearchesItSkipped() {
        let fast = Fixture.route(id: 0, seconds: 600, stress: 500)
        func finding(_ candidates: [Route], bounded: Bool) -> NoCalmerFinding {
            NativeRouter.noCalmerFinding(candidates: [fast] + candidates, fastest: fast, extraMinutes: 10, bounded: bounded)
        }
        let same = [Fixture.route(id: 1, seconds: 650, stress: 500)], longer = [Fixture.route(id: 1, seconds: 1300, stress: 100)]
        let small = [Fixture.route(id: 1, seconds: 610, stress: 490)]
        XCTAssertEqual(finding([], bounded: true), .fewerChecked(routes: 1), "Not \"every search found this\"")
        XCTAssertEqual(finding(same, bounded: true), .fewerChecked(routes: 2))
        XCTAssertEqual(finding(small, bounded: true), .fewerChecked(routes: 2))
        XCTAssertEqual(finding(longer, bounded: true), .fewerChecked(routes: 2), "Not \"calmest within this extra time\"")
        XCTAssertEqual(finding(small + [Fixture.route(id: 2, seconds: 1300, stress: 100)], bounded: true), .clearlyCalmerTakesLonger(limitMinutes: 10),
                       "A route that was found and is clearly calmer is still reported")
        XCTAssertEqual(NativeRouter.noCalmerFinding(candidates: [fast], fastest: fast, extraMinutes: 0, bounded: true), .notChecked)
        XCTAssertEqual(finding(same, bounded: false), .calmestCompared(routes: 2))
        XCTAssertTrue(NoCalmerFinding.fewerChecked(routes: 2).detail.contains("only 2 routes"))
    }
    func testSearchLimitsKeepTheFastestPlusAtLeastOneCalmerSearch() {
        let limits = SearchLimits(concurrentSearches: 3, longMeters: [.walk: 1000])
        let all = NativeRouter.weights
        XCTAssertEqual(limits.weights(all, mode: .walk, meters: 1000), all, "At the threshold nothing is dropped")
        XCTAssertEqual(limits.weights(all, mode: .walk, meters: 1001), [1, 4])
        XCTAssertEqual(limits.weights(all, mode: .walk, meters: 2501), [2])
        XCTAssertEqual(limits.weights(all, mode: .walk, meters: 1e9).count, 1)
        XCTAssertEqual(limits.weights(all, mode: .bike, meters: 1e9), all, "A mode without a threshold is never bounded")
        XCTAssertEqual(limits.weights(all, mode: .drive, meters: 1e9), all)
        XCTAssertEqual(SearchLimits.standard.weights(all, mode: .drive, meters: 1e9), all)
        XCTAssertEqual(SearchLimits(concurrentSearches: 0, longMeters: [:]).concurrentSearches, 1)
    }
    func testParallelForRunsEveryIndexOnceWithinTheLimit() {
        for limit in [1, 3] {
            nonisolated(unsafe) var seen = [Int](repeating: 0, count: 20), running = 0, peak = 0
            let lock = NSLock()
            parallelFor(seen.count, limit: limit) { i in
                lock.lock(); running += 1; peak = max(peak, running); seen[i] += 1; lock.unlock()
                Thread.sleep(forTimeInterval: 0.002)
                lock.lock(); running -= 1; lock.unlock()
            }
            XCTAssertEqual(seen, [Int](repeating: 1, count: 20))
            XCTAssertLessThanOrEqual(peak, limit)
        }
    }
    func testNoCalmerWordingSaysEstimateAndNeverSafe() {
        for finding in [NoCalmerFinding.notChecked, .onlyRoute, .fewerChecked(routes: 3), .calmestCompared(routes: 3), .calmerTakesLonger(limitMinutes: 2), .tooLittleGain, .clearlyCalmerTakesLonger(limitMinutes: 2)] {
            let text = (finding.title + " " + finding.detail).lowercased()
            XCTAssertFalse(text.contains("safe"), text)
            if finding != .notChecked { XCTAssertTrue(text.contains("estimates"), text) }
        }
    }
}

final class StressModelTests: XCTestCase {
    private func cost(_ p: GraphEdge, _ n: GraphEdge, _ j: Junction = Junction(), mode: TravelMode = .drive) -> Breakdown {
        var b = Breakdown(); _ = StressModel.transition(previous: p, next: n, junction: j, mode: mode, into: &b); return b
    }
    func testUnsignalledLeftOntoArterialIsTheBiggestDrivingCost() {
        let b = cost(Fixture.northbound, Fixture.westArterial)
        XCTAssertEqual(b[.unsignalledLeft].amount, 1)
        XCTAssertEqual(b[.unsignalledLeft].cost, 120)
        var lanes = Fixture.westArterial; lanes.lanes = 4
        XCTAssertEqual(cost(Fixture.northbound, lanes)[.unsignalledLeft].cost, 180, "Busy arterial")
    }
    func testSignalTurnsTheSameLeftIntoAMinorCost() {
        let b = cost(Fixture.northbound, Fixture.westArterial, Junction(signalized: true))
        XCTAssertEqual(b[.unsignalledLeft].amount, 0)
        XCTAssertEqual(b[.leftAtSignal].cost, 20, "Unknown left-turn lane")
    }
    func testRightIntoArterialAndStraightAcross() {
        XCTAssertEqual(cost(Fixture.northbound, Fixture.eastArterial)[.unsignalledRight].amount, 1)
        let across = cost(Fixture.northbound, Fixture.continueNorth, Junction(crossedArterial: .arterial))
        XCTAssertEqual(across[.unsignalledCrossing].cost, 90)
        XCTAssertEqual(cost(Fixture.northbound, Fixture.continueNorth, Junction(signalized: true, crossedArterial: .arterial))[.unsignalledCrossing].amount, 0)
    }
    func testStopsAndHillStarts() {
        var approach = Fixture.northbound; approach.control = .stop; approach.approachGrade = 10
        let b = cost(approach, Fixture.continueNorth)
        XCTAssertEqual(b[.stopSign].cost, 15)
        XCTAssertEqual(b[.hillStop].cost, 30)
        approach.control = .allstop; approach.approachGrade = 2
        XCTAssertEqual(cost(approach, Fixture.continueNorth)[.allWayStop].cost, 20)
        XCTAssertEqual(cost(approach, Fixture.continueNorth)[.hillStop].amount, 0)
    }
    func testComplexJunctionAndFreewayEntry() {
        XCTAssertEqual(cost(Fixture.northbound, Fixture.continueNorth, Junction(legs: 5))[.complexJunction].cost, 40)
        var ramp = Fixture.continueNorth; ramp.highway = "motorway_link"
        XCTAssertEqual(cost(Fixture.northbound, ramp)[.freewayEntry].amount, 1)
    }
    func testWholeRouteFactors() {
        var b = Breakdown()
        StressModel.pathFactors(edges: [], stops: [0, 150, 300, 350, 2000], mode: .drive, into: &b)
        XCTAssertEqual(b[.stopAndGo].amount, 2, "Third and fourth stops within 400 m")
        func road(_ name: String, _ highway: String, _ meters: Double = 300) -> GraphEdge {
            var e = Fixture.edge(from: 0, to: 1, way: 1, highway: highway, meters: meters); e.name = name; return e
        }
        var hop = Breakdown()
        StressModel.pathFactors(edges: [road("A", "primary"), road("I-5", "motorway", 1500), road("B", "primary")], stops: [], mode: .drive, into: &hop)
        XCTAssertEqual(hop[.shortFreewayHop].amount, 1)
        var shortcut = Breakdown()
        StressModel.pathFactors(edges: [road("Main", "primary"), road("Elm", "residential"), road("Oak", "residential"), road("Main", "primary")],
                                stops: [], mode: .drive, into: &shortcut)
        XCTAssertEqual(shortcut[.cutThrough].amount, 1)
    }
    func testBikeLevelOfTrafficStress() {
        var e = Fixture.westArterial
        XCTAssertEqual(StressModel.levelOfTrafficStress(e), 3)
        e.facility = "lane"; XCTAssertEqual(StressModel.levelOfTrafficStress(e), 2)
        e.lanes = 4; XCTAssertEqual(StressModel.levelOfTrafficStress(e), 3)
        e.facility = "none"; XCTAssertEqual(StressModel.levelOfTrafficStress(e), 4)
        e.facility = "track"; XCTAssertEqual(StressModel.levelOfTrafficStress(e), 1)
    }
    func testBikeSignalsCostMoreThanStopSigns() {
        var stop = Fixture.northbound, allWay = Fixture.northbound, signal = Fixture.northbound
        stop.control = .stop; allWay.control = .allstop; signal.control = .signal
        let s = cost(stop, Fixture.continueNorth, mode: .bike), a = cost(allWay, Fixture.continueNorth, mode: .bike)
        let l = cost(signal, Fixture.continueNorth, mode: .bike)
        XCTAssertEqual(s[.stopSign].cost, 10)
        XCTAssertEqual(a[.allWayStop].cost, 10)
        XCTAssertEqual(l[.signal].cost, 14)
        XCTAssertGreaterThan(l[.signal].cost, s[.stopSign].cost)
        XCTAssertEqual(StressModel.transitionSeconds(previous: signal, next: Fixture.continueNorth, turned: false, junction: Junction(), mode: .bike), 8,
                       "the time estimate is unchanged")
    }
    func testBikeClimbingAndUnknownSurface() {
        var flat = Fixture.northbound, hill = Fixture.northbound, none = NoRecord()
        hill.climb = 10
        XCTAssertGreaterThan(StressModel.exposure(hill, mode: .bike, arrivesAtRoad: false, into: &none), StressModel.exposure(flat, mode: .bike, arrivesAtRoad: false, into: &none))
        XCTAssertGreaterThan(StressModel.seconds(hill, mode: .bike), StressModel.seconds(flat, mode: .bike))
        flat.surface = nil
        var b = Breakdown(); _ = StressModel.exposure(flat, mode: .bike, arrivesAtRoad: false, into: &b)
        XCTAssertEqual(b[.unknownSurface].amount, 100, "Unknown is recorded as unknown, not as pavement")
    }
    func testWalkingCrossingsAndSidewalks() {
        var crossing = Fixture.edge(from: 0, to: 1, way: 30, highway: "footway"); crossing.footway = "crossing"
        func crossingCost(_ control: String?, _ road: RoadClass) -> Breakdown {
            crossing.crossing = Crossing(control: control, road: road)
            var b = Breakdown(); _ = StressModel.exposure(crossing, mode: .walk, arrivesAtRoad: true, into: &b); return b
        }
        XCTAssertEqual(crossingCost("unmarked", .busy)[.unmarkedCrossing].cost, 180)
        XCTAssertEqual(crossingCost("marked", .arterial)[.markedCrossing].cost, 45)
        XCTAssertEqual(crossingCost("signal", .busy)[.signalCrossing].cost, 10)
        XCTAssertEqual(crossingCost("unmarked", .local)[.sideStreetCrossing].cost, 3)
        var b = Breakdown(); _ = StressModel.exposure(crossing, mode: .walk, arrivesAtRoad: false, into: &b)
        XCTAssertTrue(b.tallies.isEmpty, "A crossing split in two is counted once, on the half that reaches the road")
        var road = Fixture.westArterial; road.sidewalk = "no"
        var r = Breakdown(); _ = StressModel.exposure(road, mode: .walk, arrivesAtRoad: false, into: &r)
        XCTAssertEqual(r[.noSidewalk].cost, 40, accuracy: 0.001)
    }
    func testDriveTimesRunAtPostedSpeedAndChargeJunctionsOnce() {
        var arterial = Fixture.westArterial; arterial.meters = 1000; arterial.maxspeed = "25 mph"
        XCTAssertEqual(StressModel.seconds(arterial, mode: .drive), 1000 / (25 * 0.447_04), accuracy: 0.01, "posted limit, no urban factor")
        var unposted = Fixture.northbound; unposted.meters = 1000
        XCTAssertEqual(StressModel.seconds(unposted, mode: .drive), 1000 / (20 * 0.447_04), accuracy: 0.01, "residential default is 20 mph")
        var freeway = Fixture.edge(from: 0, to: 1, way: 5, highway: "motorway", meters: 1000); freeway.maxspeed = "60 mph"
        XCTAssertEqual(StressModel.seconds(freeway, mode: .drive), 1000 / (70 / 3.6), accuracy: 0.01, "never faster than the router's A* bound")
        var signal = Fixture.northbound; signal.control = .signal
        let plain = Junction(legs: 4), straight = StressModel.transitionSeconds(previous: signal, next: Fixture.continueNorth, turned: false, junction: plain, mode: .drive)
        XCTAssertEqual(straight, 15)
        XCTAssertEqual(StressModel.transitionSeconds(previous: signal, next: Fixture.westArterial, turned: true, junction: plain, mode: .drive), 20)
        for (control, seconds) in [(TrafficControl.stop, 8.0), (.allstop, 10), (.yield, 3)] {
            var controlled = Fixture.northbound; controlled.control = control
            XCTAssertEqual(StressModel.transitionSeconds(previous: controlled, next: Fixture.continueNorth, turned: false, junction: plain, mode: .drive), seconds,
                           "\(control)")
        }
        XCTAssertEqual(StressModel.transitionSeconds(previous: Fixture.northbound, next: Fixture.continueNorth, turned: false, junction: plain, mode: .drive), 3,
                       "an unsigned cross street on a local street costs a look")
        XCTAssertEqual(StressModel.transitionSeconds(previous: Fixture.northbound, next: Fixture.continueNorth, turned: false, junction: Junction(legs: 3), mode: .drive), 0)
        XCTAssertEqual(StressModel.transitionSeconds(previous: Fixture.westArterial, next: Fixture.eastArterial, turned: false, junction: plain, mode: .drive), 0,
                       "arterials have the right of way")
    }
    func testTimesArePositiveAndHillsSlowWalking() {
        var hill = Fixture.northbound; hill.climb = 10
        for mode in TravelMode.allCases { XCTAssertGreaterThan(StressModel.seconds(Fixture.northbound, mode: mode), 0) }
        XCTAssertEqual(StressModel.seconds(hill, mode: .walk) - StressModel.seconds(Fixture.northbound, mode: .walk), 25, accuracy: 0.001)
    }
    func testReasonsSayBenefitsAndTradeoffsWithDisplayedMinutes() {
        var f = RouteMetrics(), c = RouteMetrics()
        f.seconds = 10.9 * 60; c.seconds = 12.1 * 60; f.meters = 3000; c.meters = 3200
        f.breakdown.add(.unsignalledLeft, amount: 2, cost: 240); f.breakdown.add(.turn, amount: 3, cost: 24)
        c.breakdown.add(.turn, amount: 4, cost: 32); c.breakdown.add(.residential, amount: 600, cost: 18)
        let place = Place(id: "a", name: "A", lat: 47.64, lon: -122.35, category: "test")
        let comparison = RouteComparison(request: .init(origin: place, destination: place, mode: .drive, extraMinutes: 5),
            fastest: Route(edgeIDs: [1], coordinates: [], metrics: f, streetNames: []), calmer: Route(edgeIDs: [2], coordinates: [], metrics: c, streetNames: []),
            candidateCount: 2, originSnapMeters: 0, destinationSnapMeters: 0, snappedOrigin: place.coordinate, snappedDestination: place.coordinate)
        XCTAssertEqual(comparison.reasons, ["2 fewer left turns across traffic without a signal", "Tradeoff: 0.4 mi more on residential streets", "Tradeoff: 1 more turn"])
        XCTAssertEqual(comparison.extraTimeLabel, "+2 min", "11 min and 13 min cards must read +2, not +1")
    }
}

final class RouterTests: XCTestCase {
    func testJunctionSeesTheArterialBeingCrossed() {
        let router = NativeRouter(graph: Fixture.graph())
        let j = router.junction(at: 1, previous: Fixture.northbound, next: Fixture.continueNorth)
        XCTAssertEqual(j.crossedArterial, .arterial)
        XCTAssertEqual(j.legs, 4)
    }
    func testNoTurnRestrictionAppliesOnlyToItsMode() {
        let r = TurnRestriction(via: 1, fromWay: 10, toWay: 20, kind: "no_left_turn", mode: .drive, osmID: 99)
        let router = NativeRouter(graph: Fixture.graph(restrictions: [r]))
        XCTAssertFalse(router.allowed(previous: Fixture.northbound, next: Fixture.westArterial, mode: .drive))
        XCTAssertTrue(router.allowed(previous: Fixture.northbound, next: Fixture.westArterial, mode: .bike))
    }
    func testOnlyTurnRestrictionBlocksOtherWays() {
        let r = TurnRestriction(via: 1, fromWay: 10, toWay: 21, kind: "only_right_turn", mode: .drive, osmID: 99)
        XCTAssertFalse(NativeRouter(graph: Fixture.graph(restrictions: [r])).allowed(previous: Fixture.northbound, next: Fixture.westArterial, mode: .drive))
    }
    func testNoImmediateUTurn() {
        let back = Fixture.edge(id: 4, from: 1, to: 0, way: 10)
        XCTAssertFalse(NativeRouter(graph: Fixture.graph()).allowed(previous: Fixture.northbound, next: back, mode: .drive))
    }
    func testMissingGraphIsRejected() {
        XCTAssertThrowsError(try StreetGraph(bounds: [], nodes: [], edges: [], restrictions: [], places: []).validate())
    }
    func testOutsideCoverageSamePlaceAndBudgetAreExplicitErrors() {
        let router = NativeRouter(graph: Fixture.graph())
        let a = Place(id: "a", name: "A", lat: 47.64, lon: -122.36, category: "test")
        let outside = Place(id: "b", name: "B", lat: 48, lon: -122.35, category: "test")
        XCTAssertThrowsError(try router.compute(.init(origin: a, destination: outside, mode: .drive, extraMinutes: 5))) { XCTAssertEqual($0 as? RoutingError, .outsideCoverage) }
        XCTAssertThrowsError(try router.compute(.init(origin: a, destination: a, mode: .drive, extraMinutes: 5))) { XCTAssertEqual($0 as? RoutingError, .samePlace) }
        XCTAssertThrowsError(try router.compute(.init(origin: a, destination: a, mode: .drive, extraMinutes: -1))) { XCTAssertEqual($0 as? RoutingError, .invalidBudget) }
    }
}

/// Against the real bundled Seattle data.
final class SeattleTests: XCTestCase {
    private static let graph = try! StreetGraph.bundled()
    private static let router = NativeRouter(graph: graph)
    private func place(_ id: String) throws -> Place { try XCTUnwrap(Self.graph.places.first { $0.id == id }) }

    func testRoutesAreContinuousLegalAndWithinBudgetInEveryMode() throws {
        let (g, router) = (Self.graph, Self.router)
        for mode in TravelMode.allCases {
            let result = try router.compute(.init(origin: try place("way/37056567"), destination: try place("relation/1047789"), mode: mode, extraMinutes: 5))
            for route in [result.fastest, result.calmer].compactMap({ $0 }) {
                XCTAssertGreaterThan(route.metrics.meters, 1000)
                XCTAssertLessThanOrEqual(route.metrics.seconds, result.fastest.metrics.seconds + 300.000001)
                for (first, second) in zip(route.edgeIDs, route.edgeIDs.dropFirst()) {
                    XCTAssertEqual(g.edges[first].to, g.edges[second].from)
                    XCTAssertTrue(router.allowed(previous: g.edges[first], next: g.edges[second], mode: mode))
                }
                XCTAssertTrue(route.edgeIDs.allSatisfy { g.edges[$0].modes.contains(mode) })
            }
            if let calmer = result.calmer { XCTAssertLessThan(calmer.metrics.stress, result.fastest.metrics.stress) }
        }
    }
    func testWalkersUseMappedSidewalksNotTheRoadBesideThem() {
        // Only roads explicitly tagged open to pedestrians remain walkable beside their mapped sidewalks.
        let walkableRoads = Self.graph.edges.filter { $0.modes.contains(.walk) && $0.isRoad }
        XCTAssertLessThan(Double(walkableRoads.filter { $0.sidewalk == "separate" }.count), Double(walkableRoads.count) * 0.02)
        XCTAssertTrue(Self.graph.edges.contains { $0.footway == "sidewalk" && $0.besideRoad == .busy })
    }
    func testBridgesAreNotAtWaterLevel() {
        let aurora = Self.graph.edges.filter { $0.name == "Aurora Avenue North" && $0.meters > 500 }
        XCTAssertFalse(aurora.isEmpty)
        XCTAssertTrue(aurora.allSatisfy { Self.graph.nodes[$0.from].z > 30 && Self.graph.nodes[$0.to].z > 30 })
    }
    func testPlaceSearchIsBoundedAndCaseInsensitive() {
        XCTAssertEqual(Self.graph.search("gAs WoRkS").first?.name, "Gas Works Park")
        XCTAssertTrue(Self.graph.search("unfindableXYZ").isEmpty)
        XCTAssertTrue(Self.graph.places.allSatisfy { Self.graph.contains($0.coordinate) })
    }
    func testSearchRanksPrefixThenWordThenContainsThenCategory() {
        let park = Self.graph.search("park")
        XCTAssertTrue(park.first?.shortName.lowercased().hasPrefix("park") == true)
        let gas = park.firstIndex { $0.name == "Gas Works Park" }
        XCTAssertNotNil(gas)
        XCTAssertGreaterThan(gas ?? 0, 0)
        XCTAssertEqual(Self.graph.search("gas").first?.name, "Gas Works Park")
        XCTAssertEqual(Self.graph.search("cafe").first?.category, "cafe", "category matches come after name matches")
        let words = park.prefix(while: { $0.shortName.lowercased().hasPrefix("park") }).map(\.shortName)
        XCTAssertEqual(words, words.sorted { $0.lowercased() < $1.lowercased() }, "ties are alphabetical")
        XCTAssertEqual(Self.graph.search("CAFÉ").count, Self.graph.search("cafe").count)
    }
    func testMuseumSnapsToConnectedNetworkInEveryMode() throws {
        for mode in TravelMode.allCases {
            let c = try Self.router.compute(.init(origin: try place("way/37058377"), destination: try place("way/160545994"), mode: mode, extraMinutes: 2))
            XCTAssertLessThan(c.destinationSnapMeters, 100)
            XCTAssertGreaterThan(c.fastest.metrics.meters, 3000)
        }
    }
    func testTenMinuteLimitDoesNotPayForScrapsOnALongDrive() throws {
        let a = try place("way/37056567"), b = try place("node/12786894083")
        let five = try Self.router.compute(.init(origin: a, destination: b, mode: .drive, extraMinutes: 5))
        let ten = try Self.router.compute(.init(origin: a, destination: b, mode: .drive, extraMinutes: 10))
        XCTAssertNotNil(ten.calmer)
        XCTAssertEqual(ten.calmer?.edgeIDs, five.calmer?.edgeIDs, "A candidate 3.5 minutes slower for 20 less stress must not win")
    }
    func testFremontToCapitolHillDriveOffersACalmerRouteAtTheDefaultLimit() throws {
        let c = try Self.router.compute(.init(origin: try place("way/37058377"), destination: try place("way/37057155"), mode: .drive, extraMinutes: 10))
        let calmer = try XCTUnwrap(c.calmer)
        XCTAssertLessThan(calmer.metrics.stress, c.fastest.metrics.stress * 0.7)
        XCTAssertLessThanOrEqual(c.extraSeconds, 600)
    }
    func testDIYTeaLabToLassiAndSpiceDriveChoosesTheNearlyIdenticalCalmerRoute() throws {
        let c = try Self.router.compute(.init(origin: try place("node/6238815765"), destination: try place("node/6309416486"), mode: .drive, extraMinutes: 10))
        let calmer = try XCTUnwrap(c.calmer, "Most of its length is shared with the fastest route, and it is still the calmer choice")
        XCTAssertLessThan(calmer.metrics.stress, c.fastest.metrics.stress * 0.7)
        XCTAssertLessThan(c.extraSeconds, 60)
        let shared = Set(c.fastest.edgeIDs)
        let sharedMeters = zip(calmer.edgeIDs, calmer.edgeMeters).filter { shared.contains($0.0) }.reduce(0) { $0 + $1.1 }
        XCTAssertGreaterThan(sharedMeters / calmer.metrics.meters, 0.9)
    }
    func testNoExtraTimeSaysNothingElseWasChecked() throws {
        let c = try Self.router.compute(.init(origin: try place("way/37056567"), destination: try place("relation/1047789"), mode: .drive, extraMinutes: 0))
        XCTAssertNil(c.calmer)
        XCTAssertEqual(c.noCalmer, .notChecked)
        XCTAssertEqual(c.reasons, [NoCalmerFinding.notChecked.detail])
    }
    func testComputeReportsWhatItFound() throws {
        let kerry = try place("node/693337509"), gasWorks = try place("relation/1047789")
        let bike = try Self.router.compute(.init(origin: kerry, destination: gasWorks, mode: .bike, extraMinutes: 5))
        XCTAssertNil(bike.calmer)
        XCTAssertEqual(bike.noCalmer, .clearlyCalmerTakesLonger(limitMinutes: 5))
        let longer = try Self.router.compute(.init(origin: kerry, destination: gasWorks, mode: .bike, extraMinutes: 10))
        XCTAssertNotNil(longer.calmer, "The route the 5 minute message points at")
        let drive = try Self.router.compute(.init(origin: kerry, destination: gasWorks, mode: .drive, extraMinutes: 10))
        XCTAssertNil(drive.calmer)
        XCTAssertEqual(drive.noCalmer, .tooLittleGain)
    }
    func testCancelledSearchStopsBeforeReturning() async throws {
        let request = RouteRequest(origin: try place("node/693337509"), destination: try place("relation/1047789"), mode: .walk, extraMinutes: 10)
        let router = Self.router
        let task = Task { try await router.compare(request) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled routing returned a route") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

final class GzipTests: XCTestCase {
    /// Python's gzip with a file name in the header (FNAME flag), so the header walk is exercised.
    private static let sample = Data(hexString: "1f8b08080000000000ff63616c6d2e747874004b4eccc94d2d52282e294a4d2d29e64ac6cb05009f3bb6342d000000")
    func testInflatesGzipWithFileName() {
        XCTAssertEqual(Self.sample.gunzipped(), Data(String(repeating: "calmer streets\n", count: 3).utf8))
    }
    func testRejectsTruncatedOrPlainData() {
        XCTAssertNil(Self.sample.dropLast(12).gunzipped())
        XCTAssertNil(Data("{\"schemaVersion\":2}".utf8).gunzipped())
    }
}

private extension Data {
    init(hexString: String) {
        var bytes = [UInt8](), chars = Array(hexString)
        for i in stride(from: 0, to: chars.count, by: 2) { bytes.append(UInt8(String(chars[i...i + 1]), radix: 16)!) }
        self.init(bytes)
    }
}
