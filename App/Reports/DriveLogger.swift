import Foundation
import UIKit
import PeoplemapsCore
@preconcurrency import FerrostarCoreFFI

/// The opt-in detailed log (`Core/DriveLog.swift`, Docs/REPORTS.md section 11): every call here does nothing unless the
/// "Keep a detailed log" switch in About is on, and then only writes to the phone. The rest of the app calls this one type,
/// so the feature stays easy to remove. Nothing here touches the network.
@MainActor
enum DriveLogger {
    static let enabledKey = "driveLogEnabled"
    static let log = DriveLog(folder: AppFiles.folder("drive-log"))
    private static var defaults: UserDefaults { ExploreView.voiceStore }
    static var enabled: Bool { defaults.bool(forKey: enabledKey) }

    /// The trip being written; nil when the switch was off at Start, so nothing is held in memory.
    private(set) static var trip: DriveLog.TripWriter?
    private static var lastFix: Date?
    private static var observers: [NSObjectProtocol] = []

    /// UI tests start with the switch off, like a fresh install, unless a test keeps its settings.
    static let resetForUITests: () -> Void = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), !arguments.contains("--keep-saved") { defaults.removeObject(forKey: enabledKey) }
        #endif
        return {}
    }()

    /// The 3-minute rule, except that a UI test can keep a short simulated trip with `--drive-log-keep-short`.
    private static var minimumTripSeconds: TimeInterval {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--drive-log-keep-short") { return 0 }
        #endif
        return DriveLog.minimumTripSeconds
    }

    // MARK: Trips

    static func startTrip(_ comparison: RouteComparison, calmer: Bool) {
        endTrip(reason: "replaced")
        guard enabled else { return }
        let request = comparison.request
        func record(_ label: String, _ route: PeoplemapsCore.Route, _ calm: CalmScore?) -> DriveLog.RouteRecord {
            .init(label: label, route: route, plan: route.navigationPlan(mode: request.mode), calm: calm)
        }
        let info = Bundle.main.infoDictionary
        let header = DriveLog.Header(
            start: Date(), mode: request.mode, appVersion: info?["CFBundleShortVersionString"] as? String ?? "?", appBuild: info?["CFBundleVersion"] as? String ?? "?",
            dataVersion: ReportCenter.shared.context?.dataVersion ?? "unknown",
            request: .init(request, snappedOrigin: comparison.snappedOrigin, snappedDestination: comparison.snappedDestination),
            startedWith: calmer ? "calmer" : "fastest", calmerOffered: comparison.calmer != nil,
            routes: [record("fastest", comparison.fastest, comparison.fastestCalm)] + (comparison.calmer.map { [record("calmer", $0, comparison.calmerCalm)] } ?? []))
        guard let writer = try? log.startTrip(header, enabled: true) else { return }
        trip = writer; lastFix = nil
        event("device", systemState())
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { event("device", systemState()) }
            },
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { event("device", systemState()) }
            },
        ]
    }

    private static func systemState() -> [String: DriveLog.Value] {
        let thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        return ["thermal": .string(thermal), "lowPower": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)]
    }

    /// Writes the end line, closes the file, deletes a trip under the minimum length, and trims the folder to its cap.
    static func endTrip(reason: String) {
        guard let writer = trip else { return }
        trip = nil; lastFix = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        writer.finish(reason: reason, minimumSeconds: minimumTripSeconds)
        log.enforceCap()
    }

    static func fix(_ location: UserLocation) {
        guard let trip, lastFix != location.timestamp else { return }
        lastFix = location.timestamp
        trip.fix(.init(t: location.timestamp, lat: location.coordinates.lat, lon: location.coordinates.lng, accuracy: location.horizontalAccuracy,
                       speed: location.speed?.value, speedAccuracy: location.speed?.accuracy,
                       course: location.courseOverGround.map { Double($0.degrees) }, courseAccuracy: location.courseOverGround?.accuracy.map(Double.init)))
    }

    /// One moment in the trip. The values are only built when a trip is being written.
    static func event(_ name: String, _ data: @autoclosure () -> [String: DriveLog.Value] = [:]) {
        trip?.event(name, data())
    }

    // MARK: App use

    /// One line in today's app-use file.
    static func use(_ name: String, _ data: @autoclosure () -> [String: DriveLog.Value] = [:]) {
        guard enabled else { return }
        log.appendUse(name, data(), enabled: true)
    }
}

extension DriveLog.Value {
    static func text(_ s: String?) -> Self { s.map(Self.string) ?? .string("") }
    static func num(_ x: Double) -> Self { .number((x * 10).rounded() / 10) }
    static func num(_ x: Int) -> Self { .number(Double(x)) }
}
