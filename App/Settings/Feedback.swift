import SwiftUI
import PeoplemapsCore

/// The Feedback section of Settings: report a problem, and the reports kept on the phone once there are any.
struct FeedbackSection: View {
    private let library = ReportLibrary.shared

    var body: some View {
        Section {
            Button { ReportCenter.shared.open(from: "settings") } label: { SettingsAction("Report a problem", symbol: "exclamationmark.bubble") }
                .accessibilityIdentifier("report-problem-about")
            if !library.reports.isEmpty {
                NavigationLink(value: SettingsRoute.savedReports) {
                    SettingsValueRow(title: "Saved reports", value: "\(library.reports.count)")
                }.accessibilityIdentifier("saved-reports")
            }
        } header: { SettingsHeader("Feedback") } footer: { SettingsFooter("Or shake the phone on any screen.") }
    }
}

/// Reports kept on the phone: tap one to add words or share it again, swipe to remove it.
struct SavedReportsPage: View {
    private let library = ReportLibrary.shared

    var body: some View {
        List {
            if !library.reports.isEmpty {
                Section {
                    ForEach(library.reports) { report in
                        Button { ReportCenter.shared.open(editing: report.id) } label: { SavedReportRow(report: report) }
                    }
                    .onDelete(perform: remove)
                } footer: {
                    SettingsFooter("Tap a report to add words or share it again, or swipe to remove it. Moments you flag during guidance wait here\u{00A0}too.")
                }
            }
        }
        .overlay {
            if library.reports.isEmpty {
                ContentUnavailableView("No saved reports", systemImage: "exclamationmark.bubble",
                                       description: Text("Reports you start, and moments you flag during guidance, wait here."))
            }
        }
        .settingsPage("Saved reports")
    }

    private func remove(_ offsets: IndexSet) { offsets.map { library.reports[$0].id }.forEach(library.remove) }
}

private struct SavedReportRow: View {
    let report: ProblemReport

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(report.hasNote ? report.note : report.moment != nil ? "Marked moment, no words yet" : "No words yet")
                .lineLimit(2).foregroundStyle(report.hasNote ? .primary : .secondary)
            Text(report.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
