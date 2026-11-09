import SwiftUI
import PeoplemapsCore

/// The usage log's page: its switches, what is kept, Share and Clear, and what it records.
struct UsageLogPage: View {
    let logs: TripLogs
    @AppStorage(UsageLogger.enabledKey, store: ExploreView.voiceStore) private var on = false
    @AppStorage(UsageLogger.exactKey, store: ExploreView.voiceStore) private var exact = false
    @State private var confirmClear = false

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
                    Button(role: .destructive) { confirmClear = true } label: { SettingsAction("Clear usage log", symbol: "trash", destructive: true) }
                        .accessibilityIdentifier("usage-log-clear")
                }
            }
            Section {
                SettingsNote(title: "What it keeps", text: "One line for each guided trip: the time, your mode and extra-time limit, the route you started, both routes\u{2019} estimates, any reroutes, where you left the route, and whether you arrived.")
                SettingsNote(title: "Where it stays", text: "On this phone, up to the last 500 trips. Nothing is sent. It leaves only if you share the file.")
            } header: { SettingsHeader("About this log") }
        }
        .settingsPage("Usage log")
        .clearConfirmation("Clear the usage log?", isPresented: $confirmClear, removes: logs.usageKept, clear: logs.clearUsage)
        .task { logs.prepareUsageShare() }
    }
}

/// The detailed log's page: its switch, what is kept, Share and Clear, and what it records.
struct DetailedLogPage: View {
    let logs: TripLogs
    @AppStorage(DriveLogger.enabledKey, store: ExploreView.voiceStore) private var on = false
    @State private var confirmClear = false
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
                    Button(role: .destructive) { confirmClear = true } label: { SettingsAction("Clear detailed log", symbol: "trash", destructive: true) }
                        .accessibilityIdentifier("drive-log-clear")
                }
            }
            Section {
                SettingsNote(title: "What it keeps", text: "Each guided walk, cycle or drive: your route and the places you chose, every location fix with its speed and accuracy, and what the app did (turns reached, leaving the route, rerouting, voice, mute, going to the background). It also keeps what you search for and open.")
                    .accessibilityIdentifier("drive-log-footer")
                SettingsNote(title: "Recordings you start", text: "A recording keeps your location, with its speed and accuracy, until you stop it, also while the app is in the background. iOS shows its blue location indicator meanwhile.")
                SettingsNote(title: "Where it stays", text: "On this phone, with exact places, unless you share the files. It is left out of backups.")
                SettingsNote(title: "Limits", text: "Trips and recordings under 3 minutes are deleted when they end. Past 500 MB the oldest are\u{00A0}removed.")
            } header: { SettingsHeader("About this log") }
        }
        .settingsPage("Detailed log")
        .clearConfirmation("Clear the detailed log?", isPresented: $confirmClear, removes: logs.detailedKept, clear: logs.clearDetailed)
        .task { logs.prepareDetailedShare() }
        .onChange(of: recorder.isRecording) { logs.prepareDetailedShare() }
    }
}

private extension View {
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
