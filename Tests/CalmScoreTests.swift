import XCTest
@testable import PeoplemapsCore

final class CalmScoreTests: XCTestCase {
    private func route(id: Int, seconds: Double, meters: Double = 8000, _ factors: [(Factor, Double, Double)]) -> Route {
        var metrics = RouteMetrics(); metrics.seconds = seconds; metrics.meters = meters
        for (factor, amount, cost) in factors { metrics.breakdown.add(factor, amount: amount, cost: cost) }
        return Route(edgeIDs: [id], edgeMeters: [meters], coordinates: [], metrics: metrics, streetNames: [])
    }
    private func comparison(_ fastest: Route, _ calmer: Route?, mode: TravelMode = .drive, noCalmer: NoCalmerFinding = .notChecked) -> RouteComparison {
        let a = Place(id: "a", name: "A", lat: 47.6, lon: -122.3, category: "park"), b = Place(id: "b", name: "B", lat: 47.7, lon: -122.3, category: "park")
        return RouteComparison(request: .init(origin: a, destination: b, mode: mode, extraMinutes: 10), fastest: fastest, calmer: calmer, candidateCount: 2,
                               originSnapMeters: 0, destinationSnapMeters: 0, snappedOrigin: a.coordinate, snappedDestination: b.coordinate, noCalmer: noCalmer)
    }

    func testLevelsCoverEveryScoreAtTheirCutoffs() {
        XCTAssertEqual(CalmLevel.allCases.map(\.title), ["Breezy", "Chill", "Meh", "Spicy", "Yikes"])
        for (score, level) in [(100, CalmLevel.breezy), (80, .breezy), (79, .chill), (60, .chill), (59, .meh), (40, .meh), (39, .spicy), (20, .spicy), (19, .yikes), (0, .yikes)] {
            XCTAssertEqual(CalmLevel(score: score), level, "\(score)")
        }
    }

    func testScoreFallsAsStressPerMinuteRises() {
        let minutes10 = 600.0
        XCTAssertEqual(CalmScore(stress: 0, tripSeconds: minutes10, mode: .drive).value, 100)
        XCTAssertEqual(CalmScore(stress: 500, tripSeconds: minutes10, mode: .drive).value, 50)
        XCTAssertEqual(CalmScore(stress: 1000, tripSeconds: minutes10, mode: .drive).value, 20)
        XCTAssertGreaterThan(CalmScore(stress: 300, tripSeconds: minutes10, mode: .drive).value, CalmScore(stress: 301, tripSeconds: minutes10, mode: .drive).value)
        XCTAssertEqual(CalmScore(stress: 1_000_000, tripSeconds: minutes10, mode: .drive).value, 0)
    }

    func testAScoreIsNotMarkedDownForALongTrip() {
        XCTAssertEqual(CalmScore(stress: 500, tripSeconds: 600, mode: .drive), CalmScore(stress: 1500, tripSeconds: 1800, mode: .drive))
    }

    func testVeryShortTripsCountAsFiveMinutes() {
        XCTAssertEqual(CalmScore(stress: 120, tripSeconds: 60, mode: .drive), CalmScore(stress: 120, tripSeconds: 300, mode: .drive))
    }

    func testEachModeHasItsOwnScale() {
        XCTAssertEqual(CalmScore(stress: 500, tripSeconds: 600, mode: .drive).value, 50)
        XCTAssertEqual(CalmScore(stress: 650, tripSeconds: 600, mode: .bike).value, 50)
        XCTAssertEqual(CalmScore(stress: 120, tripSeconds: 600, mode: .walk).value, 50)
    }

    func testFreewayMinutesCountHalfInTheDenominator() {
        XCTAssertEqual(CalmScore(stress: 500, tripSeconds: 1200, freewaySeconds: 600, mode: .drive), CalmScore(stress: 500, tripSeconds: 900, mode: .drive))
        XCTAssertEqual(CalmScore(stress: 500, tripSeconds: 1200, freewaySeconds: 0, mode: .drive), CalmScore(stress: 500, tripSeconds: 1200, mode: .drive))
        XCTAssertLessThan(CalmScore(stress: 500, tripSeconds: 1200, freewaySeconds: 600, mode: .drive).value, CalmScore(stress: 500, tripSeconds: 1200, mode: .drive).value)
        XCTAssertEqual(CalmScore(stress: 120, tripSeconds: 400, freewaySeconds: 9000, mode: .drive), CalmScore(stress: 120, tripSeconds: 200, mode: .drive), "never more than the trip")
    }

    func testOnlyMotorwayMinutesCountHalfNotTrunkRoads() {
        func fastest(_ highway: String) -> Route {
            var edge = Fixture.edge(from: 0, to: 1, way: 1, highway: highway, meters: 600 * 40 * 0.447_04); edge.maxspeed = "40 mph"
            var metrics = RouteMetrics(); metrics.seconds = 1200; metrics.breakdown.add(.turn, amount: 10, cost: 500)
            return Route(edgeIDs: [0], edgeMeters: [edge.meters], coordinates: [], metrics: metrics, streetNames: [], edges: [edge])
        }
        let plain = route(id: 9, seconds: 1200, [(.turn, 10, 500)]), none = CalmScore(stress: 500, tripSeconds: 1200, mode: .drive)
        XCTAssertEqual(comparison(fastest("trunk"), plain).fastestCalm, none, "Aurora counts in full")
        XCTAssertEqual(comparison(fastest("trunk_link"), plain).fastestCalm, none)
        XCTAssertEqual(comparison(fastest("motorway"), plain).fastestCalm, CalmScore(stress: 500, tripSeconds: 1200, freewaySeconds: 600, mode: .drive))
        XCTAssertEqual(comparison(fastest("motorway_link"), plain).fastestCalm, CalmScore(stress: 500, tripSeconds: 1200, freewaySeconds: 600, mode: .drive))
        XCTAssertLessThan(comparison(fastest("motorway"), plain).fastestCalm.value, none.value)
    }

    func testTheComparisonTakesFreewayTimeFromTheFastestRouteForBothRoutes() {
        var freeway = Fixture.edge(from: 0, to: 1, way: 1, highway: "motorway", meters: 600 * 60 * 0.447_04); freeway.maxspeed = "60 mph"
        var metrics = RouteMetrics(); metrics.seconds = 1200; metrics.breakdown.add(.turn, amount: 10, cost: 500)
        let fastest = Route(edgeIDs: [0], edgeMeters: [freeway.meters], coordinates: [], metrics: metrics, streetNames: [], edges: [freeway])
        let calmer = route(id: 1, seconds: 1300, [(.turn, 10, 300)])
        let c = comparison(fastest, calmer)
        XCTAssertEqual(c.fastestCalm, CalmScore(stress: 500, tripSeconds: 1200, freewaySeconds: 600, mode: .drive))
        XCTAssertEqual(c.calmerCalm, CalmScore(stress: 300, tripSeconds: 1200, freewaySeconds: 600, mode: .drive))
        let walk = comparison(fastest, calmer, mode: .walk)
        XCTAssertEqual(walk.fastestCalm, CalmScore(stress: 500, tripSeconds: 1200, mode: .walk), "freeway time is a drive idea")
    }

    func testTollRoadsAreMentionedNotPriced() {
        var toll = Fixture.edge(from: 0, to: 1, way: 1, highway: "motorway", meters: 1000); toll.toll = true; toll.name = "Evergreen Point Floating Bridge"
        var metrics = RouteMetrics(); metrics.seconds = 600
        let tolled = Route(edgeIDs: [0], edgeMeters: [1000], coordinates: [], metrics: metrics, streetNames: [], edges: [toll, toll])
        let plain = route(id: 1, seconds: 700, [])
        let c = comparison(tolled, plain)
        XCTAssertEqual(c.tollNotes, ["Fastest route: uses a toll road (Evergreen Point Floating Bridge). Tolls aren't in the estimate."])
        XCTAssertTrue(comparison(tolled, plain, mode: .walk).tollNotes.isEmpty, "tolls are a drive idea")
        toll.name = ""
        let unnamed = Route(edgeIDs: [0], edgeMeters: [1000], coordinates: [], metrics: metrics, streetNames: [], edges: [toll])
        XCTAssertEqual(comparison(unnamed, nil).tollNotes, ["Fastest route: uses a toll road. Tolls aren't in the estimate."])
        XCTAssertTrue(comparison(plain, nil).tollNotes.isEmpty)
    }

    func testSidewalkCaveatIsOneShareOfTheRoute() {
        let c = comparison(route(id: 0, seconds: 600, meters: 1000, [(.unknownSidewalk, 810, 16)]), nil, mode: .walk)
        XCTAssertEqual(c.caveats, ["Fastest route: sidewalk data is missing for about 80% of it."])
        XCTAssertTrue(comparison(route(id: 0, seconds: 600, meters: 1000, [(.unknownSidewalk, 90, 2)]), nil, mode: .walk).caveats.isEmpty)
    }

    func testASlowerRouteDoesNotScoreBetterForTakingLonger() {
        let fast = route(id: 0, seconds: 600, [(.turn, 10, 500)])
        let sameStress = route(id: 1, seconds: 1200, [(.turn, 10, 500)])
        let c = comparison(fast, sameStress)
        XCTAssertEqual(c.calmerCalm, c.fastestCalm)
    }

    func testChangeReadsFastestToCalmer() {
        let c = comparison(route(id: 0, seconds: 600, [(.unsignalledLeft, 6, 1100)]), route(id: 1, seconds: 720, [(.unsignalledLeft, 1, 300)]))
        XCTAssertEqual(c.fastestCalm.level, .yikes)
        XCTAssertEqual(c.calmerCalm?.level, .chill)
        XCTAssertEqual(c.calmChange, "Yikes → Chill")
        XCTAssertEqual(c.spokenCalmChange, "Yikes to Chill")
    }

    func testSharedLevelShowsTheScores() {
        let c = comparison(route(id: 0, seconds: 600, [(.turn, 30, 340)]), route(id: 1, seconds: 620, [(.turn, 20, 260)]))
        XCTAssertEqual(c.fastestCalm.level, .chill)
        XCTAssertEqual(c.calmerCalm?.level, .chill)
        XCTAssertEqual(c.calmChange, "Chill, \(c.fastestCalm.value) → \(c.calmerCalm!.value)")
        XCTAssertLessThan(c.fastestCalm.value, c.calmerCalm!.value)
    }

    func testMainGainSaysMostlyOnlyWithAMajority() {
        let mostly = comparison(route(id: 0, seconds: 600, [(.unsignalledLeft, 4, 480), (.turn, 12, 96)]), route(id: 1, seconds: 700, [(.turn, 10, 80)]))
        XCTAssertEqual(mostly.mainGain, "mostly fewer unsignalled lefts")
        let split = comparison(route(id: 0, seconds: 600, [(.stopSign, 8, 120), (.signal, 10, 100), (.turn, 10, 80)]), route(id: 1, seconds: 700, [(.turn, 0, 0)]))
        XCTAssertEqual(split.mainGain, "fewer stop signs and fewer signals")
    }

    func testMainGainIgnoresWhatTheCalmerRouteCostsAndUnnoticeableChanges() {
        let c = comparison(route(id: 0, seconds: 600, [(.stopSign, 4, 60), (.turn, 2, 16)]), route(id: 1, seconds: 700, [(.turn, 8, 64)]))
        XCTAssertEqual(c.mainGain, "mostly fewer stop signs")
        let small = comparison(route(id: 0, seconds: 600, [(.residential, 50, 90)]), route(id: 1, seconds: 610, [(.residential, 20, 40)]))
        XCTAssertEqual(small.mainGain, "fewer small hassles")
    }

    func testSummaryCarriesTheChangeAndTheGain() {
        let c = comparison(route(id: 0, seconds: 600, [(.unsignalledLeft, 6, 1100)]), route(id: 1, seconds: 720, [(.unsignalledLeft, 1, 300)]))
        XCTAssertEqual(c.calmSummary, "Yikes → Chill, mostly fewer unsignalled lefts")
        XCTAssertEqual(c.spokenCalmSummary, "Yikes to Chill, mostly fewer unsignalled lefts")
    }

    func testReasonLineSaysWhatTheCalmerRouteCostsAndItsBiggestGain() {
        let c = comparison(route(id: 0, seconds: 600, [(.unsignalledLeft, 6, 1100)]), route(id: 1, seconds: 720, [(.unsignalledLeft, 1, 300)]))
        XCTAssertEqual(c.reasonLine, "\(c.calmer!.minutes - c.fastest.minutes) min more than fastest, 5 fewer unsignalled lefts")
        let small = comparison(route(id: 0, seconds: 600, [(.residential, 50, 90)]), route(id: 1, seconds: 610, [(.residential, 20, 40)]))
        XCTAssertEqual(small.reasonLine, "Under a minute more than fastest, fewer small hassles")
        let same = comparison(route(id: 0, seconds: 600, [(.turn, 30, 500)]), route(id: 1, seconds: 600, [(.turn, 10, 100)]))
        XCTAssertEqual(same.reasonLine, "No extra time, 20 fewer turns")
        let one = comparison(route(id: 0, seconds: 600, [(.stopSign, 2, 600)]), route(id: 1, seconds: 600, [(.stopSign, 1, 100)]))
        XCTAssertEqual(one.reasonLine, "No extra time, fewer stop signs")
        XCTAssertEqual(comparison(route(id: 0, seconds: 600, [(.turn, 30, 500)]), nil, noCalmer: .tooLittleGain).reasonLine, NoCalmerFinding.tooLittleGain.title)
        XCTAssertFalse(c.reasonLine.localizedCaseInsensitiveContains("safe"))
    }

    func testWithNoCalmerRouteTheSummarySaysWhatTheRouterFound() {
        let only = route(id: 0, seconds: 600, [(.turn, 30, 500)])
        XCTAssertEqual(comparison(only, nil, noCalmer: .onlyRoute).calmSummary, "Meh, already the calmest we found")
        XCTAssertEqual(comparison(only, nil, noCalmer: .tooLittleGain).calmSummary, "Meh, best balance we found")
        XCTAssertEqual(comparison(only, nil, noCalmer: .notChecked).calmSummary, "Meh, fastest route only")
        XCTAssertNil(comparison(only, nil).calmerCalm)
    }

    func testHeadlineShowsTheRouteStartDefaultsTo() {
        let fast = route(id: 0, seconds: 600, meters: 8000, [(.turn, 30, 500)]), calm = route(id: 1, seconds: 1020, meters: 9978, [(.turn, 10, 100)])
        let c = comparison(fast, calm)
        XCTAssertEqual(c.startHeadline, "Calmer: \(calm.timeRange), \(calm.distance)")
        XCTAssertEqual(calm.timeRange, "16–19 min", "Never the fastest route's time")
        XCTAssertEqual(comparison(fast, nil, noCalmer: .onlyRoute).startHeadline, "\(fast.timeRange), \(fast.distance)")
    }

    func testTimeRangeNeverHidesTheEstimate() {
        func minutes(_ seconds: Double) -> Route { route(id: 0, seconds: seconds, []) }
        XCTAssertEqual(minutes(60).timeRange, "1 min")
        XCTAssertEqual(minutes(60).spokenTimeRange, "1 minute")
        XCTAssertEqual(minutes(130).timeRange, "2–3 min", "Includes the rounded-up time shown elsewhere")
        XCTAssertEqual(minutes(600).timeRange, "10–11 min")
        XCTAssertEqual(minutes(600).spokenTimeRange, "10 to 11 minutes")
        for seconds in stride(from: 30.0, to: 4000, by: 37) {
            let r = minutes(seconds), parts = r.timeRange.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            XCTAssertLessThanOrEqual(parts[0], r.minutes, "\(seconds)")
            XCTAssertGreaterThanOrEqual(parts.last!, r.minutes, "\(seconds)")
        }
    }

    func testNoWordImpliesSafety() {
        let words = CalmLevel.allCases.map(\.title) + Factor.allCases.map(\.gain)
        for word in words { XCTAssertFalse(word.localizedCaseInsensitiveContains("safe"), word) }
    }
}
