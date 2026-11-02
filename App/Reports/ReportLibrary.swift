import Foundation
import Observation
import PeoplemapsCore

/// Problem reports on the phone, written to Application Support after every change, until the user swipes them away.
@MainActor @Observable
final class ReportLibrary {
    static let shared = ReportLibrary()
    private(set) var store: ProblemReports
    private let url: URL

    private init() {
        url = AppFiles.url("problem-reports")
        store = ProblemReports.load(from: url)
    }

    var reports: [ProblemReport] { store.reports }
    subscript(id: String) -> ProblemReport? { store[id] }

    func save(_ report: ProblemReport) { store.save(report); try? store.save(to: url) }
    func remove(id: String) { store.remove(id: id); try? store.save(to: url) }
}

/// Files the reports and the usage log keep in Application Support. UI tests get their own, emptied at launch unless
/// a test checks that something survives a relaunch.
enum AppFiles {
    static func url(_ name: String, ext: String = "json") -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var file = name
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") {
            file += "-uitests"
            if !arguments.contains("--keep-saved") { try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(file).\(ext)")) }
        }
        #endif
        return folder.appendingPathComponent("\(file).\(ext)")
    }
}

/// The opt-in usage log (`Core/UsageLog.swift`). Off unless the user turns it on in About; nothing here touches the network.
@MainActor
enum UsageLogger {
    static let enabledKey = "usageLogEnabled", exactKey = "usageLogExact"
    static let log = UsageLog(url: AppFiles.url("usage-log", ext: "jsonl"))
    private static var defaults: UserDefaults { ExploreView.voiceStore }
    static var enabled: Bool { defaults.bool(forKey: enabledKey) }
    static var exact: Bool { defaults.bool(forKey: exactKey) }

    /// What a trip knows while it runs; `record` rounds the departures and writes the line.
    struct Draft {
        var at = Date()
        var mode: TravelMode
        var extraMinutes: Int
        var started: Report.Chosen
        var fastest: UsageLog.Estimate
        var calmer: UsageLog.Estimate?
        var offered: Bool
        var reroutes = 0
        var departures: [Coordinate] = []

        init(comparison: RouteComparison, started: Report.Chosen) {
            mode = comparison.request.mode; extraMinutes = comparison.request.extraMinutes; self.started = started
            fastest = .init(minutes: comparison.fastest.minutes, meters: comparison.fastest.metrics.meters.rounded())
            calmer = comparison.calmer.map { .init(minutes: $0.minutes, meters: $0.metrics.meters.rounded()) }
            offered = comparison.calmer != nil
        }
    }

    /// UI tests start with the log off, like a fresh install, unless a test keeps its settings.
    static let resetForUITests: () -> Void = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), !arguments.contains("--keep-saved") {
            defaults.removeObject(forKey: enabledKey); defaults.removeObject(forKey: exactKey)
        }
        #endif
        return {}
    }()

    static func record(_ draft: Draft, ended: UsageLog.Ended) {
        let exact = exact
        let trip = UsageLog.Trip(at: draft.at, mode: draft.mode, extraMinutes: draft.extraMinutes, started: draft.started, fastest: draft.fastest,
                                 calmer: draft.calmer, calmerOffered: draft.offered, reroutes: draft.reroutes,
                                 departures: draft.departures.map { UsageLog.point(lat: $0.lat, lon: $0.lon, exact: exact) }, ended: ended)
        try? log.append(trip, enabled: enabled)
    }
}
