import Foundation

/// Everything that makes a route ask more of you, per Docs/STRESS_MODEL.md.
/// Costs are in equivalent seconds: roughly how much extra travel time a typical local would accept to avoid it.
/// They are hypotheses to be fitted to real choices later, not measurements, and never a safety rating.
public enum Factor: String, CaseIterable, Sendable, Comparable {
    // Events, counted
    case unsignalledLeft, unsignalledCrossing, unsignalledRight, leftAtSignal, turn
    case stopSign, allWayStop, signal, yield, stopAndGo, complexJunction, hillStop
    case freewayEntry, shortFreewayHop, movableBridge, cutThrough, bikeRouteGap
    case unmarkedCrossing, markedCrossing, signalCrossing, sideStreetCrossing, stairs
    // Exposure, in metres
    case residential, narrowWithParking, quietStreet, arterialRiding, busyArterialRiding
    case roughSurface, steepDescent, besideTraffic, noSidewalk
    case climb
    // Unknowns, in metres: a small default cost, shown as caveats rather than reasons
    case unknownSurface, unknownSidewalk

    public static func < (a: Self, b: Self) -> Bool { a.order < b.order }
    private var order: Int { Self.allCases.firstIndex(of: self)! }

    public var isExposure: Bool { [.residential, .narrowWithParking, .quietStreet, .arterialRiding, .busyArterialRiding,
                                   .roughSurface, .steepDescent, .besideTraffic, .noSidewalk, .unknownSurface, .unknownSidewalk].contains(self) }
    public var isUnknown: Bool { self == .unknownSurface || self == .unknownSidewalk }

    /// Short label for tables.
    public var title: String {
        switch self {
        case .unsignalledLeft: "Lefts without a signal"
        case .unsignalledCrossing: "Busy crossings, no signal"
        case .unsignalledRight: "Rights into traffic, no signal"
        case .leftAtSignal: "Lefts at signals"
        case .turn: "Turns"
        case .stopSign: "Stop signs"
        case .allWayStop: "All-way stops"
        case .signal: "Traffic signals"
        case .yield: "Yields"
        case .stopAndGo: "Stop-and-go stops"
        case .complexJunction: "5+ way intersections"
        case .hillStop: "Stops on steep hills"
        case .freewayEntry: "Freeway entries"
        case .shortFreewayHop: "Short freeway hops"
        case .movableBridge: "Drawbridges"
        case .cutThrough: "Side-street shortcuts"
        case .bikeRouteGap: "Bike route gaps"
        case .unmarkedCrossing: "Unmarked busy crossings"
        case .markedCrossing: "Marked crossings, no signal"
        case .signalCrossing: "Signalled crossings"
        case .sideStreetCrossing: "Side-street crossings"
        case .stairs: "Steps"
        case .residential: "Residential streets"
        case .narrowWithParking: "Narrow, parked both sides"
        case .quietStreet: "Quiet streets"
        case .arterialRiding: "Riding on arterials"
        case .busyArterialRiding: "Busy arterials, in traffic"
        case .roughSurface: "Rough surface"
        case .steepDescent: "Steep downhill in traffic"
        case .besideTraffic: "Beside arterial traffic"
        case .noSidewalk: "No sidewalk"
        case .climb: "Climbing"
        case .unknownSurface: "Surface unknown"
        case .unknownSidewalk: "Sidewalk unknown"
        }
    }

    /// An amount of this factor for a table cell: a count, kilometres, or metres climbed.
    public func formatted(_ amount: Double) -> String {
        self == .climb ? "\(Int(amount.rounded())) m" : isExposure ? String(format: "%.1f km", amount / 1000) : "\(Int(amount.rounded()))"
    }

    /// Plain-language description of an amount of this factor: a count, metres, or metres of climbing.
    public func describe(_ amount: Double) -> String {
        if self == .climb { return "\(Int(amount.rounded())) m of climbing" }
        if isExposure { return "\(String(format: "%.1f", amount / 1000)) km \(exposurePhrase)" }
        let n = Int(amount.rounded())
        let (one, many) = eventPhrase
        return "\(n) \(n == 1 ? one : many)"
    }
    private var exposurePhrase: String {
        switch self {
        case .residential: "on residential streets"
        case .narrowWithParking: "on narrow streets with parking on both sides"
        case .quietStreet: "on quiet streets"
        case .arterialRiding: "riding on arterials"
        case .busyArterialRiding: "riding in traffic on busy arterials"
        case .roughSurface: "on rough surfaces"
        case .steepDescent: "of steep downhill in traffic"
        case .besideTraffic: "walking beside arterial traffic"
        case .noSidewalk: "without a sidewalk"
        case .unknownSurface: "with unknown surface"
        case .unknownSidewalk: "where sidewalks aren't mapped"
        default: ""
        }
    }
    private var eventPhrase: (String, String) {
        switch self {
        case .unsignalledLeft: ("left turn across traffic without a signal", "left turns across traffic without a signal")
        case .unsignalledCrossing: ("crossing of a busy street without a signal", "crossings of busy streets without a signal")
        case .unsignalledRight: ("right turn into arterial traffic without a signal", "right turns into arterial traffic without a signal")
        case .leftAtSignal: ("left turn at a signal", "left turns at signals")
        case .turn: ("turn", "turns")
        case .stopSign: ("stop sign", "stop signs")
        case .allWayStop: ("all-way stop", "all-way stops")
        case .signal: ("traffic signal", "traffic signals")
        case .yield: ("yield", "yields")
        case .stopAndGo: ("stop-and-go stop", "stop-and-go stops")
        case .complexJunction: ("intersection of five or more streets", "intersections of five or more streets")
        case .hillStop: ("stop on a steep hill", "stops on steep hills")
        case .freewayEntry: ("freeway entry", "freeway entries")
        case .shortFreewayHop: ("short freeway hop with quick lane changes", "short freeway hops with quick lane changes")
        case .movableBridge: ("drawbridge", "drawbridges")
        case .cutThrough: ("side-street shortcut", "side-street shortcuts")
        case .bikeRouteGap: ("place where the bike route drops you into traffic", "places where the bike route drops you into traffic")
        case .unmarkedCrossing: ("unmarked crossing of a busy street", "unmarked crossings of busy streets")
        case .markedCrossing: ("marked crossing without a signal", "marked crossings without a signal")
        case .signalCrossing: ("signalled crossing", "signalled crossings")
        case .sideStreetCrossing: ("side-street crossing", "side-street crossings")
        case .stairs: ("step", "steps")
        default: ("", "")
        }
    }
}

/// Per-factor totals for a route: amount (count or metres) and cost in equivalent seconds.
public struct Tally: Sendable {
    public var amount = 0.0
    public var cost = 0.0
}

protocol StressRecorder {
    mutating func add(_ factor: Factor, amount: Double, cost: Double)
}

/// Used during search, where only the total matters.
struct NoRecord: StressRecorder {
    mutating func add(_ factor: Factor, amount: Double, cost: Double) {}
}

public struct Breakdown: StressRecorder, Sendable {
    public private(set) var tallies: [Factor: Tally] = [:]
    public var stress: Double { tallies.values.reduce(0) { $0 + $1.cost } }
    public subscript(_ factor: Factor) -> Tally { tallies[factor] ?? Tally() }
    public init() {}
    mutating func add(_ factor: Factor, amount: Double, cost: Double) {
        tallies[factor, default: Tally()].amount += amount
        tallies[factor, default: Tally()].cost += cost
    }
}

/// What a junction looks like to someone passing through it.
struct Junction {
    /// A signal at the junction or on an approach within 30 m.
    var signalized = false
    var pedestrianSignal = false
    /// Distinct streets meeting here (road legs).
    var legs = 0
    /// The busiest arterial at this junction other than the two ways being used; nil if none.
    var crossedArterial: RoadClass?
}

public enum StressModel {
    // MARK: Time (honest estimates; stress never changes them)

    static func seconds(_ e: GraphEdge, mode: TravelMode) -> Double {
        switch mode {
        case .drive:
            let defaults: [String: Double] = ["motorway":70, "motorway_link":32, "trunk":50, "trunk_link":28,
                "primary":35, "primary_link":22, "secondary":32, "secondary_link":20, "tertiary":28,
                "tertiary_link":18, "residential":22, "unclassified":22, "living_street":12, "service":12]
            let assumed = defaults[e.highway] ?? 18
            let posted = (e.speedLimitMph ?? 100) * 1.609_344 * 0.8
            return e.meters / (max(5, min(assumed, posted)) / 3.6)
        case .bike:
            let kph = e.isRough ? 11.0 : e.facility == "sharedPath" ? 14 : 18
            // About 3 s per metre climbed (roughly 8 km/h up an 8% grade), a little back going down, capped at 32 km/h.
            return max(e.meters / (32 / 3.6), e.meters / (kph / 3.6) + 3 * e.climb - 0.5 * e.descent)
        case .walk:
            if e.highway == "steps" { return e.meters / 0.6 }
            return e.meters / 1.4 + 2.5 * e.climb  // close to Tobler's hiking function for city grades
        }
    }

    static func transitionSeconds(previous p: GraphEdge, next n: GraphEdge, turned: Bool, junction j: Junction, mode: TravelMode) -> Double {
        switch mode {
        case .drive:
            let control: Double = switch p.control { case .signal: 12; case .stop, .allstop: 5; case .yield: 2; case nil: 0 }
            return control + (turned ? 5 : 0)
        case .bike:
            let control: Double = switch p.control { case .signal: 8; case .stop, .allstop: 3; case .yield: 1; case nil: 0 }
            return control + (turned ? 2 : 0)
        case .walk:
            let signalCrossing = (n.crossing?.control == "signal" && n.crossing?.road != nil && n.crossing?.road != .local)
            return signalCrossing ? 25 : 0  // average wait for the walk signal
        }
    }

    // MARK: Stress along an edge

    static func exposure<R: StressRecorder>(_ e: GraphEdge, mode: TravelMode, arrivesAtRoad: Bool, into r: inout R) -> Double {
        var total = 0.0
        func add(_ f: Factor, _ amount: Double, perUnit: Double) {
            let cost = amount * perUnit
            r.add(f, amount: amount, cost: cost)
            total += cost
        }
        switch mode {
        case .drive:
            if e.isResidential { add(.residential, e.meters, perUnit: 0.030) }
            if e.parkedBothSides == true, (e.lanes ?? 2) <= 2, e.twoWayForDriving { add(.narrowWithParking, e.meters, perUnit: 0.040) }
        case .bike:
            switch levelOfTrafficStress(e) {
            case 2: add(.quietStreet, e.meters, perUnit: 0.060)
            case 3: add(.arterialRiding, e.meters, perUnit: 0.240)
            case 4: add(.busyArterialRiding, e.meters, perUnit: 0.600)
            default: break
            }
            if e.isRough { add(.roughSurface, e.meters, perUnit: 0.060) }
            if e.surface == nil { add(.unknownSurface, e.meters, perUnit: 0.005) }
            if e.climb > 0 { add(.climb, e.climb, perUnit: 4) }
            if e.descent / e.meters > 0.08, levelOfTrafficStress(e) >= 2 { add(.steepDescent, e.meters, perUnit: 0.200) }
        case .walk:
            if let crossing = e.crossing, arrivesAtRoad { total += crossingCost(crossing, into: &r) }
            if e.footway == "sidewalk" {
                if let road = e.besideRoad, road >= .arterial { add(.besideTraffic, e.meters, perUnit: 0.060) }
            } else if e.isRoad {
                let road = e.roadClass ?? .local
                switch e.sidewalk {
                case "yes": if road >= .arterial { add(.besideTraffic, e.meters, perUnit: 0.060) }
                case "no": add(.noSidewalk, e.meters, perUnit: road >= .arterial ? 0.400 : 0.030)
                // Walking in the roadway where the sidewalks are mapped as their own paths
                case "separate": add(.noSidewalk, e.meters, perUnit: road >= .arterial ? 0.400 : 0.060)
                default:
                    if road >= .arterial { add(.besideTraffic, e.meters, perUnit: 0.060) }
                    add(.unknownSidewalk, e.meters, perUnit: 0.020)
                }
            }
            if let steps = e.steps { add(.stairs, Double(steps), perUnit: 1) }
            if e.climb > 0 { add(.climb, e.climb, perUnit: 2) }
        }
        return total
    }

    /// Level of Traffic Stress (Mekuria, Furth & Nixon 2012), simplified to the tags Seattle's map has.
    static func levelOfTrafficStress(_ e: GraphEdge) -> Int {
        if e.hasCycleTrackTag || e.facility == "sharedPath" || ["cycleway", "path", "footway", "pedestrian", "living_street", "track"].contains(e.highway) { return 1 }
        guard let road = e.roadClass else { return 2 }  // service roads
        switch road {
        case .local: return (e.speedLimitMph ?? 25) <= 25 ? 2 : 3
        case .arterial: return e.facility == "lane" ? 2 : 3
        case .busy: return e.facility == "lane" ? 3 : 4
        }
    }

    private static func crossingCost<R: StressRecorder>(_ c: Crossing, into r: inout R) -> Double {
        let (factor, cost): (Factor, Double)
        switch (c.road, c.control) {
        case (nil, _), (.local?, _): (factor, cost) = (.sideStreetCrossing, 3)
        case (_, "signal"?): (factor, cost) = (.signalCrossing, 10)
        case (let road?, "marked"?): (factor, cost) = (.markedCrossing, road == .busy ? 90 : 45)
        case (let road?, _): (factor, cost) = (.unmarkedCrossing, road == .busy ? 180 : 90)
        }
        r.add(factor, amount: 1, cost: cost)
        return cost
    }

    // MARK: Stress at a junction

    /// Signed turn angle in degrees; positive is a left turn.
    public static func angle(previous p: GraphEdge, next n: GraphEdge) -> Double {
        let a = p.coordinates[p.coordinates.count - 2], b = p.coordinates[p.coordinates.count - 1], c = n.coordinates[1]
        let scale = cos(b.lat * .pi / 180)
        let ux = (b.lon - a.lon) * scale, uy = b.lat - a.lat
        let vx = (c.lon - b.lon) * scale, vy = c.lat - b.lat
        return atan2(ux * vy - uy * vx, ux * vx + uy * vy) * 180 / .pi
    }

    static func isTurn(previous p: GraphEdge, next n: GraphEdge) -> Bool {
        abs(angle(previous: p, next: n)) > 35 && p.wayID != n.wayID
    }

    static func transition<R: StressRecorder>(previous p: GraphEdge, next n: GraphEdge, junction j: Junction,
                                             mode: TravelMode, into r: inout R) -> Double {
        var total = 0.0
        func add(_ f: Factor, _ cost: Double) { r.add(f, amount: 1, cost: cost); total += cost }
        let a = angle(previous: p, next: n)
        let turned = abs(a) > 35 && p.wayID != n.wayID
        let left = turned && a > 0, right = turned && a < 0
        let signalized = j.signalized || p.control == .signal
        let major = [p.roadClass, n.roadClass, j.crossedArterial].compactMap { $0 }.filter { $0 >= .arterial }.max()
        let pMinor = (p.roadClass ?? .local) < .arterial, nMinor = (n.roadClass ?? .local) < .arterial
        var waits = false

        switch mode {
        case .drive:
            switch p.control {
            case .stop: add(.stopSign, 15); waits = true
            case .allstop: add(.allWayStop, 20); waits = true
            case .signal: add(.signal, 10); waits = true
            case .yield: add(.yield, 8)
            case nil: break
            }
            if left, let major {
                if signalized { add(.leftAtSignal, p.leftTurnLane == true ? 10 : p.leftTurnLane == false ? 30 : 20) }
                else { add(.unsignalledLeft, major == .busy ? 180 : 120); waits = true }
            } else if !turned, let crossed = j.crossedArterial, pMinor, nMinor, !signalized {
                add(.unsignalledCrossing, crossed == .busy ? 150 : 90); waits = true
            } else if right, !nMinor, pMinor, !signalized {
                add(.unsignalledRight, 15); waits = true
            }
            if turned { add(.turn, 8) }
            if j.legs >= 5 { add(.complexJunction, 40) }
            if waits, let g = p.approachGrade, g > 8 { add(.hillStop, g > 12 ? 60 : 30) }
            if !p.isHighway && n.isHighway { add(.freewayEntry, 30) }
            if n.movableBridge && !p.movableBridge { add(.movableBridge, 30) }
        case .bike:
            switch p.control {
            case .stop: add(.stopSign, 10); waits = true
            case .allstop: add(.allWayStop, 10); waits = true
            case .signal: add(.signal, 8); waits = true
            case .yield: add(.yield, 4)
            case nil: break
            }
            if left, major != nil, !(n.hasCycleTrackTag || n.facility == "sharedPath") {
                if signalized { add(.leftAtSignal, 15) } else { add(.unsignalledLeft, 90); waits = true }
            } else if !turned, let crossed = j.crossedArterial, pMinor, nMinor, !signalized {
                add(.unsignalledCrossing, crossed == .busy ? 150 : 60); waits = true
            }
            if p.facility != "none", n.facility == "none", !nMinor { add(.bikeRouteGap, 20) }
            if turned { add(.turn, 4) }
            if waits, let g = p.approachGrade, g > 6 { add(.hillStop, 20) }
            if n.movableBridge && !p.movableBridge { add(.movableBridge, 15) }
        case .walk:
            // Walking along streets (not mapped sidewalks) straight across an arterial.
            if p.isRoad, n.isRoad, !turned, let crossed = j.crossedArterial {
                if j.pedestrianSignal || signalized { add(.signalCrossing, 10) }
                else { add(.unmarkedCrossing, crossed == .busy ? 180 : 90) }
            }
        }
        return total
    }

    // MARK: Whole-route factors the search can't see edge by edge

    struct Event { let factor: Factor; let at: Double }

    /// Stop-and-go clusters, short freeway hops and side-street shortcuts, from the finished route.
    static func pathFactors(edges: [GraphEdge], stops: [Double], mode: TravelMode, into r: inout Breakdown) {
        guard mode != .walk else { return }
        // 3 or more stops within 400 m: each stop beyond the second costs extra.
        for (i, at) in stops.enumerated() {
            let recent = stops[..<i].filter { at - $0 <= 400 }.count
            if recent >= 2 { r.add(.stopAndGo, amount: 1, cost: mode == .drive ? 10 : 5) }
        }
        guard mode == .drive else { return }
        var run = 0.0, entered: Double?
        for (i, e) in edges.enumerated() {
            let wasHighway = i > 0 && edges[i - 1].isHighway
            if e.isHighway && !wasHighway { entered = run }
            if !e.isHighway && wasHighway, let start = entered, run - start < 2000 { r.add(.shortFreewayHop, amount: 1, cost: 90) }
            run += e.meters
        }
        // Leaving a named arterial for side streets and rejoining it within 1.5 km.
        struct Stretch { var name: String; var road: RoadClass?; var start: Double; var end: Double }
        var stretches: [Stretch] = []; run = 0
        for e in edges {
            if let last = stretches.last, last.name == e.name { stretches[stretches.count - 1].end = run + e.meters }
            else { stretches.append(.init(name: e.name, road: e.roadClass, start: run, end: run + e.meters)) }
            run += e.meters
        }
        for (i, s) in stretches.enumerated() where !s.name.isEmpty && (s.road ?? .local) >= .arterial {
            guard let j = stretches[(i + 1)...].firstIndex(where: { $0.name == s.name }), stretches[j].start - s.end < 1500 else { continue }
            if stretches[(i + 1)..<j].contains(where: { $0.road == .local }) { r.add(.cutThrough, amount: 1, cost: 60) }
        }
    }
}
