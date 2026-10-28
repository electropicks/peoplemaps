import SwiftUI

/// Credits and licences for what ships in the app; THIRD_PARTY.md is the repository copy.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                credit("OpenStreetMap", "© OpenStreetMap contributors. Streets, paths and places, under the Open Database License 1.0.",
                       link: "https://www.openstreetmap.org/copyright")
                credit("USGS 3D Elevation Program", "Elevation from the U.S. Geological Survey 3DEP ground model, public domain.",
                       link: "https://www.usgs.gov/3d-elevation-program")
            } header: { Text("Data") }
            Section {
                licence("MapLibre Native", "Map rendering · BSD 2-Clause", file: "MapLibre-LICENSE")
                licence("Ferrostar", "Turn-by-turn navigation core · BSD 3-Clause, © Stadia Maps", file: "Ferrostar-LICENSE")
            } header: { Text("Software") } footer: {
                Text("Ferrostar's navigation core includes open-source Rust libraries, each under the MIT, Apache 2.0 or MPL 2.0 licence. Apple frameworks and SF Symbols are used through the iOS SDK.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Acknowledgements").navigationBarTitleDisplayMode(.inline)
    }

    private func credit(_ name: String, _ detail: String, link: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.body.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
            Link("Licence and attribution", destination: URL(string: link)!).font(.subheadline)
        }
    }

    private func licence(_ name: String, _ detail: String, file: String) -> some View {
        NavigationLink {
            LicenceText(title: name, file: file)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("licence-\(file)")
    }
}

/// A bundled licence file shown verbatim.
private struct LicenceText: View {
    let title: String
    let file: String
    var body: some View {
        ScrollView {
            Text(text).font(.footnote.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
    private var text: String {
        Bundle.main.url(forResource: file, withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "The licence text is missing from this build."
    }
}
