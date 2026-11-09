import SwiftUI
import PeoplemapsCore

/// The Trip logs section of Settings: each log's state, leading to its page, and the recording control while the detailed log is on.
struct TripLogsSection: View {
    let logs: TripLogs
    @AppStorage(UsageLogger.enabledKey, store: ExploreView.voiceStore) private var usageOn = false
    @AppStorage(DriveLogger.enabledKey, store: ExploreView.voiceStore) private var detailedOn = false

    var body: some View {
        Section {
            NavigationLink(value: SettingsRoute.usageLog) {
                SettingsValueRow(title: "Usage log", value: logs.usageState(on: usageOn))
            }.accessibilityIdentifier("usage-log")
            NavigationLink(value: SettingsRoute.detailedLog) {
                SettingsValueRow(title: "Detailed log", value: logs.detailedState(on: detailedOn))
            }.accessibilityIdentifier("drive-log")
            if detailedOn { RecordingRow(logs: logs) }
        } header: { SettingsHeader("Trip logs") } footer: {
            SettingsFooter("Off by default. They stay on this phone unless\u{00A0}you\u{00A0}share\u{00A0}them.")
        }
    }
}

/// Starts or stops a manual recording. It is the one log action people repeat, so it sits on the root list.
private struct RecordingRow: View {
    let logs: TripLogs
    private let recorder = ManualRecorder.shared
    @State private var denied = false

    var body: some View {
        Button(action: toggle) {
            SettingsAction(title: recorder.isRecording ? "Stop recording" : "Start recording", symbol: recorder.isRecording ? "stop.circle" : "play.circle") {
                if let startedAt = recorder.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(RecordingPill.elapsed(context.date.timeIntervalSince(startedAt))).monospacedDigit()
                    }
                }
            }
        }
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
        .accessibilityIdentifier("drive-record-toggle")
        .onChange(of: recorder.isRecording) { logs.refresh() }
        if denied {
            Text("Location is off for PeopleMaps, so the recording did not start. Allow it in the iPhone\u{2019}s Settings app.")
                .font(.subheadline).foregroundStyle(GuidanceOverlay.onGlass).accessibilityIdentifier("drive-record-denied")
        }
    }

    private func toggle() {
        if recorder.isRecording { recorder.stop(); logs.refresh() } else {
            Task { denied = !(await recorder.start()) }
        }
    }
}
