import SwiftUI
import PeoplemapsCore

@main
struct PeoplemapsApp: App {
    @State private var loaded: (graph: StreetGraph, router: NativeRouter)?
    @State private var error: String?
    var body: some Scene {
        WindowGroup {
            Group {
                if let loaded { ExploreView(graph: loaded.graph, router: loaded.router) }
                else if let error { ContentUnavailableView("Seattle data unavailable", systemImage: "map", description: Text(error)) }
                else {
                    ProgressView("Opening Seattle…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .mapLand), ignoresSafeAreaEdges: .all)
                        .task { await load() }
                }
            }
            .tint(.calmer)
        }
    }
    private func load() async {
        do {
            loaded = try await Task.detached {
                let graph = try StreetGraph.bundled()
                return (graph, NativeRouter(graph: graph))
            }.value
        }
        catch { self.error = error.localizedDescription }
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
    let base: NativeRouter
    func compare(_ request: RouteRequest) async throws -> RouteComparison {
        try await Task.sleep(for: .milliseconds(ProcessInfo.processInfo.arguments.contains("--slow-routing") ? 3000 : 150))
        return try await base.compare(request)
    }
}
#endif
