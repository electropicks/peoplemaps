import Foundation
import Observation
import PeoplemapsCore

/// What the two trip logs hold right now, and the files Share hands over. Settings owns one and its pages read it; the logs
/// themselves are `UsageLogger` and `DriveLogger`.
@MainActor @Observable
final class TripLogs {
    private(set) var usageTrips = 0
    private(set) var usageFile: URL?
    private(set) var detailed = DriveLog.Summary(trips: 0, bytes: 0)
    private(set) var detailedFiles: [URL] = []

    /// The counts alone: cheap enough for the root list.
    func refresh() {
        usageTrips = UsageLogger.log.count
        detailed = DriveLogger.log.summary()
    }

    /// Writes the usage log to a dated file for Share.
    func prepareUsageShare() {
        refresh()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usage-log", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        guard usageTrips > 0 else { usageFile = nil; return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let day = Date().formatted(.iso8601.year().month().day())
        let url = folder.appendingPathComponent("peoplemaps-usage-log-\(day).jsonl")
        usageFile = (try? UsageLogger.log.data().write(to: url)) != nil ? url : nil
    }

    /// Copies the detailed log's files for Share. Copies on this volume are clones, so a large log costs no space or time.
    func prepareDetailedShare() {
        refresh()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drive-log", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        guard detailed.bytes > 0 else { detailedFiles = []; return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        detailedFiles = DriveLogger.log.allFiles().compactMap { url in
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            return (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : nil
        }
    }

    func clearUsage() { UsageLogger.log.clear(); prepareUsageShare() }
    func clearDetailed() { DriveLogger.log.clear(); prepareDetailedShare() }

    // MARK: Words

    var usageKept: String { Self.trips(usageTrips) }
    /// "2 trips, 1 recording, 1.4 MB". An empty log is "0 trips": it has no size worth printing.
    var detailedKept: String {
        var parts = [Self.trips(detailed.trips)]
        if detailed.recordings > 0 { parts.append("\(detailed.recordings) \(detailed.recordings == 1 ? "recording" : "recordings")") }
        if detailed.bytes > 0 { parts.append(Self.size(detailed.bytes)) }
        return parts.joined(separator: ", ")
    }
    /// The root row's value: "Off", "On", or with what is kept, "On · 3 trips".
    func usageState(on: Bool) -> String { Self.state(on, kept: usageTrips > 0 ? usageKept : nil) }
    /// "On · 2 trips, 1.4 MB". Short for the root row: recordings are named only when there are no trips, and the size from 1 MB up.
    func detailedState(on: Bool) -> String {
        guard detailed.trips > 0 || detailed.recordings > 0 else { return Self.state(on, kept: nil) }
        let count = detailed.trips > 0 ? Self.trips(detailed.trips) : "\(detailed.recordings) \(detailed.recordings == 1 ? "recording" : "recordings")"
        return Self.state(on, kept: count + (detailed.bytes >= 1_000_000 ? ", \(Self.size(detailed.bytes))" : ""))
    }

    private static func trips(_ n: Int) -> String { "\(n) \(n == 1 ? "trip" : "trips")" }
    /// "1.4 MB", "12 KB", and "under 1 KB" where the formatter would count bytes.
    private static func size(_ bytes: Int) -> String {
        guard bytes >= 1000 else { return "under 1 KB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }
    private static func state(_ on: Bool, kept: String?) -> String { (on ? "On" : "Off") + (kept.map { " \u{00B7} \($0)" } ?? "") }
}
