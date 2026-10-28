import Foundation
import PeoplemapsCore
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI

/// Ferrostar's route source for the first route AND every reroute: our own `NativeRouter`, offline.
/// A reroute keeps the destination, mode, extra-time budget and the user's calmer/fastest choice.
final class OwnRouteProvider: CustomRouteProvider, @unchecked Sendable {
    let router: NativeRouter
    let destination: Place
    let mode: TravelMode
    let extraMinutes: Int
    let preferCalmer: Bool
    /// Called with every route handed to Ferrostar, so the UI can read the plan behind it.
    private let onRoute: @Sendable (AdaptedRoute) -> Void

    init(router: NativeRouter, destination: Place, mode: TravelMode, extraMinutes: Int, preferCalmer: Bool, onRoute: @escaping @Sendable (AdaptedRoute) -> Void) {
        self.router = router; self.destination = destination; self.mode = mode
        self.extraMinutes = extraMinutes; self.preferCalmer = preferCalmer; self.onRoute = onRoute
    }

    func getRoutes(userLocation: UserLocation, waypoints: [Waypoint]) async throws -> [FerrostarCoreFFI.Route] {
        let here = Place(id: "current-location", name: "Current location", lat: userLocation.coordinates.lat, lon: userLocation.coordinates.lng, category: "gps")
        // Throws `RoutingError.noConnection` when no street is within 400 m, so Ferrostar keeps the old route.
        let comparison = try await router.compare(RouteRequest(origin: here, destination: destination, mode: mode, extraMinutes: extraMinutes))
        let chosen = (preferCalmer ? comparison.calmer : nil) ?? comparison.fastest
        let adapted = try FerrostarAdapter.convert(chosen.navigationPlan(mode: mode), destination: destination)
        onRoute(adapted)
        return [adapted.route]
    }
}
