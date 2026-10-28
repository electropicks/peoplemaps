import Foundation
import PeoplemapsCore
@preconcurrency import FerrostarCoreFFI

/// A Ferrostar route made from one of our plans, plus what the UI needs that Ferrostar does not carry.
struct AdaptedRoute: @unchecked Sendable {
    let route: FerrostarCoreFFI.Route
    let plan: NavigationPlan
    let destination: Place
    /// Parallel to `plan.steps`: the calm note of the maneuver that begins each step.
    var calmNotes: [String?] { plan.steps.map(\.calmNote) }
}

enum FerrostarAdapterError: Error { case emptyPlan }

/// The only place that knows Ferrostar's route model. Swapping the engine later means replacing this file.
enum FerrostarAdapter {
    /// Distances before a maneuver at which the banner and voice fire: (far, near) in metres.
    static func triggers(for mode: TravelMode) -> (far: Double, near: Double) {
        mode == .drive ? (400, 100) : (100, 30)
    }

    /// One Ferrostar step per `NavigationStep` (its geometry runs from its maneuver to the next one), plus a zero-length arrive step.
    /// Instructions attach to the step BEFORE their maneuver, so step `i` announces `plan.steps[i + 1]`.
    static func convert(_ plan: NavigationPlan, destination: Place) throws -> AdaptedRoute {
        let travelled = plan.steps.dropLast()
        var geometry: [Coordinate] = []
        for step in travelled where !step.coordinates.isEmpty {
            geometry.append(contentsOf: geometry.isEmpty ? step.coordinates : Array(step.coordinates.dropFirst()))
        }
        guard let first = geometry.first, let last = geometry.last, geometry.count > 1 else { throw FerrostarAdapterError.emptyPlan }
        let (far, near) = triggers(for: plan.mode)

        var steps: [RouteStep] = []
        for (i, step) in travelled.enumerated() {
            let upcoming = plan.steps[i + 1]
            let text = upcoming.maneuver == .arrive ? "Arrive at \(destination.shortName)" : upcoming.instruction
            let (type, modifier) = kind(of: upcoming.maneuver)
            let farTrigger = min(far, step.meters), nearTrigger = min(near, step.meters)
            let triggerList = farTrigger > nearTrigger ? [farTrigger, nearTrigger] : [nearTrigger]
            let content = VisualInstructionContent(text: text, maneuverType: type, maneuverModifier: modifier, roundaboutExitDegrees: nil, laneInfo: nil, exitNumbers: [])
            let visual = triggerList.map {
                VisualInstruction(primaryContent: content, secondaryContent: nil, subContent: nil, triggerDistanceBeforeManeuver: $0)
            }
            let spoken = triggerList.enumerated().map { index, trigger in
                // The first (farthest) announcement says how far away; the last is the bare instruction.
                let saying = index == 0 && triggerList.count > 1 ? "In \(NavigationFormat.distance(trigger, spoken: true)), \(text.lowercasedFirst)" : text
                return SpokenInstruction(text: saying, ssml: nil, triggerDistanceBeforeManeuver: trigger, utteranceId: UUID())
            }
            steps.append(RouteStep(geometry: step.coordinates.map(point), distance: step.meters, duration: step.seconds,
                                   roadName: step.street.isEmpty ? nil : step.street, exits: [], instruction: step.instruction,
                                   visualInstructions: visual, spokenInstructions: spoken, annotations: nil, incidents: [],
                                   drivingSide: .right, roundaboutExitNumber: nil))
        }
        let end = point(last)
        steps.append(RouteStep(geometry: [end, end], distance: 0, duration: 0, roadName: nil, exits: [],
                               instruction: "Arrive at \(destination.shortName)", visualInstructions: [], spokenInstructions: [],
                               annotations: nil, incidents: [], drivingSide: .right, roundaboutExitNumber: nil))

        let lats = geometry.map(\.lat), lons = geometry.map(\.lon)
        let bbox = BoundingBox(sw: GeographicCoordinate(lat: lats.min()!, lng: lons.min()!), ne: GeographicCoordinate(lat: lats.max()!, lng: lons.max()!))
        let waypoints = [Waypoint(coordinate: point(first), kind: .break), Waypoint(coordinate: point(destination.coordinate), kind: .break)]
        let route = FerrostarCoreFFI.Route(geometry: geometry.map(point), bbox: bbox, distance: plan.meters, waypoints: waypoints, steps: steps)
        return AdaptedRoute(route: route, plan: plan, destination: destination)
    }

    static func point(_ c: Coordinate) -> GeographicCoordinate { GeographicCoordinate(lat: c.lat, lng: c.lon) }

    static func kind(of maneuver: PeoplemapsCore.Maneuver) -> (ManeuverType, ManeuverModifier?) {
        switch maneuver {
        case .depart: (.depart, nil)
        case .arrive: (.arrive, nil)
        case .continueOnto: (.newName, .straight)
        case .cross: (.continue, .straight)
        case let .turn(direction):
            switch direction {
            case .slightLeft: (.turn, .slightLeft)
            case .left: (.turn, .left)
            case .sharpLeft: (.turn, .sharpLeft)
            case .slightRight: (.turn, .slightRight)
            case .right: (.turn, .right)
            case .sharpRight: (.turn, .sharpRight)
            case .uTurn: (.turn, .uTurn)
            }
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
