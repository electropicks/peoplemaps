import SwiftUI
import PeoplemapsCore

/// Where a row of Settings leads.
enum SettingsRoute: Hashable { case usageLog, detailedLog, savedReports, calmerMeans, mapData, acknowledgements }

/// Settings, from the home sheet: the map on the phone, the trip logs, feedback, and what the app is. The root list is rows only;
/// every explanation is a page behind one (Docs/DESIGN.md section 4.9).
struct SettingsView: View {
    let graph: StreetGraph
    let dataVersion: String
    /// No route is shown and the person is not navigating, so a downloaded map may replace this one now.
    let canSwitchNow: Bool
    @State private var logs = TripLogs()
    @Environment(\.dismiss) private var dismiss

    init(graph: StreetGraph, dataVersion: String, canSwitchNow: Bool = false) {
        self.graph = graph; self.dataVersion = dataVersion; self.canSwitchNow = canSwitchNow
        UsageLogger.resetForUITests(); DriveLogger.resetForUITests()
    }

    var body: some View {
        NavigationStack {
            List {
                MapSettingsSection(canSwitchNow: canSwitchNow)
                TripLogsSection(logs: logs)
                FeedbackSection()
                AboutSection()
            }
            .settingsPage("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .usageLog: UsageLogPage(logs: logs)
                case .detailedLog: DetailedLogPage(logs: logs)
                case .savedReports: SavedReportsPage()
                case .calmerMeans: CalmerMeansPage()
                case .mapData: MapDataPage(graph: graph, dataVersion: dataVersion)
                case .acknowledgements: AcknowledgementsView()
                }
            }
            .task { logs.refresh() }
        }
        .environment(\.closeSettings, dismiss)
        // Rows to read and switches to set: solid, not glass (Docs/DESIGN.md, principle 2).
        .tint(.primary).presentationDetents([.large]).presentationBackground(Color.panel)
    }
}

/// What the app is, behind three rows, and which build this is.
private struct AboutSection: View {
    var body: some View {
        Section {
            NavigationLink("What calmer means", value: SettingsRoute.calmerMeans).accessibilityIdentifier("calmer-means")
            NavigationLink("Map data and coverage", value: SettingsRoute.mapData).accessibilityIdentifier("map-data")
            NavigationLink("Acknowledgements", value: SettingsRoute.acknowledgements).accessibilityIdentifier("acknowledgements")
        } header: { SettingsHeader("About") } footer: {
            Text(AppVersion.line).font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, 16)
                .accessibilityIdentifier("app-version")
        }
    }
}

/// "PeopleMaps 0.1.0", with the commit the build was made from when the build says: the `PM_BUILD_COMMIT` build setting,
/// through `PMBuildCommit` in Info.plist.
enum AppVersion {
    static var line: String { line(Bundle.main.infoDictionary ?? [:]) }
    static func line(_ info: [String: Any]) -> String {
        let commit = (info["PMBuildCommit"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return "PeopleMaps \(info["CFBundleShortVersionString"] as? String ?? "?")" + (commit.isEmpty ? "" : "\u{00A0}\u{00B7}\u{00A0}\(commit)")
    }
}
