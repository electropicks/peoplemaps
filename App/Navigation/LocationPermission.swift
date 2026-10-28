import CoreLocation

/// Asks for "when in use" location, only when the user starts guidance. Ferrostar's own provider would ask by itself
/// the moment it is created, so we ask first and create it only once access is granted.
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    enum Access { case granted, undecided, denied }

    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<Access, Never>?

    var access: Access { Self.access(manager.authorizationStatus) }

    private static func access(_ status: CLAuthorizationStatus) -> Access {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: .granted
        case .notDetermined: .undecided
        default: .denied
        }
    }

    /// Shows the system prompt if the choice has not been made, and returns the answer.
    func request() async -> Access {
        guard access == .undecided else { return access }
        manager.delegate = self
        return await withCheckedContinuation { continuation in
            waiting = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let result = Self.access(status)
            guard result != .undecided, let waiting = self.waiting else { return }
            self.waiting = nil
            waiting.resume(returning: result)
        }
    }
}
