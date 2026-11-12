import SwiftUI
import TipKit
import PeoplemapsCore

/// The launch data, loaded off the selected region (`RegionSelection`) and rebuilt on Switch now.
@MainActor @Observable
final class AppData {
    typealias Loaded = (graph: StreetGraph, router: DeferredRouter, search: SearchIndex)
    /// Home needs only the graph's bounds and search; the router builds behind it and routing requests wait for it.
    private(set) var loaded: Result<Loaded, Error>
    /// Changes when the data does, so the screen is rebuilt on the new map.
    private(set) var generation = 0

    init() { loaded = Self.load() }

    /// A downloaded region that fails to load is dropped for this launch and Seattle is loaded instead.
    private static func load() -> Result<Loaded, Error> {
        var result = attempt()
        if case let .failure(error) = result, RegionSelection.launchFolder != nil {
            AppEvents.shared.log(.error, "downloaded region failed to load", error: error)
            RegionSelection.suppress()
            result = attempt()
        }
        if case let .failure(error) = result { AppEvents.shared.log(.error, "bundled data failed to load", error: error) }
        return result
    }

    private static func attempt() -> Result<Loaded, Error> {
        Result {
            let header = try AppEvents.shared.timed(.data, "graph header loaded") { try StreetGraph.bundledHeader() }
            let router = DeferredRouter { holdForTests(); return try AppEvents.shared.timed(.data, "router ready") { NativeRouter(graph: try StreetGraph.bundled()) } }
            return (header.boundsOnly, router, try AppEvents.shared.timed(.data, "search index loaded") { try SearchIndex.bundled(graphNodes: header.nodes) })
        }
    }

    /// Loads whatever `RegionSelection` now points at. Only called with no route shown and no guidance running.
    func reload() {
        loaded = Self.load()
        generation += 1
    }

    /// UI tests pass `--hold-router` to keep the router from being ready, proving home never waits for it.
    private nonisolated static func holdForTests() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--hold-router") { Thread.sleep(forTimeInterval: 60) }
        #endif
    }
}

/// Lets the system hand the app the finish of region downloads it kept going while the app was suspended or gone.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == RegionStore.backgroundIdentifier else { return completionHandler() }
        nonisolated(unsafe) let finish = completionHandler   // the store calls it on the main thread
        RegionStore.setBackgroundCompletion { finish() }
    }
}

@main
struct PeoplemapsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var data: AppData
    @State private var regions: RegionModel
    init() {
        Self.isolateRegionsForUITests()
        AppEventHooks.start()
        Self.configureTips()
        let data = AppData(), regions = RegionModel.make()
        regions.reload = { [weak data] in data?.reload() }
        _data = State(initialValue: data)
        _regions = State(initialValue: regions)
    }
    /// UI tests keep downloaded regions in a folder of their own, emptied at each launch (`--keep-regions` keeps it), so they never touch the real ones.
    private static func isolateRegionsForUITests() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing") else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ui-test-regions", isDirectory: true)
        if !arguments.contains("--keep-regions") { try? FileManager.default.removeItem(at: folder) }
        RegionSelection.configure(root: folder)
        #endif
    }
    /// Tips show as soon as they apply. UI tests start with none dismissed, so each launch shows the same ones.
    private static func configureTips() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { try? Tips.resetDatastore() }
        #endif
        try? Tips.configure([.displayFrequency(.immediate)])
    }
    var body: some Scene {
        WindowGroup {
            Group {
                switch data.loaded {
                case let .success(ready): ExploreView(graph: ready.graph, router: ready.router, search: ready.search).id(data.generation)
                case let .failure(error): ContentUnavailableView("Map data unavailable", systemImage: "map", description: Text(error.localizedDescription))
                }
            }
            .environment(regions)
            .task { await regions.start() }
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
    private static func dynamic(light: UInt32, lightAlpha: CGFloat, dark: UInt32, darkAlpha: CGFloat) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? hex(dark).withAlphaComponent(darkAlpha) : hex(light).withAlphaComponent(lightAlpha) }
    }
    /// The calmer route's line, the selected place and the route's end: dusk blue, muted so it sits in the map. Never a control colour.
    static let calmer = dynamic(light: 0x4A6F97, dark: 0x7FA3CC)
    /// The fastest route's dotted line.
    static let fastest = dynamic(light: 0x6B7872, dark: 0xAEBAB3)
    /// The part of the followed route already driven: a muted blue-grey, drawn thinner.
    static let passedRoute = dynamic(light: 0xA6B3C0, dark: 0x53616F)
    /// The user's marker and the Current location badge.
    static let userLocation = hex(0x4A8FD6)
    /// Start, Directions, Done and Share report: the one filled control on a screen, with white words. In light mode the label's slate;
    /// white at 72% on the pale sheet did not read as a button. In dark mode dusk blue, the hue the switches take: a lifted grey was no
    /// clearer there, and white at 86% was a slab brighter than anything else on the card (owner's phone, 9 November 2026).
    /// Swap these to change the primary action everywhere.
    static let primaryActionFill = dynamic(light: 0x20384F, dark: 0x4A6F97)
    static let primaryActionText = hex(0xFFFFFF)
    /// Laid over the glass of a panel, so text holds its contrast over a busy map. Neutral: glass is never tinted a hue.
    static let glassVeil = dynamic(light: 0xFFFFFF, lightAlpha: 0.34, dark: 0x101412, darkAlpha: 0.5)
    /// The heavier veil for a surface read at length, or at a glance while driving.
    static let glassVeilDense = dynamic(light: 0xFFFFFF, lightAlpha: 0.72, dark: 0x101412, darkAlpha: 0.72)
    /// Hairlines between the rows of a panel, the track under a rating, the well behind the modes, and the chosen mode.
    static let glassHairline = dynamic(light: 0x142D23, lightAlpha: 0.14, dark: 0xFFFFFF, darkAlpha: 0.14)
    static let glassTrack = dynamic(light: 0x142D23, lightAlpha: 0.14, dark: 0xFFFFFF, darkAlpha: 0.20)
    static let glassWell = dynamic(light: 0x142D23, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.08)
    static let glassChosen = dynamic(light: 0xFFFFFF, lightAlpha: 0.72, dark: 0xFFFFFF, darkAlpha: 0.20)
    /// System backgrounds at the elevated level, as in a sheet, so the panel lifts off a black map in dark mode.
    static let panel = elevated(.systemBackground)
    static let panelFill = elevated(.secondarySystemBackground)
    private static func elevated(_ color: UIColor) -> UIColor {
        UIColor { color.resolvedColor(with: UITraitCollection(traitsFrom: [$0, UITraitCollection(userInterfaceLevel: .elevated)])) }
    }
    /// Category badge fills (Docs/DESIGN.md section 2): muted, so markers sit in the map. Only place badges use them, never text, glass or buttons.
    static func categoryFill(_ group: PlaceCategory) -> UIColor {
        switch group {
        case .food: dynamic(light: 0xBE6E46, dark: 0xE09A72)
        case .coffee: dynamic(light: 0x927050, dark: 0xC8A583)
        case .nightlife: dynamic(light: 0x8C64A0, dark: 0xBC97CF)
        case .shops: dynamic(light: 0x646CB0, dark: 0x9BA2DB)
        case .parks: dynamic(light: 0x48886C, dark: 0x7DBD9F)
        case .sport: dynamic(light: 0x3F8A8F, dark: 0x74BCC1)
        case .transit: dynamic(light: 0x428096, dark: 0x78B3C8)
        case .sights: dynamic(light: 0xB0607C, dark: 0xDB93AD)
        case .health: dynamic(light: 0xB85F60, dark: 0xE29A9A)
        case .services: dynamic(light: 0x77797C, dark: 0xADAFB2)
        }
    }
    /// A rating's bar: muted and distinct from each other. Not green to red, so it doesn't read as safe and unsafe.
    static func calmFill(_ level: CalmLevel) -> UIColor {
        switch level {
        case .breezy: hex(0x7FB2D6)
        case .chill: hex(0x6FAFA8)
        case .mixed: hex(0xB8AE9A)
        case .spicy: hex(0xD19A6B)
        case .yikes: hex(0xCF8A88)
        }
    }
    /// A rating's word: the same hue as its bar, dark or light enough for 4.5:1 on glass over any part of the map.
    static func calmWord(_ level: CalmLevel) -> UIColor {
        switch level {
        case .breezy: dynamic(light: 0x285A7E, dark: 0xA3D0F0)
        case .chill: dynamic(light: 0x1F5F5A, dark: 0x93D8D0)
        case .mixed: dynamic(light: 0x5F5646, dark: 0xD3CBB8)
        case .spicy: dynamic(light: 0x84491A, dark: 0xF0BE8F)
        case .yikes: dynamic(light: 0x8C3B39, dark: 0xF0AFAD)
        }
    }
    /// The glyph on a category fill: white in light mode, near-black in dark mode where the fills are lighter.
    static let categoryGlyph = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let mapLand = dynamic(light: 0xF1F2EC, dark: 0x1A2421)
    static let mapStreet = dynamic(light: 0xFBFBF8, dark: 0x2C3A35)
    static let mapArterial = dynamic(light: 0xEFE5C6, dark: 0x4A4631)
    static let mapWater = dynamic(light: 0xB9D5DF, dark: 0x24454F)
    static let mapPark = dynamic(light: 0xCCDFCF, dark: 0x27463A)
    static let mapPath = dynamic(light: 0xC9D4C3, dark: 0x33423B)
    static let mapLabel = dynamic(light: 0x4F6359, dark: 0xBDCBC3)
    static let mapWaterLabel = dynamic(light: 0x3D6878, dark: 0xB4D3DE)
}

extension ShapeStyle where Self == Color {
    static var calmer: Color { Color(uiColor: .calmer) }
    static var fastest: Color { Color(uiColor: .fastest) }
    static var primaryActionFill: Color { Color(uiColor: .primaryActionFill) }
    static var primaryActionText: Color { Color(uiColor: .primaryActionText) }
    static var panel: Color { Color(uiColor: .panel) }
    static var panelFill: Color { Color(uiColor: .panelFill) }
    static var glassHairline: Color { Color(uiColor: .glassHairline) }
    static var glassTrack: Color { Color(uiColor: .glassTrack) }
    static var glassWell: Color { Color(uiColor: .glassWell) }
    static var glassChosen: Color { Color(uiColor: .glassChosen) }
}

extension Color {
    static func categoryFill(_ group: PlaceCategory) -> Color { Color(uiColor: .categoryFill(group)) }
    static var categoryGlyph: Color { Color(uiColor: .categoryGlyph) }
    static func calmFill(_ level: CalmLevel) -> Color { Color(uiColor: .calmFill(level)) }
    static func calmWord(_ level: CalmLevel) -> Color { Color(uiColor: .calmWord(level)) }
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
