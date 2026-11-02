#if DEBUG
import SwiftUI
import UIKit
import PeoplemapsCore

/// What the map drew, for the probe: MapLibre layers are not in the accessibility tree. Written by `SeattleMap`.
@MainActor @Observable
final class MapDebug {
    static let shared = MapDebug()
    /// Times a followed route's source was emptied while guiding. The line must never go blank between routes.
    var routeClears = 0
    /// Length of the dashed leader from the puck to the route's first coordinate, 0 when none is drawn.
    var leaderMeters = 0.0
    /// The followed route's name and the colours its line and leader layers hold, e.g. `fastest 8E8E93 leader 8E8E93`.
    var lineStyle = ""
    /// Which route line the map draws above the other in the preview.
    var topRoute = ""
    /// Base-map features (water, roads, arterials) in view once the map is idle. 0 means no tiles drew.
    var baseFeatures = 0
    /// Metres of the followed line drawn as passed and as ahead, and the passed layer's colour, e.g. `120 ahead 2400 9CB3A3`.
    var passed = ""
    /// The user's marker: `dot`, `dot <degrees>`, `arrow <degrees>`, or `none`.
    var marker = "none"
    /// How each programmatic camera move was made (`cut`, `glide`, `fly`, `fade`), as it would be with motion on.
    var moves: [String] = []
    /// The marker feed: `<count> <ms>`, empty until it is on the map.
    var placeMarkers = ""
    /// The camera's zoom once the map is idle.
    var zoom = 0.0
    /// The portrait sheet on screen, `<top> <bottom> <inset below content>`, in window points.
    var sheet = ""
    /// Frame times while panning, with `--measure-frames`: `<frames> p50 <ms> p95 <ms> p99 <ms> max <ms> long <count>`.
    /// `long` counts frames over 1.5 refresh intervals.
    var frames = ""
}

/// Times each frame while a gesture moves the map, with `--measure-frames`, so a UI test can read what panning costs.
@MainActor final class FrameMeter: NSObject {
    static let shared = FrameMeter()
    private var link: CADisplayLink?
    private var intervals: [Double] = []
    private var last = 0.0
    /// Set by the map from a gesture starting until its motion ends.
    var counting = false { didSet { if !counting { last = 0 } } }
    func start() {
        guard link == nil, ProcessInfo.processInfo.arguments.contains("--measure-frames") else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    /// What the system counts against the app, in MB.
    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
    @objc private func tick(_ link: CADisplayLink) {
        guard counting else { return }
        if last > 0 { intervals.append(link.timestamp - last) }
        last = link.timestamp
        guard intervals.count % 30 == 0, !intervals.isEmpty else { return }
        let sorted = intervals.sorted(), budget = max(link.targetTimestamp - link.timestamp, 1.0 / 120) * 1.5
        func p(_ q: Double) -> Int { Int((sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] * 1000).rounded()) }
        MapDebug.shared.frames = "\(sorted.count) p50 \(p(0.5)) p95 \(p(0.95)) p99 \(p(0.99)) max \(Int((sorted.last! * 1000).rounded())) long \(sorted.filter { $0 > budget }.count) mem \(Self.footprintMB())"
    }
}

extension UIColor {
    /// `RRGGBB` of the colour in the light scheme, for the probe.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))
    }
}

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
        let map = MapDebug.shared
        VStack(spacing: 0) {
            probe("debug-last-spoken", navigator.lastSpoken)
            probe("debug-idle-disabled", idle ? "1" : "0")
            probe("debug-nav-state", state)
            probe("debug-route", routeStart)
            probe("debug-reroute-count", String(navigator.rerouteCount))
            probe("debug-route-clears", String(map.routeClears))
            probe("debug-leader", String(Int(map.leaderMeters.rounded())))
            probe("debug-line-style", map.lineStyle)
            probe("debug-top-route", map.topRoute)
            probe("debug-map-features", String(map.baseFeatures))
            probe("debug-passed", map.passed)
            probe("debug-marker", map.marker)
            probe("debug-camera-moves", map.moves.suffix(6).joined(separator: ","))
            probe("debug-place-markers", map.placeMarkers)
            probe("debug-zoom", String(format: "%.2f", map.zoom))
            probe("debug-sheet", map.sheet)
            probe("debug-frames", map.frames)
        }
        .onAppear { FrameMeter.shared.start() }
        .frame(width: 1, height: 17).allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func probe(_ id: String, _ value: String) -> some View {
        Color.clear.frame(width: 1, height: 1)
            .accessibilityElement().accessibilityLabel(id).accessibilityValue(value).accessibilityIdentifier(id)
    }
}
#endif
