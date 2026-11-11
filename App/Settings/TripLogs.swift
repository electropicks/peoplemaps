import Foundation
import Observation
import SwiftUI
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

/// Send to PeopleMaps for one log (Docs/REPORTS.md 4.8): works out what is new, asks, then seals it and sends it to the Worker.
/// It keeps each send's delete secret, so Delete sent logs can take them off the server again. One per page.
@MainActor @Observable
final class LogSender {
    enum Phase: Equatable {
        case idle, checking, sending, sent, nothingNew, deleting
    }

    /// Why the last send or delete did not happen, for an alert.
    struct Failure: Equatable { var title: String; var message: String }
    var failure: Failure?

    private(set) var phase = Phase.idle
    /// What the confirmation offers; set once the check found something new.
    var pending: [LogFile] = []
    var confirming = false
    var confirmingDelete = false
    /// Sends that may still be on the server: under 30 days old and not deleted from here.
    private(set) var batches: [SentLogBatch] = []
    private let files: @MainActor () -> [URL]
    private let sentKey: String

    init(sentKey: String, files: @escaping @MainActor () -> [URL]) {
        self.sentKey = sentKey; self.files = files
        batches = loadBatches()
    }

    var busy: Bool { switch phase { case .checking, .sending, .deleting: true; default: false } }

    /// The Send row's trailing value once it is done. While it works the row shows the system's spinner, with no changing words.
    var status: String? {
        switch phase { case .sent: "Sent"; case .nothingNew: "Already sent"; default: nil }
    }
    /// Delete sent logs is offered once a send is over, so the list does not change under a send in progress.
    var offersDelete: Bool { !batches.isEmpty && phase != .checking && phase != .sending }

    /// "4 files, 2.1 MB".
    var pendingSummary: String {
        let n = pending.count
        return "\(n) \(n == 1 ? "file" : "files"), " + ByteCountFormatter.string(fromByteCount: Int64(pending.reduce(0) { $0 + $1.bytes }), countStyle: .file)
    }

    func check() {
        guard !busy else { return }
        phase = .checking
        let urls = files(), sent = sentHashes
        Task {
            let fresh = await Task.detached(priority: .userInitiated) { LogFile.unsent(urls, sent: sent) }.value
            pending = fresh
            if fresh.isEmpty { phase = .nothingNew } else { phase = .idle; confirming = true }
        }
    }

    func send() {
        let files = pending
        guard !files.isEmpty, !busy else { return }
        phase = .sending
        // Saved before the first byte goes, so a send that is cut off can still be deleted.
        let batch = SentLogBatch()
        save(batches + [batch])
        Task {
            do {
                try await Self.uploader.send(files, batch: batch) { file in
                    await MainActor.run { self.remember(file.sha256) }
                }
                withAnimation { phase = .sent }
            } catch let e as LogUploadError {
                // These stop before anything is sent, so there is nothing on the server to delete.
                if case .cannotAttest = e { save(batches.filter { $0.id != batch.id }) }
                if case .tooLarge = e { save(batches.filter { $0.id != batch.id }) }
                fail("Not Sent", Self.words(e))
            } catch {
                fail("Not Sent", Self.words(.unavailable))
            }
            pending = []
        }
    }

    private func fail(_ title: String, _ message: String) {
        withAnimation { phase = .idle }
        failure = Failure(title: title, message: message)
    }

    /// Takes every send this phone remembers off the server. A send that fails to delete is kept, to try again.
    func deleteSent() {
        guard !busy, !batches.isEmpty else { return }
        phase = .deleting
        Task {
            var left = batches, failure: LogUploadError?
            for batch in batches {
                do { try await Self.uploader.delete(batch); left.removeAll { $0.id == batch.id } }
                catch let e as LogUploadError { failure = e; break }
                catch { failure = .unavailable; break }
            }
            withAnimation { save(left) }
            // What was deleted may be sent again.
            if left.isEmpty { defaults.removeObject(forKey: sentKey) }
            if let failure { fail("Not Deleted", Self.words(failure, deleting: true)) } else { withAnimation { phase = .idle } }
        }
    }

    private var batchesKey: String { sentKey + ".batches" }
    private func loadBatches() -> [SentLogBatch] {
        let all = defaults.data(forKey: batchesKey).flatMap { try? JSONDecoder().decode([SentLogBatch].self, from: $0) } ?? []
        // Past the server's 30 days there is nothing left to delete.
        return all.filter { $0.sentAt > Date().addingTimeInterval(-31 * 86_400) }
    }
    private func save(_ next: [SentLogBatch]) {
        batches = next
        defaults.set(try? JSONEncoder().encode(next), forKey: batchesKey)
    }

    private static let uploader = LogUploader()
    private var defaults: UserDefaults { ExploreView.voiceStore }
    private var sentHashes: Set<String> { Set(defaults.stringArray(forKey: sentKey) ?? []) }
    /// The last 2,000 hashes: far more files than either log keeps.
    private func remember(_ hash: String) { defaults.set(Array(((defaults.stringArray(forKey: sentKey) ?? []) + [hash]).suffix(2000)), forKey: sentKey) }

    static func words(_ e: LogUploadError, deleting: Bool = false) -> String {
        if deleting {
            return e == .noConnection ? "No connection. The sent logs are still on the server; try again when you\u{2019}re online."
                : "The PeopleMaps server didn\u{2019}t delete the logs. Try again later."
        }
        return switch e {
        case .noConnection: "No connection. Try again when you\u{2019}re online."
        case let .tooLarge(name): "\(name) is over 25\u{00A0}MB, too large to send. Share it instead."
        case .busy: "The PeopleMaps server isn\u{2019}t taking logs right now. Try again later."
        case .unavailable: "The PeopleMaps server didn\u{2019}t take the log. Try again later, or share it instead."
        case .cannotAttest: "This device can\u{2019}t send logs. Share them instead."
        }
    }
}
