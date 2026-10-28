#if DEBUG
import SwiftUI
import UIKit
import PeoplemapsCore

/// Invisible, accessible readouts for the UI tests. Only added in Debug builds launched with `--ui-testing`.
struct NavigationDebugProbe: View {
    let navigator: NavigationController

    private var state: String {
        guard navigator.isActive else { return "idle" }
        if navigator.hasArrived { return "arrived" }
        if navigator.isPaused { return "paused" }
        return navigator.isRerouting ? "rerouting" : "guiding"
    }

    /// The first kilometre of the followed route as "lat,lon;lat,lon…", so tests can walk the device along it.
    private var routeStart: String {
        var out: [String] = [], metres = 0.0
        var previous: Coordinate?
        for c in navigator.routeGeometry {
            if let previous { metres += abs(c.lat - previous.lat) * 111_000 + abs(c.lon - previous.lon) * 75_000 }
            out.append(String(format: "%.6f,%.6f", c.lat, c.lon))
            previous = c
            if metres > 1000 { break }
        }
        return out.joined(separator: ";")
    }

    private var idleDisabled: Bool {
        _ = navigator.keepingAwake  // makes the view update when it changes; the value shown is the real system flag
        return UIApplication.shared.isIdleTimerDisabled
    }

    var body: some View {
        let idle = idleDisabled
        VStack(spacing: 0) {
            probe("debug-last-spoken", navigator.lastSpoken)
            probe("debug-idle-disabled", idle ? "1" : "0")
            probe("debug-nav-state", state)
            probe("debug-route", routeStart)
        }
        .frame(width: 1, height: 3).allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func probe(_ id: String, _ value: String) -> some View {
        Color.clear.frame(width: 1, height: 1)
            .accessibilityElement().accessibilityLabel(id).accessibilityValue(value).accessibilityIdentifier(id)
    }
}
#endif
