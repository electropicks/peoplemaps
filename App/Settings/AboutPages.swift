import SwiftUI
import PeoplemapsCore

/// What "calmer" weighs in each travel mode, in a sentence each.
struct CalmerMeansPage: View {
    var body: some View {
        List {
            Section { Text("Routes with fewer stressful turns, for a\u{00A0}few\u{00A0}minutes\u{00A0}more.") }
            Section {
                SettingsNote(title: "Driving", text: "Avoids lefts and crossings without a signal, stop-and-go, confusing junctions and hill starts.", symbol: "car.fill")
                SettingsNote(title: "Cycling", text: "Avoids riding in traffic, busy crossings and climbs.", symbol: "bicycle")
                SettingsNote(title: "Walking", text: "Avoids unmarked crossings of busy streets, missing sidewalks and hills.", symbol: "figure.walk")
            } footer: {
                SettingsFooter("These are transparent preferences, not safety ratings. Times and stress are estimates, with no live traffic.")
            }
        }
        .settingsPage("What calmer means")
    }
}

/// Where the map comes from, what it covers and what it can miss.
struct MapDataPage: View {
    let graph: StreetGraph
    /// `SearchIndex.dataVersion`: "osm-2026-10-31".
    let dataVersion: String
    /// The launch graph holds only its bounds, so the count comes from the graph file's header.
    @State private var segments: Int?

    var body: some View {
        List {
            Section {
                SettingsNote(title: "On this phone", text: "The map and search are stored on this phone, and routes are worked out here. No account is needed.")
                SettingsNote(title: "Your location", text: "It stays on this iPhone unless you share a report or a log that includes it.")
            }
            Section {
                if let date = Self.date(dataVersion) { SettingsValueRow(title: "Map data from", value: date) }
                ExternalLink(title: "OpenStreetMap contributors \u{00B7} ODbL 1.0", url: URL(string: "https://www.openstreetmap.org/copyright")!)
                SettingsValueRow(title: "Elevation", value: "USGS 3D Elevation Program")
                if let segments {
                    SettingsValueRow(title: "Street and path segments", value: segments.formatted())
                        .accessibilityElement(children: .combine).accessibilityIdentifier("segment-count")
                }
            } header: { SettingsHeader("Sources") }
            Section {
                SettingsNote(title: RegionSelection.areaName, text: coverage)
                SettingsNote(title: "What the map can miss", text: "Missing restrictions, conditional access, temporary closures, and entrances can affect feasibility. Unsupported turn-restriction forms are conservatively excluded. This prototype has not been field validated.")
            } header: { SettingsHeader("Coverage") }
        }
        .settingsPage("Map data and coverage")
        .task { segments = await Task.detached { try? StreetGraph.bundledHeader().segments }.value }
    }

    private var coverage: String {
        if RegionSelection.usesCounty {
            return "King County and a little beyond. Map detail stops at the edge of the extract. Places that need a ferry or a road outside the map, as Vashon and the Kitsap shore do, have no road route."
        }
        // The small extract in the repository, used when the full Seattle data has not been fetched for the build.
        let small = graph.bounds.count == 4 && graph.bounds[2] - graph.bounds[0] < 0.1
        return small ? "North of Denny Way through southern Green Lake, from east Ballard to the University District. Map detail stops at the extract boundary."
            : "All of Seattle. Map detail stops at the edge of the map."
    }

    /// "31 October 2026" from "osm-2026-10-31"; nil when the index doesn't say.
    static func date(_ dataVersion: String) -> String? {
        guard dataVersion.hasPrefix("osm-"),
              let day = try? Date(String(dataVersion.dropFirst("osm-".count)), strategy: .iso8601.year().month().day()) else { return nil }
        // The day as written in the data, wherever the phone is.
        var style = Date.FormatStyle(locale: Locale(identifier: "en_GB"), timeZone: .gmt)
        style = style.day().month(.wide).year()
        return day.formatted(style)
    }
}
