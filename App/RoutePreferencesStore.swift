import Foundation
import Observation
import PeoplemapsCore

/// What the person minds in each travel mode, kept in UserDefaults as one JSON value per mode.
@MainActor @Observable
final class RoutePreferencesStore {
    private var all: [TravelMode: RoutePreferences]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? Self.defaultStore()
        self.defaults = defaults
        var loaded: [TravelMode: RoutePreferences] = [:]
        for mode in TravelMode.allCases {
            if let data = defaults.data(forKey: Self.key(mode)), let value = try? JSONDecoder().decode(RoutePreferences.self, from: data) { loaded[mode] = value }
        }
        all = loaded
    }

    /// Each mode keeps its own preferences, so a hill you avoid on a bike doesn't change your drive.
    subscript(_ mode: TravelMode) -> RoutePreferences {
        get { all[mode] ?? .default(for: mode) }
        set {
            all[mode] = newValue
            if newValue == RoutePreferences() { defaults.removeObject(forKey: Self.key(mode)) }
            else if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key(mode)) }
        }
    }

    private static func key(_ mode: TravelMode) -> String { "routePreferences.\(mode.rawValue)" }

    /// UI tests get their own defaults, cleared at launch unless a test checks that something survives a relaunch.
    private static func defaultStore() -> UserDefaults {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), let store = UserDefaults(suiteName: "peoplemaps.uitests") {
            if !arguments.contains("--keep-saved") { for mode in TravelMode.allCases { store.removeObject(forKey: key(mode)) } }
            return store
        }
        #endif
        return .standard
    }
}
