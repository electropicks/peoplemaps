import Foundation

extension DriveLog.RouteRecord {
    /// A graph route with the navigation plan built from it. `calm` is the score the comparison showed for it, if any.
    public init(label: String, route: Route, plan: NavigationPlan, calm: CalmScore?) {
        let mode = plan.mode
        let edgeSeconds = route.edges.map { StressModel.seconds($0, mode: mode) }
        var starts: [Int] = [], at = 0
        for (k, edge) in route.edges.enumerated() { starts.append(at); at += k == 0 ? edge.coordinates.count : max(0, edge.coordinates.count - 1) }
        var breakdown: [String: [Double]] = [:]
        for factor in Factor.allCases {
            let tally = route.metrics.breakdown[factor]
            if tally.amount > 0 || tally.cost > 0 { breakdown[factor.rawValue] = [Self.round(tally.amount, 1), Self.round(tally.cost, 1)] }
        }
        self.init(label: label, meters: Self.round(route.metrics.meters, 1), seconds: Self.round(route.metrics.seconds, 1),
                  stress: Self.round(route.metrics.stress, 1), calmScore: calm?.value, calmLevel: calm?.level.title,
                  edgeIDs: route.edgeIDs, wayIDs: route.edges.map(\.wayID), edgeNames: route.edges.map(\.name),
                  edgeMeters: route.edgeMeters.isEmpty ? route.edges.map { Self.round($0.meters, 1) } : route.edgeMeters.map { Self.round($0, 1) },
                  edgeSeconds: edgeSeconds.map { Self.round($0, 1) }, edgeStart: starts,
                  junctionSeconds: route.edges.isEmpty ? nil : Self.round(route.metrics.seconds - edgeSeconds.reduce(0, +), 1),
                  coordinates: route.coordinates.map { [Self.round($0.lat, 6), Self.round($0.lon, 6)] },
                  maneuvers: Self.steps(plan), breakdown: breakdown)
    }

    /// The part of a route that can be rebuilt from its plan alone.
    public init(label: String, plan: NavigationPlan, coordinates: [Coordinate]) {
        self.init(label: label, meters: Self.round(plan.meters, 1), seconds: Self.round(plan.seconds, 1), stress: nil, calmScore: nil, calmLevel: nil,
                  edgeIDs: [], wayIDs: [], edgeNames: [], edgeMeters: [], edgeSeconds: [], edgeStart: [], junctionSeconds: nil,
                  coordinates: coordinates.map { [Self.round($0.lat, 6), Self.round($0.lon, 6)] }, maneuvers: Self.steps(plan), breakdown: nil)
    }

    static func round(_ x: Double, _ places: Int) -> Double { DriveLog.Fix.round(x, places) }

    static func steps(_ plan: NavigationPlan) -> [Step] {
        plan.steps.enumerated().map { i, step in
            let first = step.coordinates.first
            return Step(index: i, kind: kind(step.maneuver), instruction: step.instruction, street: step.street, meters: round(step.meters, 1),
                        seconds: round(step.seconds, 1), lat: first.map { round($0.lat, 6) }, lon: first.map { round($0.lon, 6) }, note: step.calmNote)
        }
    }

    static func kind(_ m: Maneuver) -> String {
        switch m {
        case .depart: "depart"
        case .continueOnto: "continue"
        case .cross: "cross"
        case .arrive: "arrive"
        case let .turn(d):
            switch d {
            case .left: "left"
            case .slightLeft: "slight_left"
            case .sharpLeft: "sharp_left"
            case .right: "right"
            case .slightRight: "slight_right"
            case .sharpRight: "sharp_right"
            case .uTurn: "u_turn"
            }
        }
    }
}

extension DriveLog.RequestRecord {
    public init(_ request: RouteRequest, snappedOrigin: Coordinate? = nil, snappedDestination: Coordinate? = nil) {
        let preferences = Dictionary(uniqueKeysWithValues: RoutePreferences.Option.allCases.compactMap { o in
            request.preferences[o] == .normal ? nil : (o.rawValue, request.preferences[o].rawValue) })
        self.init(originName: request.origin.name, originLat: request.origin.lat, originLon: request.origin.lon,
                  destinationName: request.destination.name, destinationID: request.destination.id,
                  destinationLat: request.destination.lat, destinationLon: request.destination.lon,
                  extraMinutes: request.extraMinutes, preferences: preferences)
        snappedOriginLat = snappedOrigin?.lat; snappedOriginLon = snappedOrigin?.lon
        snappedDestinationLat = snappedDestination?.lat; snappedDestinationLon = snappedDestination?.lon
    }
}
