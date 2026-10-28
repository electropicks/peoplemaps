import AVFoundation
import CoreLocation
import Combine
import Foundation
import Observation
import UIKit
import PeoplemapsCore
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI

/// Owns Ferrostar's engine for one guided trip and publishes what the guidance screen shows.
/// Thresholds follow `Docs/NAVIGATION.md`: off-route at 50 m driving and 30 m cycling or walking, Ferrostar's own
/// reroute throttling (5 s, 50 m), steps advance by distance to the end of the step, arrival within 20 m.
@MainActor @Observable
final class NavigationController {
    private(set) var isActive = false
    private(set) var stepIndex = 0
    /// What the top card shows: the upcoming maneuver (or "Head north on…" until the user has set off).
    private(set) var currentStep: NavigationStep?
    private(set) var distanceToManeuver = 0.0
    private(set) var remainingMeters = 0.0
    private(set) var remainingSeconds = 0.0
    private(set) var coordinate: Coordinate?
    private(set) var course: Double?
    private(set) var isRerouting = false
    private(set) var hasArrived = false
    /// Geometry of the route being followed; `routeVersion` changes whenever it is replaced (start or reroute).
    private(set) var routeGeometry: [Coordinate] = []
    private(set) var routeVersion = 0
    private(set) var mode = TravelMode.drive
    private(set) var calmerRoute = false
    private(set) var destination: Place?
    /// The maneuver after the one the card shows ("Then: right onto Halladay St"), nil when the card shows the last one.
    private(set) var thenStep: NavigationStep?
    /// What the arrival summary shows: whole-trip distance and time, and the main differences from the fastest route.
    private(set) var tripMeters = 0.0
    private(set) var tripSeconds = 0.0
    private(set) var tripNotes: [String] = []

    /// The note for the step the card is showing.
    var calmNote: String? { currentStep?.calmNote }
    var instruction: String {
        guard let step = currentStep else { return "" }
        if step.maneuver == .arrive, let destination { return "Arrive at \(destination.shortName)" }
        return step.instruction
    }

    /// "right onto Halladay St": the next maneuver in lower case, for the "Then:" row.
    var thenText: String {
        guard let step = thenStep else { return "" }
        if step.maneuver == .arrive, let destination { return "arrive at \(destination.shortName)" }
        let text = step.instruction.hasPrefix("Turn ") ? String(step.instruction.dropFirst(5)) : step.instruction
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    @ObservationIgnored private let router: NativeRouter
    @ObservationIgnored private var core: FerrostarCore?
    @ObservationIgnored private var subscription: AnyCancellable?
    @ObservationIgnored private var active: AdaptedRoute?
    @ObservationIgnored private var location: LocationProviding?
    @ObservationIgnored private var observer: SpokenInstructionObserver?
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var arrivalHandled = false
    /// Routes handed to Ferrostar, by token, so a reroute's plan can be found when the engine switches to it.
    @ObservationIgnored private var known: [UUID: AdaptedRoute] = [:]

    init(router: NativeRouter) { self.router = router }

    /// Distance walked along a step before "Head north on…" gives way to the next maneuver.
    private static let setOffMeters = 40.0

    #if DEBUG
    static var simulating: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        ProcessInfo.processInfo.arguments.contains("--simulate-route")
        #endif
    }
    #endif

    func start(comparison: RouteComparison, useCalmer: Bool, muted: Bool) {
        stop()
        let request = comparison.request
        let chosen = (useCalmer ? comparison.calmer : nil) ?? comparison.fastest
        let usingCalmer = useCalmer && comparison.calmer != nil
        guard let adapted = try? FerrostarAdapter.convert(chosen.navigationPlan(mode: request.mode), destination: request.destination) else { return }

        let provider = OwnRouteProvider(router: router, destination: request.destination, mode: request.mode,
                                        extraMinutes: request.extraMinutes, preferCalmer: usingCalmer) { [weak self] adapted in
            Task { @MainActor in self?.remember(adapted) }
        }
        let location: LocationProviding
        #if DEBUG
        if Self.simulating {
            let sim = SimulatedLocationProvider()
            let first = adapted.route.geometry[0]
            sim.lastLocation = UserLocation(coordinates: first, horizontalAccuracy: 5, courseOverGround: nil, timestamp: Date(), speed: nil)
            // One tick a second at the route's own average speed is real time; replay four times faster.
            sim.warpFactor = ProcessInfo.processInfo.arguments.contains("--fast-simulation") ? 40 : 4
            try? sim.setSimulatedRoute(adapted.route, resampleDistance: max(1, adapted.plan.meters / max(1, adapted.plan.seconds)))
            location = sim
        } else {
            location = CoreLocationProvider(activityType: Self.activity(request.mode), allowBackgroundLocationUpdates: false)
        }
        #else
        location = CoreLocationProvider(activityType: Self.activity(request.mode), allowBackgroundLocationUpdates: false)
        #endif

        self.location = location
        let observer = SpokenInstructionObserver(synthesizer: AVSpeechSynthesizer(), isMuted: muted)
        self.observer = observer
        let core = FerrostarCore(customRouteProvider: provider, locationProvider: location,
                                 navigationControllerConfig: Self.config(for: request.mode),
                                 spokenInstructionObserver: observer)
        self.core = core
        mode = request.mode; calmerRoute = usingCalmer; destination = request.destination
        tripMeters = adapted.plan.meters; tripSeconds = adapted.plan.seconds
        tripNotes = Self.notes(comparison, calmer: usingCalmer)
        hasArrived = false; isRerouting = false; isActive = true
        arrivalHandled = false; paused = false
        Self.keepAwake(true)
        subscription = core.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            MainActor.assumeIsolated { self?.apply(state) }
        }
        install(adapted)
        do { try core.startNavigation(route: adapted.route) } catch { stop() }
    }

    /// Up to three facts for the arrival summary: what the calmer route avoided, then what it cost in time.
    private static func notes(_ comparison: RouteComparison, calmer: Bool) -> [String] {
        guard calmer else { return [] }
        let gains = comparison.reasons.filter { !$0.hasPrefix("Tradeoff") && !$0.hasPrefix("No calmer") }.prefix(2)
        let extra = comparison.extraTimeLabel
        let cost = extra == "No extra time" ? "No extra time compared with the fastest route"
            : extra.hasPrefix("<1") ? "Under a minute longer than the fastest route"
            : "\(extra.dropFirst()) longer than the fastest route"
        return Array(gains) + [cost]
    }

    /// Follows the stored preference; muting stops anything being said at once.
    func setMuted(_ muted: Bool) {
        if let observer, observer.isMuted != muted { observer.toggleMute() }
    }

    /// Version 1 guides in the foreground only: in the background nothing is said and location updates stop.
    func pause() {
        guard isActive, !paused else { return }
        paused = true
        observer?.stopAndClearQueue()
        location?.stopUpdating()
    }

    func resume() {
        guard isActive, paused else { return }
        paused = false
        if !hasArrived { location?.startUpdating() }
    }

    private static func keepAwake(_ on: Bool) { UIApplication.shared.isIdleTimerDisabled = on }

    /// Arrival: stop location, let the screen sleep again, and say it once.
    private func arrive() {
        guard !arrivalHandled else { return }
        arrivalHandled = true
        location?.stopUpdating()
        Self.keepAwake(false)
        guard let observer, let name = destination?.shortName else { return }
        observer.spokenInstructionTriggered(SpokenInstruction(text: "You've arrived at \(name)", ssml: nil, triggerDistanceBeforeManeuver: 0, utteranceId: UUID()))
    }

    func stop() {
        subscription = nil
        core?.stopNavigation()
        location?.stopUpdating()
        observer?.stopAndClearQueue()
        Self.keepAwake(false)
        core = nil; location = nil; observer = nil; paused = false; arrivalHandled = false
        active = nil; known = [:]
        isActive = false; hasArrived = false; isRerouting = false
        currentStep = nil; thenStep = nil; tripNotes = []; coordinate = nil; course = nil; routeGeometry = []; stepIndex = 0
        distanceToManeuver = 0; remainingMeters = 0; remainingSeconds = 0
    }

    static func config(for mode: TravelMode) -> SwiftNavigationControllerConfig {
        let offRoute = mode == .drive ? 50.0 : 30.0
        let advance: UInt16 = mode == .drive ? 20 : mode == .bike ? 12 : 8
        return SwiftNavigationControllerConfig(
            waypointAdvance: .waypointWithinRange(20),
            stepAdvanceCondition: stepAdvanceDistanceToEndOfStep(distance: advance, minimumHorizontalAccuracy: 32),
            arrivalStepAdvanceCondition: stepAdvanceDistanceToEndOfStep(distance: 20, minimumHorizontalAccuracy: 32),
            routeDeviationTracking: .staticThreshold(minimumHorizontalAccuracy: 25, maxAcceptableDeviation: offRoute),
            snappedLocationCourseFiltering: .snapToRoute)
    }

    private static func activity(_ mode: TravelMode) -> CLActivityType { mode == .drive ? .automotiveNavigation : .fitness }

    private func token(of route: FerrostarCoreFFI.Route) -> UUID? { route.steps.first?.spokenInstructions.first?.utteranceId }

    private func remember(_ adapted: AdaptedRoute) {
        guard core != nil, let token = token(of: adapted.route) else { return }
        known[token] = adapted
    }

    private func install(_ adapted: AdaptedRoute) {
        remember(adapted)
        active = adapted
        routeGeometry = adapted.route.geometry.map { Coordinate(lat: $0.lat, lon: $0.lng) }
        routeVersion += 1
    }

    private func apply(_ state: NavigationState?) {
        guard let state, core != nil else { return }
        // A reroute replaces the route inside the engine; follow it to its plan.
        if let route = core?.route, let token = token(of: route), token != active.flatMap({ self.token(of: $0.route) }), let adapted = known[token] {
            install(adapted)
        }
        isRerouting = state.isCalculatingNewRoute
        if let location = state.preferredUserLocation {
            coordinate = Coordinate(lat: location.coordinates.lat, lon: location.coordinates.lng)
            course = location.courseOverGround.map { Double($0.degrees) }
        }
        switch state.tripState {
        case .complete:
            hasArrived = true
            arrive()
            remainingMeters = 0; remainingSeconds = 0; distanceToManeuver = 0
            if let plan = active?.plan { stepIndex = plan.steps.count - 1; currentStep = plan.steps.last; thenStep = nil }
        case .idle:
            break
        case let .navigating(_, _, _, remaining, _, progress, _, _, _, _, _):
            guard let plan = active?.plan else { return }
            hasArrived = false
            distanceToManeuver = progress.distanceToNextManeuver
            remainingMeters = progress.distanceRemaining
            remainingSeconds = progress.durationRemaining
            stepIndex = min(max(0, plan.steps.count - remaining.count), plan.steps.count - 1)
            let travelled = plan.steps[stepIndex].meters - progress.distanceToNextManeuver
            let heading = stepIndex == 0 && travelled < Self.setOffMeters && plan.steps.count > 1
            let shown = heading ? 0 : min(stepIndex + 1, plan.steps.count - 1)
            currentStep = plan.steps[shown]
            thenStep = shown + 1 < plan.steps.count ? plan.steps[shown + 1] : nil
        }
    }
}
