import SwiftUI

/// Credits and licences for what ships in the app; THIRD_PARTY.md is the repository copy.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            credit("OpenStreetMap", "© OpenStreetMap contributors. Streets, paths and places, under the Open Database License\u{00A0}1.0.",
                   link: "https://www.openstreetmap.org/copyright")
            credit("Overture Maps Foundation", "Places: Overture Maps Foundation (release 2026-10-21), with data from Meta, Microsoft, BrightQuery, Foursquare, AllThePlaces, Uberall, Birdeye and DAC. Licences: CDLA Permissive 2.0, Apache 2.0, CC0 1.0. Foursquare data © Foursquare Labs, Inc. Combined with OpenStreetMap data in the search index, provided as is.",
                   link: "https://docs.overturemaps.org/attribution/")
            credit("USGS 3D Elevation Program", "Elevation from the U.S. Geological Survey 3DEP ground model, public domain.",
                   link: "https://www.usgs.gov/3d-elevation-program")
            Section {
                licence("MapLibre Native", "BSD 2-Clause", file: "MapLibre-LICENSE")
                licence("Ferrostar", "BSD 3-Clause", file: "Ferrostar-LICENSE")
            } header: { SettingsHeader("Software") } footer: {
                SettingsFooter([
                    "MapLibre Native draws the map. Ferrostar, © Stadia Maps, is the turn-by-turn navigation core.",
                    "Ferrostar\u{2019}s navigation core includes open-source Rust libraries, each under the MIT, Apache 2.0 or MPL 2.0 licence. Apple frameworks and SF Symbols are used through the iOS SDK.",
                ])
            }
        }
        .settingsPage("Acknowledgements")
    }

    /// A data source: its name is the link to its licence, and the credit it asks for is the footer.
    private func credit(_ name: String, _ detail: String, link: String) -> some View {
        Section { ExternalLink(title: name, url: URL(string: link)!) } footer: { SettingsFooter(detail) }
    }

    private func licence(_ name: String, _ kind: String, file: String) -> some View {
        NavigationLink { LicenceText(title: name, file: file) } label: { SettingsValueRow(title: name, value: kind) }
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
        .settingsPage(title)
    }
    private var text: String {
        Bundle.main.url(forResource: file, withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "The licence text is missing from this build."
    }
}
