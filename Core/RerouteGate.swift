import Foundation

/// Decides when a fix the engine calls off-route should start a reroute. Plain Swift, engine-independent.
///
/// The engine's own check is a fixed distance from the current step's line, judged on every fix. This gate adds
/// what a single fix cannot know: the GPS error and the speed that make one wide fix ordinary, the run of fixes
/// a real wrong turn produces, a floor on how often the route may be replaced, and the approach to a route whose
/// first coordinate is a snapped node some way from where the user stands.
public struct RerouteGate: Sendable {
    public struct Fix: Sendable {
        public let coordinate: Coordinate
        /// How far the engine says the fix is from the route, in metres.
        public let metersOffRoute: Double
        /// Reported horizontal accuracy, in metres: the radius the true position is inside about two times in three.
        public let accuracy: Double
        /// Metres per second, when the fix carries one.
        public let speed: Double?
        public let time: Date
        public init(coordinate: Coordinate, metersOffRoute: Double, accuracy: Double, speed: Double?, time: Date) {
            self.coordinate = coordinate; self.metersOffRoute = metersOffRoute; self.accuracy = accuracy; self.speed = speed; self.time = time
        }
    }

    public let mode: TravelMode
    /// Metres off the route before the error allowances: 50 driving, 30 cycling and walking, as in `Docs/NAVIGATION.md`.
    public var baseMeters: Double
    /// Consecutive fixes over the threshold before rerouting: about three seconds at the one-fix-a-second GPS rate.
    public var fixesBeforeReroute = 3
    /// Least time between one route being installed and the next reroute starting: long enough for a new route's
    /// first instruction to be shown and spoken before it can be replaced.
    public var minimumInterval: TimeInterval = 10

    private var installed: Date?
    private var reached = false
    private var run = 0
    private var closest = Double.infinity
    private var initialGap: Double?
    private var travelled = 0.0
    private var last: Coordinate?

    public init(mode: TravelMode) {
        self.mode = mode
        baseMeters = mode == .drive ? 50 : 30
    }

    /// Metres a fix must be off the route to count: the base, plus the fix's own error radius, plus one second of
    /// travel, which is how far a once-a-second fix lags a moving user.
    public func threshold(accuracy: Double, speed: Double?) -> Double {
        baseMeters + max(0, accuracy) + max(0, speed ?? 0)
    }

    /// A route was handed to the engine: at the start, or the result of a reroute.
    public mutating func routeInstalled(at time: Date) {
        installed = time
        reached = false; run = 0; closest = .infinity; initialGap = nil; travelled = 0; last = nil
    }

    /// The engine judged a fix on the route.
    public mutating func onRoute() {
        reached = true; run = 0
    }

    /// Whether this off-route fix should start a reroute.
    public mutating func shouldReroute(_ fix: Fix) -> Bool {
        let threshold = threshold(accuracy: fix.accuracy, speed: fix.speed)
        if let last { travelled += last.distance(to: fix.coordinate) }
        last = fix.coordinate
        if !reached {
            // Heading for a route that starts at a snapped node is not leaving it. Reroute only once the user is
            // moving away from the route, or has travelled far enough to have reached its start and has not.
            let gap = initialGap ?? fix.metersOffRoute
            initialGap = gap
            closest = min(closest, fix.metersOffRoute)
            let away = fix.metersOffRoute > closest + threshold
            let overdue = travelled > 2 * gap + threshold
            guard away || overdue else { return false }
        } else {
            guard fix.metersOffRoute > threshold else { run = 0; return false }
            run += 1
            guard run >= fixesBeforeReroute else { return false }
        }
        if let installed, fix.time.timeIntervalSince(installed) < minimumInterval { return false }
        return true
    }
}
