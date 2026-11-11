import SwiftUI
import PeoplemapsCore

/// The usage log's page: its switches, what is kept, Share and Clear, and what it records.
struct UsageLogPage: View {
    let logs: TripLogs
    @AppStorage(UsageLogger.enabledKey, store: ExploreView.voiceStore) private var on = false
    @AppStorage(UsageLogger.exactKey, store: ExploreView.voiceStore) private var exact = false
    @State private var confirmClear = false
    @State private var sender = LogSender(sentKey: "usageLogSentHashes") { [UsageLogger.log.url].filter { FileManager.default.fileExists(atPath: $0.path) } }

    var body: some View {
        List {
            Section {
                Toggle("Keep a usage log", isOn: $on).switchTint().accessibilityIdentifier("usage-log-toggle")
                if on { Toggle("Exact places", isOn: $exact).switchTint().accessibilityIdentifier("usage-log-exact") }
                SettingsValueRow(title: "Kept on this phone", value: logs.usageKept)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("usage-log-summary")
            } footer: {
                SettingsFooter("Off by default. Where you left a route is rounded to about 100\u{00A0}m unless Exact places is on.")
            }
            if logs.usageTrips > 0 {
                Section {
                    if let file = logs.usageFile {
                        ShareLink(item: file) { SettingsAction("Share usage log", symbol: "square.and.arrow.up") }.accessibilityIdentifier("usage-log-share")
                    }
                    SendLogRow(sender: sender, identifier: "usage-log-send")
                    if !sender.batches.isEmpty { DeleteSentRow(sender: sender, identifier: "usage-log-delete-sent") }
                    Button(role: .destructive) { confirmClear = true } label: { SettingsAction("Clear usage log", symbol: "trash", destructive: true) }
                        .accessibilityIdentifier("usage-log-clear")
                } footer: { SendLogFooter(sender: sender) }
            }
            Section {
                SettingsNote(title: "What it keeps", text: "One line for each guided trip: the time, your mode and extra-time limit, the route you started, both routes\u{2019} estimates, any reroutes, where you left the route, and whether you arrived.")
                SettingsNote(title: "Where it stays", text: "On this phone, up to the last 500 trips. It leaves only if you share it, or tap Send to PeopleMaps: then it is encrypted so only the maintainer can read it, and kept on the PeopleMaps server for up to 30\u{00A0}days.")
            } header: { SettingsHeader("About this log") }
        }
        .settingsPage("Usage log")
        .sendConfirmation(sender, exactPlaces: exact)
        .clearConfirmation("Clear the usage log?", isPresented: $confirmClear, removes: logs.usageKept, clear: logs.clearUsage)
        .task { logs.prepareUsageShare() }
    }
}

/// The detailed log's page: its switch, what is kept, Share and Clear, and what it records.
struct DetailedLogPage: View {
    let logs: TripLogs
    @AppStorage(DriveLogger.enabledKey, store: ExploreView.voiceStore) private var on = false
    @State private var confirmClear = false
    @State private var sender = LogSender(sentKey: "driveLogSentHashes") { DriveLogger.log.allFiles() }
    private let recorder = ManualRecorder.shared

    var body: some View {
        List {
            Section {
                Toggle("Keep a detailed log", isOn: $on).switchTint().accessibilityIdentifier("drive-log-toggle")
                SettingsValueRow(title: "Kept on this phone", value: logs.detailedKept)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("drive-log-summary")
            } footer: {
                SettingsFooter("For testing a build on your own phone. Off by default, and separate from the usage\u{00A0}log.")
            }
            if logs.detailed.bytes > 0 {
                Section {
                    if !logs.detailedFiles.isEmpty {
                        ShareLink(items: logs.detailedFiles) { SettingsAction("Share detailed log", symbol: "square.and.arrow.up") }
                            .accessibilityIdentifier("drive-log-share")
                    }
                    SendLogRow(sender: sender, identifier: "drive-log-send")
                    if !sender.batches.isEmpty { DeleteSentRow(sender: sender, identifier: "drive-log-delete-sent") }
                    Button(role: .destructive) { confirmClear = true } label: { SettingsAction("Clear detailed log", symbol: "trash", destructive: true) }
                        .accessibilityIdentifier("drive-log-clear")
                } footer: { SendLogFooter(sender: sender) }
            }
            Section {
                SettingsNote(title: "What it keeps", text: "Each guided walk, cycle or drive: your route and the places you chose, every location fix with its speed and accuracy, and what the app did (turns reached, leaving the route, rerouting, voice, mute, going to the background). It also keeps what you search for and open.")
                    .accessibilityIdentifier("drive-log-footer")
                SettingsNote(title: "Recordings you start", text: "A recording keeps your location, with its speed and accuracy, until you stop it, also while the app is in the background. iOS shows its blue location indicator meanwhile.")
                SettingsNote(title: "Where it stays", text: "On this phone, with exact places, unless you share the files or tap Send to PeopleMaps: then they are encrypted so only the maintainer can read them, and kept on the PeopleMaps server for up to 30\u{00A0}days. It is left out of backups.")
                SettingsNote(title: "Limits", text: "Trips and recordings under 3 minutes are deleted when they end. Past 500 MB the oldest are\u{00A0}removed.")
            } header: { SettingsHeader("About this log") }
        }
        .settingsPage("Detailed log")
        .sendConfirmation(sender, exactPlaces: true)
        .clearConfirmation("Clear the detailed log?", isPresented: $confirmClear, removes: logs.detailedKept, clear: logs.clearDetailed)
        .task { logs.prepareDetailedShare() }
        .onChange(of: recorder.isRecording) { logs.prepareDetailedShare() }
    }
}

/// Send to PeopleMaps: one tap checks what is new, then the confirmation says what goes.
private struct SendLogRow: View {
    let sender: LogSender
    let identifier: String
    var body: some View {
        Button { sender.check() } label: {
            SettingsAction(title: "Send to PeopleMaps", symbol: "icloud.and.arrow.up") {
                if let status = sender.status { Text(status) }
            }
        }
        .foregroundStyle(.primary)
        .disabled(sender.busy)
        .accessibilityIdentifier(identifier)
    }
}

/// Delete sent logs: takes what this phone sent off the server, after asking. Shown while a send may still be there.
private struct DeleteSentRow: View {
    let sender: LogSender
    let identifier: String
    var body: some View {
        Button { sender.confirmingDelete = true } label: {
            SettingsAction(title: "Delete sent logs", symbol: "xmark.icloud") {
                if let status = sender.deleteStatus { Text(status) }
            }
        }
        .foregroundStyle(.primary)
        .disabled(sender.busy)
        .accessibilityIdentifier(identifier)
    }
}

/// Why the last send or delete failed, under the section.
private struct SendLogFooter: View {
    let sender: LogSender
    var body: some View {
        if case let .failed(message) = sender.phase { SettingsFooter(message) }
    }
}

private extension View {
    /// What Send to PeopleMaps will send and where it goes, before it goes. Off the page's background, as the clear dialog is.
    func sendConfirmation(_ sender: LogSender, exactPlaces: Bool) -> some View {
        background {
            Color.clear.confirmationDialog("Send \(sender.pendingSummary) to PeopleMaps?",
                                           isPresented: Binding(get: { sender.confirming }, set: { sender.confirming = $0 }), titleVisibility: .visible) {
                Button("Send") { sender.send() }
            } message: {
                Text((exactPlaces ? "They include exact places. " : "")
                     + "They are encrypted on this phone so only the maintainer can read them. The PeopleMaps server keeps them for up to 30\u{00A0}days, then deletes them.")
            }
        }
        .background {
            Color.clear.confirmationDialog("Delete the logs this phone sent?",
                                           isPresented: Binding(get: { sender.confirmingDelete }, set: { sender.confirmingDelete = $0 }), titleVisibility: .visible) {
                Button("Delete from server", role: .destructive) { sender.deleteSent() }
            } message: {
                Text("This removes them from the PeopleMaps server. A copy the maintainer already took is not removed. The log on this phone stays.")
            }
        }
    }

    /// Asks before a log is cleared. The dialog hangs off a view of its own behind the page, never off the list or a section in it:
    /// on a container that holds a ShareLink it stops the share sheet from presenting.
    func clearConfirmation(_ title: String, isPresented: Binding<Bool>, removes kept: String, clear: @escaping () -> Void) -> some View {
        background {
            Color.clear.confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
                Button("Clear", role: .destructive, action: clear)
            } message: { Text("This removes \(kept) from this phone.") }
        }
    }
}
