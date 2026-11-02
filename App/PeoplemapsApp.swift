import SwiftUI
import PeoplemapsCore

@main
struct PeoplemapsApp: App {
    /// Home needs only the graph's bounds and search; the router builds behind it and routing requests wait for it.
    private let ready: Result<(graph: StreetGraph, router: DeferredRouter, search: SearchIndex), Error>
    init() {
        ready = Result {
            let header = try StreetGraph.bundledHeader()
            return (header.boundsOnly, DeferredRouter { Self.holdForTests(); return NativeRouter(graph: try StreetGraph.bundled()) }, try SearchIndex.bundled(graphNodes: header.nodes))
        }
    }
    /// UI tests pass `--hold-router` to keep the router from being ready, proving home never waits for it.
    private nonisolated static func holdForTests() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--hold-router") { Thread.sleep(forTimeInterval: 60) }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            Group {
                switch ready {
                case let .success(ready): ExploreView(graph: ready.graph, router: ready.router, search: ready.search)
                case let .failure(error): ContentUnavailableView("Seattle data unavailable", systemImage: "map", description: Text(error.localizedDescription))
                }
            }
            .tint(.calmer)
        }
    }
}

extension UIColor {
    private static func hex(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? hex(dark) : hex(light) }
    }
    /// The one accent: the calmer route.
    static let calmer = dynamic(light: 0x248A3D, dark: 0x30D158)
    /// The accent in small text, a shade darker in light mode to keep 4.5:1 contrast.
    static let calmerText = dynamic(light: 0x1F7A3A, dark: 0x30D158)
    static let fastest = hex(0x8E8E93)
    /// Directions button: a shade darker than the accent in light mode so white text keeps its contrast.
    static let directionsFill = dynamic(light: 0x1F7A3A, dark: 0x30D158)
    static let directionsText = dynamic(light: 0xFFFFFF, dark: 0x000000)
    /// System backgrounds at the elevated level, as in a sheet, so the panel lifts off a black map in dark mode.
    static let panel = elevated(.systemBackground)
    static let panelFill = elevated(.secondarySystemBackground)
    private static func elevated(_ color: UIColor) -> UIColor {
        UIColor { color.resolvedColor(with: UITraitCollection(traitsFrom: [$0, UITraitCollection(userInterfaceLevel: .elevated)])) }
    }
    /// Category badge fills (Docs/DESIGN.md section 2). Only place badges use them, never text, glass or buttons.
    static func categoryFill(_ group: PlaceCategory) -> UIColor {
        switch group {
        case .food: dynamic(light: 0xC75300, dark: 0xFF9F0A)
        case .coffee: dynamic(light: 0x8A5A2B, dark: 0xC8935A)
        case .nightlife: dynamic(light: 0x8E3FC0, dark: 0xBF5AF2)
        case .shops: dynamic(light: 0x4B49C8, dark: 0x7D7AFF)
        case .parks: dynamic(light: 0x0B7A6B, dark: 0x3CC9B0)
        case .sport: dynamic(light: 0x00728F, dark: 0x40C8E0)
        case .transit: dynamic(light: 0x0064D2, dark: 0x409CFF)
        case .sights: dynamic(light: 0xC2185B, dark: 0xFF6482)
        case .health: dynamic(light: 0xD70015, dark: 0xFF6961)
        case .services: dynamic(light: 0x6C6C70, dark: 0xAEAEB2)
        }
    }
    /// The glyph on a category fill: white in light mode, near-black in dark mode where the fills are brighter.
    static let categoryGlyph = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let mapLand = dynamic(light: 0xF2F2F2, dark: 0x1A1A1C)
    static let mapStreet = dynamic(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let mapArterial = dynamic(light: 0xE3DDCF, dark: 0x46423A)
    static let mapWater = dynamic(light: 0xD7E6EC, dark: 0x17303A)
    static let mapPark = dynamic(light: 0xDCE8D6, dark: 0x1E2A21)
    static let mapPath = dynamic(light: 0xC9D4C3, dark: 0x34403A)
}

extension ShapeStyle where Self == Color {
    static var calmer: Color { Color(uiColor: .calmer) }
    static var calmerText: Color { Color(uiColor: .calmerText) }
    static var directionsFill: Color { Color(uiColor: .directionsFill) }
    static var directionsText: Color { Color(uiColor: .directionsText) }
    static var fastest: Color { Color(uiColor: .fastest) }
    static var panel: Color { Color(uiColor: .panel) }
    static var panelFill: Color { Color(uiColor: .panelFill) }
}

extension Color {
    static func categoryFill(_ group: PlaceCategory) -> Color { Color(uiColor: .categoryFill(group)) }
    static var categoryGlyph: Color { Color(uiColor: .categoryGlyph) }
}

/// One set of short, physical timings for every screen, like Apple Maps. Reduce Motion keeps crossfades and drops
/// movement; UI tests run without animation so a view is gone the moment its state says so.
enum Motion {
    static let off: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        return false
        #endif
    }()
    /// Panels, cards and sheets entering, leaving or resizing.
    static func panel(_ reduce: Bool) -> Animation? { off ? nil : reduce ? .easeInOut(duration: 0.2) : .snappy(duration: 0.35) }
    /// Content changing in place: route states, numbers, instructions.
    static func content(_ reduce: Bool) -> Animation? { off ? nil : reduce ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3) }
    /// Slides in from an edge; a plain crossfade with Reduce Motion.
    static func edge(_ edge: Edge, reduce: Bool) -> AnyTransition { reduce ? .opacity : .move(edge: edge).combined(with: .opacity) }
    /// Map camera moves, in seconds; 0 cuts straight to the new view.
    static func camera(_ reduce: Bool, _ duration: TimeInterval = 0.5) -> TimeInterval { off || reduce ? 0 : duration }
}

#if DEBUG
struct SlowTestRouter: RouteComputing {
    let base: any RouteComputing
    func compare(_ request: RouteRequest) async throws -> RouteComparison {
        try await Task.sleep(for: .milliseconds(ProcessInfo.processInfo.arguments.contains("--slow-routing") ? 3000 : 150))
        return try await base.compare(request)
    }
}
#endif
