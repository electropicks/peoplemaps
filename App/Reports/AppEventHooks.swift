import UIKit
import PeoplemapsCore

/// App-level sources for `AppEvents` (Core/AppEvents.swift). Only the app's own signals: no OSLog, MapLibre or Ferrostar logs.
enum AppEventHooks {
    @MainActor private static var started = false

    @MainActor static func start() {
        guard !started else { return }
        started = true
        AppEvents.shared.log(.data, "app launched")
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            AppEvents.shared.log(.error, "memory warning")
        }
    }
}
