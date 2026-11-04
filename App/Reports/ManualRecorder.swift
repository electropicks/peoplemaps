import CoreLocation
import UIKit
import PeoplemapsCore

/// A recording the owner starts and stops by hand, with no route running (Docs/REPORTS.md section 11). It has its own location
/// manager, so it keeps writing fixes in the background after a start in the foreground: When-In-Use is enough, with the
/// `location` background mode and the system's blue indicator. Lines go to `rec-<UTC start>.jsonl` in the detailed log's folder.
/// It only starts while "Keep a detailed log" is on, and never resumes by itself after the app was killed.
@MainActor @Observable
final class ManualRecorder: NSObject, CLLocationManagerDelegate {
    static let shared = ManualRecorder()
    /// The open file's name, kept so the next launch can close a recording the system killed.
    static let openFileKey = "manualRecordingOpenFile"
    private static var defaults: UserDefaults { ExploreView.voiceStore }

    private(set) var startedAt: Date?
    var isRecording: Bool { startedAt != nil }

    @ObservationIgnored private let permission = LocationPermission()
    @ObservationIgnored private lazy var manager = CLLocationManager()
    @ObservationIgnored private var writer: DriveLog.TripWriter?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var simulator: Task<Void, Never>?

    /// Asks for When-In-Use if nobody has answered, then starts. False when location is off or the detailed log is.
    @discardableResult
    func start() async -> Bool {
        guard DriveLogger.enabled, !isRecording else { return isRecording }
        guard await permission.request() == .granted, !isRecording, DriveLogger.enabled else { return false }
        let info = Bundle.main.infoDictionary
        let header = DriveLog.RecordingHeader(
            start: Date(), appVersion: info?["CFBundleShortVersionString"] as? String ?? "?", appBuild: info?["CFBundleVersion"] as? String ?? "?",
            dataVersion: ReportCenter.shared.context?.dataVersion ?? "unknown")
        guard let opened = try? DriveLogger.log.startRecording(header, enabled: true) else { return false }
        writer = opened
        Self.defaults.set(opened.url.lastPathComponent, forKey: Self.openFileKey)
        startedAt = header.startDate
        event("device", DriveLogger.systemState())
        event("authorization", ["status": .string(Self.name(manager.authorizationStatus))])
        observe()
        beginUpdates()
        return true
    }

    /// Writes the end line, closes the file, deletes a recording under 3 minutes, and trims the folder to its cap.
    func stop(reason: String = "user") {
        guard let writer else { return }
        self.writer = nil; startedAt = nil
        simulator?.cancel(); simulator = nil
        manager.stopUpdatingLocation()
        manager.delegate = nil
        manager.allowsBackgroundLocationUpdates = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        writer.finish(reason: reason, minimumSeconds: DriveLogger.minimumTripSeconds)
        Self.defaults.removeObject(forKey: Self.openFileKey)
        DriveLogger.log.enforceCap()
    }

    /// A recording still marked open at launch was cut off by the system or a crash: close it with reason `terminated`.
    func closeLeftOpen() {
        guard !isRecording, let name = Self.defaults.string(forKey: Self.openFileKey) else { return }
        Self.defaults.removeObject(forKey: Self.openFileKey)
        DriveLogger.log.closeOrphan(named: name, reason: "terminated", minimumSeconds: DriveLogger.minimumTripSeconds)
    }

    // MARK: Updates

    private func beginUpdates() {
        #if DEBUG
        // UI tests have no location source: one fix a second at the faked spot, so a short recording has something in it.
        if let spot = LocationPermission.fakeCoordinate {
            simulator = Task { [weak self] in
                while !Task.isCancelled {
                    self?.write(CLLocation(coordinate: spot, altitude: 50, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3, timestamp: Date()))
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            return
        }
        #endif
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    private func observe() {
        let center = NotificationCenter.default
        func watch(_ name: Notification.Name, _ body: @escaping @MainActor () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated(body) })
        }
        watch(UIApplication.didEnterBackgroundNotification) { [weak self] in self?.event("background") }
        watch(UIApplication.willEnterForegroundNotification) { [weak self] in self?.event("foreground") }
        watch(ProcessInfo.thermalStateDidChangeNotification) { [weak self] in self?.event("device", DriveLogger.systemState()) }
        watch(.NSProcessInfoPowerStateDidChange) { [weak self] in self?.event("device", DriveLogger.systemState()) }
    }

    private func event(_ name: String, _ data: [String: DriveLog.Value] = [:]) { writer?.event(name, data) }

    private func write(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0 else { return }
        writer?.fix(.init(t: location.timestamp, lat: location.coordinate.latitude, lon: location.coordinate.longitude, accuracy: location.horizontalAccuracy,
                          speed: location.speed >= 0 ? location.speed : nil, speedAccuracy: location.speedAccuracy >= 0 ? location.speedAccuracy : nil,
                          course: location.course >= 0 ? location.course : nil, courseAccuracy: location.courseAccuracy >= 0 ? location.courseAccuracy : nil))
    }

    private nonisolated static func name(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedWhenInUse: "whenInUse"
        case .authorizedAlways: "always"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in locations.forEach(self.write) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = Self.name(manager.authorizationStatus)
        Task { @MainActor in self.event("authorization", ["status": .string(status)]) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = (error as NSError).localizedDescription
        Task { @MainActor in self.event("location_error", ["message": .string(message)]) }
    }
}
