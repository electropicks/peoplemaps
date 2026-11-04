import SwiftUI
import PeoplemapsCore

/// The report and log sections of About: report a problem, reports kept on the phone, the usage log and the detailed log.
struct ReportsAboutSection: View {
    private let library = ReportLibrary.shared
    init() { UsageLogger.resetForUITests(); DriveLogger.resetForUITests() }
    @AppStorage(UsageLogger.enabledKey, store: ExploreView.voiceStore) private var logOn = false
    @AppStorage(UsageLogger.exactKey, store: ExploreView.voiceStore) private var logExact = false
    @State private var logFile: URL?
    @State private var tripCount = 0
    @State private var confirmClear = false
    @AppStorage(DriveLogger.enabledKey, store: ExploreView.voiceStore) private var driveOn = false
    @State private var driveFiles: [URL] = []
    @State private var driveSummary = DriveLog.Summary(trips: 0, bytes: 0)
    @State private var confirmClearDrive = false

    var body: some View {
        Section {
            Button { ReportCenter.shared.open(from: "about") } label: { Label("Report a problem", systemImage: "exclamationmark.bubble") }
                .accessibilityIdentifier("report-problem-about")
        } header: { header("Feedback") } footer: {
            Text("You can also shake the phone on any screen. In guidance, the flag button marks a moment to describe later.")
        }
        if !library.reports.isEmpty {
            Section {
                ForEach(library.reports) { report in
                    Button { ReportCenter.shared.open(editing: report.id) } label: { row(report) }
                        .foregroundStyle(.primary)
                }
                .onDelete { offsets in offsets.map { library.reports[$0].id }.forEach(library.remove) }
            } header: { header("Saved reports") } footer: {
                Text("Tap one to add words or share it again. Swipe to remove it from this phone.")
            }.accessibilityIdentifier("saved-reports")
        }
        Section {
            Toggle("Keep a usage log", isOn: $logOn).accessibilityIdentifier("usage-log-toggle")
            if logOn {
                Toggle("Exact places in the log", isOn: $logExact).accessibilityIdentifier("usage-log-exact")
            }
            if tripCount > 0 {
                if let logFile {
                    ShareLink(item: logFile) { Label("Share usage log", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("usage-log-share")
                }
                Button("Clear", role: .destructive) { confirmClear = true }.accessibilityIdentifier("usage-log-clear")
            }
        } header: { header("Usage log") } footer: {
            Text("Off by default. When on, each trip\u{2019}s mode, route choice, estimates and where you left the route (rounded to about 100 m) are kept on this phone, and stay here unless you share the file. \(tripCount) \(tripCount == 1 ? "trip" : "trips") kept.")
        }
        Section {
            Toggle("Keep a detailed log", isOn: $driveOn).accessibilityIdentifier("drive-log-toggle")
            if driveSummary.trips > 0 || !driveFiles.isEmpty {
                if !driveFiles.isEmpty {
                    ShareLink(items: driveFiles) { Label("Share detailed log", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("drive-log-share")
                }
                Button("Clear", role: .destructive) { confirmClearDrive = true }.accessibilityIdentifier("drive-log-clear")
            }
        } header: { header("Detailed log") } footer: {
            Text("Off by default, and separate from the usage log. When on, each guided walk, cycle or drive is recorded on this phone: your route and the places you chose, every location fix with its speed and accuracy, and what the app did (turns reached, leaving the route, rerouting, voice, mute, going to the background). It also keeps what you search for and open. Trips under 3 minutes are deleted when they end. It includes exact places and stays on this phone unless you share the files. \(Self.summaryText(driveSummary)).")
                .accessibilityIdentifier("drive-log-footer")
        }
        .confirmationDialog("Clear the detailed log?", isPresented: $confirmClearDrive, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { DriveLogger.log.clear(); refresh() }
        } message: { Text("This removes \(Self.summaryText(driveSummary)) from this phone.") }
        .confirmationDialog("Clear the usage log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { UsageLogger.log.clear(); refresh() }
        } message: { Text("This removes \(tripCount) \(tripCount == 1 ? "trip" : "trips") from this phone.") }
        .task { refresh() }
        .onChange(of: logOn) { refresh() }
        .onChange(of: driveOn) { refresh() }
    }

    /// "2 trips, 1.4 MB kept"
    static func summaryText(_ s: DriveLog.Summary) -> String {
        "\(s.trips) \(s.trips == 1 ? "trip" : "trips"), \(ByteCountFormatter.string(fromByteCount: Int64(s.bytes), countStyle: .file)) kept"
    }

    private func refresh() {
        driveSummary = DriveLogger.log.summary()
        driveFiles = []
        let share = FileManager.default.temporaryDirectory.appendingPathComponent("drive-log", isDirectory: true)
        try? FileManager.default.removeItem(at: share)
        if driveSummary.bytes > 0 {
            try? FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
            // Copies on this volume are clones, so a large log costs no space or time to share.
            driveFiles = DriveLogger.log.allFiles().compactMap { url in
                let copy = share.appendingPathComponent(url.lastPathComponent)
                return (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : nil
            }
        }

        tripCount = UsageLogger.log.count
        guard tripCount > 0 else { logFile = nil; return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usage-log", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let day = Date().formatted(.iso8601.year().month().day())
        let url = folder.appendingPathComponent("peoplemaps-usage-log-\(day).jsonl")
        logFile = (try? UsageLogger.log.data().write(to: url)) != nil ? url : nil
    }

    private func row(_ report: ProblemReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(report.hasNote ? report.note : report.moment != nil ? "Marked moment, no words yet" : "No words yet")
                .lineLimit(2).foregroundStyle(report.hasNote ? .primary : .secondary)
            Text(report.createdAt.formatted(date: .abbreviated, time: .shortened) + " \u{00B7} " + report.screen)
                .font(.footnote).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).textCase(nil).accessibilityAddTraits(.isHeader)
    }
}
