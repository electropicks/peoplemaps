import CoreLocation

/// Asks for "when in use" location once the map shows on first launch, so routes can start from where the user is.
/// Start and "Current location" check again. Ferrostar's own provider would ask by itself the moment it is created,
/// so we ask first and create it only once access is granted.
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    enum Access { case granted, undecided, denied }

    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<Access, Never>?
    private var locating: [CheckedContinuation<CLLocationCoordinate2D?, Never>] = []

    #if DEBUG
    /// UI tests answer for the system: `--location-granted LAT,LON` allows location at that spot; without it,
    /// `--ui-testing` counts as denied, so no prompt interrupts a test. `--real-location` asks Core Location for real.
    private static let fake: (access: Access, at: CLLocationCoordinate2D?)? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing"), !arguments.contains("--real-location") else { return nil }
        if let i = arguments.firstIndex(of: "--location-granted"), i + 1 < arguments.count {
            let p = arguments[i + 1].split(separator: ",").compactMap { Double($0) }
            if p.count == 2 { return (.granted, CLLocationCoordinate2D(latitude: p[0], longitude: p[1])) }
        }
        return (.denied, nil)
    }()
    #else
    private static let fake: (access: Access, at: CLLocationCoordinate2D?)? = nil
    #endif

    var access: Access { Self.fake?.access ?? Self.access(manager.authorizationStatus) }

    private static func access(_ status: CLAuthorizationStatus) -> Access {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: .granted
        case .notDetermined: .undecided
        default: .denied
        }
    }

    /// Shows the system prompt if the choice has not been made, and returns the answer.
    func request() async -> Access {
        guard Self.fake == nil, access == .undecided else { return access }
        manager.delegate = self
        return await withCheckedContinuation { continuation in
            waiting = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    /// One fix of where the device is, or nil without access or when Core Location cannot tell.
    func currentCoordinate() async -> CLLocationCoordinate2D? {
        if let fake = Self.fake { return fake.at }
        guard access == .granted else { return nil }
        manager.delegate = self
        return await withCheckedContinuation { continuation in
            locating.append(continuation)
            if locating.count == 1 { manager.requestLocation() }
        }
    }

    private func finishLocating(_ coordinate: CLLocationCoordinate2D?) {
        let waiting = locating
        locating = []
        waiting.forEach { $0.resume(returning: coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in self.finishLocating(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishLocating(nil) }
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
