import SwiftUI
import PeoplemapsCore

/// The report sheet: one note, what is included, and Share. The report is kept on the phone once it has words or marks
/// a moment, and goes out only when the user shares the file.
struct ReportComposerView: View {
    @State private var report: ProblemReport
    @State private var fileURL: URL?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(report: ProblemReport) { _report = State(initialValue: report) }

    private var json: String { (try? report.fileData()).map { String(decoding: $0, as: UTF8.self) } ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What happened, or what you\u{2019}d prefer", text: $report.note, axis: .vertical)
                        .lineLimit(4...12).focused($focused).accessibilityIdentifier("report-note")
                } footer: {
                    Text(report.moment == nil ? "Mention the street if you can." : "This moment is already marked. Words are optional.")
                }
                Section {
                    Toggle("Include exact locations", isOn: $report.includeExact).accessibilityIdentifier("report-exact")
                    DisclosureGroup("What\u{2019}s included") {
                        Text(json).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("report-json")
                    }
                } footer: {
                    Text(report.includeExact ? "Your exact start, destination and position are in the file."
                         : "Start, destination and position are rounded to the nearest street corner or a 550 m square.")
                }
                Section {} footer: {
                    Text("Shares one .json file. Save it to iCloud Drive, in PeopleMaps Reports. Nothing leaves this phone until you share it.")
                }
            }
            // The note is focused as the sheet opens, so Share rides above the keyboard, and a drag down the form puts the keyboard away.
            .scrollDismissesKeyboard(.interactively)
            .safeAreaBar(edge: .bottom) { shareBar }
            .navigationTitle("Report a problem").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { dismiss() }.accessibilityIdentifier("close-report") } }
        }
        .task { writeFile(); focused = report.moment == nil }
        .onChange(of: report) { writeFile() }
        .onDisappear { persist(); if let fileURL { try? FileManager.default.removeItem(at: fileURL) } }
    }

    /// The one action, pinned under the form: a solid primary button, since this sheet is a solid panel (Docs/DESIGN.md, principle 6).
    @ViewBuilder private var shareBar: some View {
        if let fileURL {
            ShareLink(item: fileURL, preview: SharePreview(fileURL.lastPathComponent)) {
                Label("Share report", systemImage: "square.and.arrow.up").font(.body.weight(.semibold)).foregroundStyle(.primaryActionText)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .primaryAction()
            .simultaneousGesture(TapGesture().onEnded { persist() })
            .accessibilityIdentifier("share-report")
            // Held to one line at the largest sizes, so the note keeps its room above the keyboard.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
    }

    /// Kept once it has words or marks a moment; an empty form leaves nothing behind.
    private func persist() {
        if report.hasNote || report.moment != nil { ReportLibrary.shared.save(report) }
    }

    /// The file the share sheet hands over, rewritten as the note and toggle change.
    private func writeFile() {
        guard let data = try? report.fileData() else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(report.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(report.fileName())
        if (try? data.write(to: url)) != nil { fileURL = url }
    }
}
