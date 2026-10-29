import Foundation

public enum TurnDirection: Sendable, Equatable { case slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn }

public enum Maneuver: Sendable, Equatable { case depart, turn(TurnDirection), continueOnto, cross, arrive }

public struct NavigationStep: Sendable {
    public let maneuver: Maneuver
    public let instruction: String
    public let street: String
    /// Distance, time and geometry of the stretch AFTER the maneuver, up to the next maneuver.
    public let meters: Double
    public let seconds: Double
    public let coordinates: [Coordinate]
    /// A stress fact at the maneuver's junction ("Signalled left"); facts only.
    public let calmNote: String?
    public init(maneuver: Maneuver, instruction: String, street: String, meters: Double, seconds: Double, coordinates: [Coordinate], calmNote: String?) {
        self.maneuver = maneuver; self.instruction = instruction; self.street = street
        self.meters = meters; self.seconds = seconds; self.coordinates = coordinates; self.calmNote = calmNote
    }
}

public struct NavigationPlan: Sendable {
    public let steps: [NavigationStep]
    public let mode: TravelMode
    public let meters: Double
    public let seconds: Double
    public init(steps: [NavigationStep], mode: TravelMode, meters: Double, seconds: Double) {
        self.steps = steps; self.mode = mode; self.meters = meters; self.seconds = seconds
    }
}

extension Route {
    public func navigationPlan(mode: TravelMode) -> NavigationPlan {
        NavigationBuilder(route: self, mode: mode).build()
    }
}

struct NavigationBuilder {
    let route: Route
    let mode: TravelMode

    /// One decision point: the edge it happens at, and what it is.
    struct Pending { var edge: Int; var maneuver: Maneuver; var street: String }

    func factors(_ k: Int) -> [Factor] { k < route.junctionFactors.count ? route.junctionFactors[k] : [] }

    func build() -> NavigationPlan {
        let edges = route.edges
        let arrive = NavigationStep(maneuver: .arrive, instruction: "Arrive at destination", street: "", meters: 0, seconds: 0, coordinates: [], calmNote: nil)
        guard !edges.isEmpty else { return NavigationPlan(steps: [arrive], mode: mode, meters: route.metrics.meters, seconds: route.metrics.seconds) }
        let totalMeters = edges.reduce(0) { $0 + $1.meters }
        let secondsPerMeter = totalMeters > 0 ? route.metrics.seconds / totalMeters : 0

        // 1. Find the maneuvers.
        var pending = [Pending(edge: 0, maneuver: .depart, street: edges[0].name)]
        var lastNamed = edges[0].name
        for k in 1..<max(1, edges.count) {
            let previous = edges[k - 1], e = edges[k]
            defer { if !e.name.isEmpty { lastNamed = e.name } }
            let fs = factors(k)
            let crossingFactors: [Factor] = [.signalCrossing, .markedCrossing, .unmarkedCrossing]
            if e.footway == "crossing", previous.footway != "crossing", fs.contains(where: crossingFactors.contains) {
                pending.append(Pending(edge: k, maneuver: .cross, street: e.name))
                continue
            }
            guard !e.name.isEmpty, e.name != lastNamed else { continue }
            if lastNamed.isEmpty {
                // First named street after an unnamed start: say where the user is.
                pending.append(Pending(edge: k, maneuver: .continueOnto, street: e.name))
                continue
            }
            let angle = StressModel.angle(previous: previous, next: e)
            if abs(angle) > 35 {
                pending.append(Pending(edge: k, maneuver: .turn(Self.direction(angle)), street: e.name))
            } else if abs(angle) >= 15 {
                pending.append(Pending(edge: k, maneuver: .continueOnto, street: e.name))
            }  // under 15 degrees: a silent rename
        }

        // 2. Drop short "continue onto" steps; the stretch joins the step before. Turns and crossings always stay.
        let minimum = mode == .drive ? 20.0 : 8.0
        func length(_ from: Int, _ to: Int) -> Double { edges[from..<to].reduce(0) { $0 + $1.meters } }
        var merged = pending
        var changed = true
        while changed {
            changed = false
            for i in merged.indices.dropFirst() where merged[i].maneuver == .continueOnto {
                let end = i + 1 < merged.count ? merged[i + 1].edge : edges.count
                if length(merged[i].edge, end) < minimum { merged.remove(at: i); changed = true; break }
            }
        }

        // 3. Turn them into steps.
        var steps: [NavigationStep] = []
        for (i, p) in merged.enumerated() {
            let end = i + 1 < merged.count ? merged[i + 1].edge : edges.count
            let range = p.edge..<end
            var coordinates: [Coordinate] = []
            for k in range { coordinates.append(contentsOf: k == range.lowerBound ? edges[k].coordinates : Array(edges[k].coordinates.dropFirst())) }
            let meters = length(range.lowerBound, range.upperBound)
            let fs = factors(p.edge)
            let text: String, note: String?
            switch p.maneuver {
            case .depart:
                let e = edges[0], bearing = Self.bearing(e.coordinates.first!, e.coordinates.last!)
                text = "Head \(Self.compass(bearing))" + (e.name.isEmpty ? "" : " on \(Self.shorten(e.name))"); note = nil
            case .turn(let d):
                let name = Self.shorten(p.street)
                switch d {
                case .slightLeft: text = "Turn slightly left onto \(name)"
                case .left: text = "Turn left onto \(name)"
                case .sharpLeft: text = "Make a sharp left onto \(name)"
                case .slightRight: text = "Turn slightly right onto \(name)"
                case .right: text = "Turn right onto \(name)"
                case .sharpRight: text = "Make a sharp right onto \(name)"
                case .uTurn: text = "Make a U-turn"
                }
                note = Self.calmNote(fs)
            case .continueOnto:
                text = "Continue onto \(Self.shorten(p.street))"; note = Self.calmNote(fs)
            case .cross:
                text = fs.contains(.signalCrossing) ? "Cross at the signal" : fs.contains(.markedCrossing) ? "Cross at the crosswalk"
                    : p.street.isEmpty ? "Cross the street" : "Cross \(Self.shorten(p.street))"
                note = Self.calmNote(fs)
            case .arrive:
                text = ""; note = nil
            }
            steps.append(NavigationStep(maneuver: p.maneuver, instruction: text, street: Self.shorten(edges[range].last { !$0.name.isEmpty }?.name ?? p.street), meters: meters,
                                        seconds: meters * secondsPerMeter, coordinates: coordinates, calmNote: note))
        }
        steps.append(arrive)
        return NavigationPlan(steps: steps, mode: mode, meters: route.metrics.meters, seconds: route.metrics.seconds)
    }

    static func direction(_ angle: Double) -> TurnDirection {
        let left = angle > 0, a = abs(angle)
        if a > 170 { return .uTurn }
        if a > 135 { return left ? .sharpLeft : .sharpRight }
        if a > 60 { return left ? .left : .right }
        return left ? .slightLeft : .slightRight
    }

    static func calmNote(_ fs: [Factor]) -> String? {
        let table: [(Factor, String)] = [(.leftAtSignal, "Signalled left"), (.signalCrossing, "Signalled crossing"), (.allWayStop, "All-way stop"),
                                         (.stopSign, "Stop sign"), (.markedCrossing, "Marked crossing"), (.signal, "At a signal")]
        return table.first { fs.contains($0.0) }?.1
    }

    static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dx = (b.lon - a.lon) * cos((a.lat + b.lat) * .pi / 360), dy = b.lat - a.lat
        let deg = atan2(dx, dy) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    static func compass(_ bearing: Double) -> String {
        ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"][Int(((bearing + 22.5) / 45).rounded(.down)) % 8]
    }

    private static let words = ["Avenue": "Ave", "Street": "St", "Drive": "Dr", "Boulevard": "Blvd", "Place": "Pl", "Road": "Rd"]
    private static let directionals = ["North": "N", "South": "S", "East": "E", "West": "W",
                                       "Northeast": "NE", "Northwest": "NW", "Southeast": "SE", "Southwest": "SW"]

    static func shorten(_ name: String) -> String {
        var parts = name.split(separator: " ").map(String.init)
        for i in parts.indices {
            if let short = words[parts[i]] { parts[i] = short }
            else if i == 0 || i == parts.count - 1, let short = directionals[parts[i]] { parts[i] = short }
        }
        return parts.joined(separator: " ")
    }
}
