import XCTest
@testable import PeoplemapsCore

final class PreferenceTests: XCTestCase {
    func testDefaultsChangeNothing() {
        for mode in TravelMode.allCases {
            let p = RoutePreferences.default(for: mode)
            XCTAssertTrue(p.isDefault(in: mode))
            XCTAssertNil(FactorScale(p, mode: mode))
            XCTAssertTrue(RoutePreferences.Option.allCases.allSatisfy { p[$0] == .normal })
        }
        let place = Place(id: "a", name: "A", lat: 47.64, lon: -122.35, category: "test")
        XCTAssertEqual(RouteRequest(origin: place, destination: place, mode: .bike, extraMinutes: 5).preferences, .default(for: .bike))
    }

    func testOptionsOnlyAppearWhereTheModeHasTheirFactors() {
        XCTAssertEqual(RoutePreferences.Option.available(in: .walk), [.trafficLights, .busyStreets, .busyCrossings, .hills])
        XCTAssertEqual(RoutePreferences.Option.available(in: .bike), RoutePreferences.Option.allCases)
        XCTAssertEqual(RoutePreferences.Option.available(in: .drive), [.trafficLights, .stopSigns, .unprotectedLefts, .busyCrossings, .hills, .turns])
        for mode in TravelMode.allCases {
            for option in RoutePreferences.Option.allCases {
                for factor in option.factors(in: mode) { XCTAssertEqual(factor.preferenceOption, option, "\(factor) in \(mode)") }
            }
        }
        for factor in Factor.allCases {
            guard let option = factor.preferenceOption else { continue }
            XCTAssertTrue(TravelMode.allCases.contains { option.factors(in: $0).contains(factor) }, "\(factor) is scaled but never offered")
        }
        XCTAssertNil(FactorScale(.init([.stopSigns: .avoid, .turns: .dontMind]), mode: .walk), "Walking has no stop signs or turn costs")
    }

    func testCodableIsStableAndTolerant() throws {
        var p = RoutePreferences()
        p[.trafficLights] = .avoid; p[.hills] = .dontMind; p[.turns] = .avoid; p[.turns] = .normal
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(p), as: UTF8.self)
        XCTAssertEqual(json, #"{"hills":"dontMind","trafficLights":"avoid"}"#)
        XCTAssertEqual(try JSONDecoder().decode(RoutePreferences.self, from: Data(json.utf8)), p)
        XCTAssertEqual(String(decoding: try encoder.encode(RoutePreferences.default(for: .drive)), as: UTF8.self), "{}")
        let future = #"{"stopSigns":"avoid","ferries":"avoid","hills":"loveThem","turns":"normal"}"#
        XCTAssertEqual(try JSONDecoder().decode(RoutePreferences.self, from: Data(future.utf8)), RoutePreferences([.stopSigns: .avoid]),
                       "Unknown options and levels from a newer version are skipped")
        XCTAssertEqual(RoutePreferences([.turns: .normal]), RoutePreferences(), "Normal is not stored")
    }

    func testScaleAppliesToJunctionAndExposureCosts() {
        var approach = Fixture.northbound; approach.control = .stop
        let scale = FactorScale(.init([.stopSigns: .avoid, .turns: .dontMind]), mode: .bike)!
        var scaled = ScaledRecord(scale: scale), plain = Breakdown()
        _ = StressModel.transition(previous: approach, next: Fixture.eastArterial, junction: Junction(), mode: .bike, into: &scaled)
        _ = StressModel.transition(previous: approach, next: Fixture.eastArterial, junction: Junction(), mode: .bike, into: &plain)
        XCTAssertEqual(plain[.stopSign].cost, 10)
        XCTAssertEqual(plain[.turn].cost, 4)
        XCTAssertEqual(scaled.total, plain.stress + 2 * 10 - 0.7 * 4, accuracy: 1e-9)
        XCTAssertEqual(scale.stress(plain), scaled.total, accuracy: 1e-9)
    }

    func testReasonsRankByPreferenceButReportRealCounts() {
        var f = RouteMetrics(), c = RouteMetrics()
        f.seconds = 600; c.seconds = 660; f.meters = 3000; c.meters = 3100
        f.breakdown.add(.unsignalledLeft, amount: 1, cost: 120); f.breakdown.add(.signal, amount: 8, cost: 80)
        c.breakdown.add(.signal, amount: 2, cost: 20)
        let place = Place(id: "a", name: "A", lat: 47.64, lon: -122.35, category: "test")
        func reasons(_ p: RoutePreferences) -> [String] {
            RouteComparison(request: .init(origin: place, destination: place, mode: .drive, extraMinutes: 5, preferences: p),
                            fastest: Route(edgeIDs: [1], coordinates: [], metrics: f, streetNames: []),
                            calmer: Route(edgeIDs: [2], coordinates: [], metrics: c, streetNames: []), candidateCount: 2,
                            originSnapMeters: 0, destinationSnapMeters: 0, snappedOrigin: place.coordinate, snappedDestination: place.coordinate).reasons
        }
        XCTAssertEqual(reasons(.default(for: .drive)), ["1 fewer left turn across traffic without a signal", "6 fewer traffic signals"])
        XCTAssertEqual(reasons(.init([.trafficLights: .avoid])), ["6 fewer traffic signals", "1 fewer left turn across traffic without a signal"])
    }

    func testSelectionWeighsCandidatesAsThePersonDoes() {
        func route(_ id: Int, seconds: Double, signals: Double, turns: Double) -> Route {
            var m = RouteMetrics(); m.seconds = seconds; m.meters = 1000
            m.breakdown.add(.signal, amount: signals / 10, cost: signals); m.breakdown.add(.turn, amount: turns / 8, cost: turns)
            return Route(edgeIDs: [id], edgeMeters: [1000], coordinates: [], metrics: m, streetNames: [])
        }
        let fast = route(0, seconds: 100, signals: 200, turns: 200)
        let fewerTurns = route(1, seconds: 150, signals: 200, turns: 40), fewerSignals = route(2, seconds: 150, signals: 80, turns: 200)
        XCTAssertEqual(NativeRouter.selectCalmer(candidates: [fewerTurns, fewerSignals], fastest: fast, extraMinutes: 5)?.edgeIDs, [1])
        let scale = FactorScale(.init([.trafficLights: .avoid]), mode: .drive)!
        XCTAssertEqual(NativeRouter.selectCalmer(candidates: [fewerTurns, fewerSignals], fastest: fast, extraMinutes: 5,
                                                 stress: { scale.stress($0.metrics.breakdown) })?.edgeIDs, [2])
    }
}

/// Against the real bundled Seattle data.
final class SeattlePreferenceTests: XCTestCase {
    private static let graph = try! StreetGraph.bundled()
    private static let router = NativeRouter(graph: graph)
    private func place(_ id: String) throws -> Place { try XCTUnwrap(Self.graph.places.first { $0.id == id }) }
    private func compare(_ a: String, _ b: String, _ mode: TravelMode, _ budget: Int = 5, _ p: RoutePreferences? = nil) throws -> RouteComparison {
        try Self.router.compute(.init(origin: try place(a), destination: try place(b), mode: mode, extraMinutes: budget, preferences: p))
    }

    /// Default preferences must give exactly the routes recorded in Evidence/route-audit.json before preferences existed.
    func testDefaultsReproduceTheRouteAudit() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Evidence/route-audit.json")
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        // Fixed rounding and name order: dictionary order and JSON parsing of the last digits differ between platforms.
        func row(_ name: String, _ amount: Double, _ cost: Double) -> String { "\(name) \(String(format: "%.1f", amount)) \(String(format: "%.0f", cost))" }
        func factors(_ v: Any?) -> [String] { ((v as? [[Any]]) ?? []).map { row("\($0[0])", number($0[1])!, number($0[2])!) }.sorted() }
        func factors(_ r: Route?) -> [String] {
            (r?.metrics.breakdown.tallies ?? [:]).map { row($0.key.rawValue, ($0.value.amount * 10).rounded() / 10, $0.value.cost.rounded()) }.sorted()
        }
        var checked = 0
        for (a, b) in [("way/37056567", "relation/1047789"), ("way/37058377", "way/160545994"), ("node/693337509", "relation/1047789")] {
            for mode in TravelMode.allCases {
                let origin = try place(a).shortName
                let row = try XCTUnwrap(rows.first { $0["origin"] as? String == origin && $0["mode"] as? String == mode.rawValue && $0["budgetMinutes"] as? Int == 5 })
                let c = try compare(a, b, mode, 5, .default(for: mode))
                XCTAssertEqual(c.fastest.metrics.seconds, try XCTUnwrap(number(row["fastestSeconds"])), accuracy: 1e-6)
                XCTAssertEqual(c.fastest.metrics.meters, try XCTUnwrap(number(row["fastestMeters"])), accuracy: 1e-6)
                XCTAssertEqual(c.fastest.metrics.stress, try XCTUnwrap(number(row["fastestStress"])), accuracy: 1e-6)
                XCTAssertEqual(c.calmer == nil, row["calmerSeconds"] is NSNull, "\(origin) \(mode)")
                if let seconds = number(row["calmerSeconds"]), let calmer = c.calmer {
                    XCTAssertEqual(calmer.metrics.seconds, seconds, accuracy: 1e-6)
                    XCTAssertEqual(calmer.metrics.meters, try XCTUnwrap(number(row["calmerMeters"])), accuracy: 1e-6)
                    XCTAssertEqual(calmer.metrics.stress, try XCTUnwrap(number(row["calmerStress"])), accuracy: 1e-6)
                }
                XCTAssertEqual(factors(c.fastest), factors(row["fastestFactors"]), "\(origin) \(mode)")
                XCTAssertEqual(factors(c.calmer), factors(row["calmerFactors"]), "\(origin) \(mode)")
                XCTAssertEqual(c.candidateCount, row["candidates"] as? Int)
                XCTAssertEqual(c.reasons, row["reasons"] as? [String])
                checked += 1
            }
        }
        XCTAssertEqual(checked, 9)
    }

    /// The route shown as calmer, or the fastest when there's no calmer one.
    private func shown(_ c: RouteComparison) -> Route { c.calmer ?? c.fastest }
    private func amount(_ r: Route, _ option: RoutePreferences.Option, _ mode: TravelMode) -> Double {
        option.factors(in: mode).reduce(0) { $0 + r.metrics.breakdown[$1].amount }
    }

    /// Trips in the bundled data where each option, set to Avoid, changes the route and cuts that option's factors.
    private static let avoidTrips: [(trip: (String, String), mode: TravelMode, options: [RoutePreferences.Option])] = [
        (("node/2544213221", "node/4318969638"), .bike, RoutePreferences.Option.allCases),
        (("node/6737717414", "way/293941621"), .drive, [.trafficLights, .stopSigns, .unprotectedLefts, .busyCrossings, .turns]),
        (("node/2158768959", "node/2327652050"), .drive, [.hills]),
        (("way/253553517", "way/222420235"), .walk, [.trafficLights, .busyStreets, .busyCrossings, .hills]),
    ]

    func testEachOptionSetToAvoidChangesARealTripAndNeverAddsItsFactors() throws {
        var covered = Set<String>()
        for (trip, mode, options) in Self.avoidTrips {
            let plain = try compare(trip.0, trip.1, mode)
            for factor in Set([plain.fastest, shown(plain)].flatMap { $0.metrics.breakdown.tallies.keys }) {
                guard let option = factor.preferenceOption else { continue }
                XCTAssertTrue(option.factors(in: mode).contains(factor), "\(mode) records \(factor), which \(option) doesn't list")
            }
            for option in options {
                let avoided = try compare(trip.0, trip.1, mode, 5, .init([option: .avoid]))
                let label = "\(mode) \(option) \(trip)"
                XCTAssertEqual(avoided.fastest.edgeIDs, plain.fastest.edgeIDs, "The fastest route ignores preferences: \(label)")
                XCTAssertNotEqual(shown(avoided).edgeIDs, shown(plain).edgeIDs, label)
                XCTAssertLessThan(amount(shown(avoided), option, mode), amount(shown(plain), option, mode), label)
                XCTAssertLessThanOrEqual(shown(avoided).metrics.seconds, avoided.fastest.metrics.seconds + 300.000001, "Budget still applies: \(label)")
                covered.insert("\(mode) \(option)")
            }
        }
        let offered = TravelMode.allCases.flatMap { mode in RoutePreferences.Option.available(in: mode).map { "\(mode) \($0)" } }
        XCTAssertEqual(covered, Set(offered), "Every offered option has a trip it changes")
    }

    /// Cyclists and drivers who don't mind stop signs get a quicker route through them; walkers who don't mind busy crossings likewise.
    func testDontMindTradesThatFactorForTime() throws {
        let trip = ("node/6737717414", "way/293941621")
        for (mode, option) in [(TravelMode.bike, RoutePreferences.Option.stopSigns), (.drive, .stopSigns), (.walk, .busyCrossings)] {
            let plain = try compare(trip.0, trip.1, mode), relaxed = try compare(trip.0, trip.1, mode, 5, .init([option: .dontMind]))
            let label = "\(mode) \(option)"
            XCTAssertNotEqual(shown(relaxed).edgeIDs, shown(plain).edgeIDs, label)
            XCTAssertGreaterThan(amount(shown(relaxed), option, mode), amount(shown(plain), option, mode), label)
            XCTAssertLessThan(shown(relaxed).metrics.seconds, shown(plain).metrics.seconds, label)
        }
    }

    func testAnOptionTheModeDoesNotHaveChangesNothing() throws {
        let plain = try compare("way/37056567", "relation/1047789", .walk)
        let other = try compare("way/37056567", "relation/1047789", .walk, 5, .init([.stopSigns: .avoid, .unprotectedLefts: .avoid, .turns: .dontMind]))
        XCTAssertEqual(other.fastest.edgeIDs, plain.fastest.edgeIDs)
        XCTAssertEqual(other.calmer?.edgeIDs, plain.calmer?.edgeIDs)
    }
}
