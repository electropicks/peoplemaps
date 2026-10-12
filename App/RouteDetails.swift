import SwiftUI
import PeoplemapsCore

struct RouteDetails: View {
    let comparison: RouteComparison
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Why this choice") {
                    ForEach(comparison.reasons, id: \.self) { Text($0).font(.subheadline) }
                    Text("The extra-time limit is applied to unrounded estimates. \(comparison.candidateCount) distinct candidates were found; the search does not guarantee the best possible calmer route.")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                Section("What the data says") {
                    metricsRow("Estimated time", comparison.fastest.duration, comparison.calmer?.duration)
                    metricsRow("Distance", comparison.fastest.distance, comparison.calmer?.distance)
                    metricsRow("Turns", "\(comparison.fastest.metrics.turns)", comparison.calmer.map { "\($0.metrics.turns)" })
                    if comparison.request.mode == .drive {
                        metricsRow("Arterial left turns", "\(comparison.fastest.metrics.arterialLefts)", comparison.calmer.map { "\($0.metrics.arterialLefts)" })
                        metricsRow("Highway entries", "\(comparison.fastest.metrics.highwayEntries)", comparison.calmer.map { "\($0.metrics.highwayEntries)" })
                    } else {
                        metricsRow("Cycleway / track tags", percent(comparison.fastest.metrics.cycleTrackMeters, of: comparison.fastest), comparison.calmer.map { percent($0.metrics.cycleTrackMeters, of: $0) })
                        metricsRow("Surface unknown", percent(comparison.fastest.metrics.unknownSurfaceMeters, of: comparison.fastest), comparison.calmer.map { percent($0.metrics.unknownSurfaceMeters, of: $0) })
                        metricsRow("Grade unknown", percent(comparison.fastest.metrics.unknownGradeMeters, of: comparison.fastest), comparison.calmer.map { percent($0.metrics.unknownGradeMeters, of: $0) })
                    }
                    Text("Left column: fastest estimate. Right column: calmer candidate.").font(.caption).foregroundStyle(Palette.muted)
                }
                Section("Read this before relying on a route") {
                    Text("This is a route-comparison prototype, not turn-by-turn navigation. No route is labeled safe.")
                    Text("Times use assumed speeds and junction delays. They do not include live traffic, closures, parking, signal timing, or verified travel times.")
                    Text(comparison.request.mode == .drive ? "Left-turn protection, merge difficulty, and the length of a highway visit are not verified. Highway-entry and turn counts are limited proxies." : "Cycleway/track tags are not a physical inspection of separation. Surface tags are incomplete. Grade is reported as coverage only and is not scored; no elevation model is bundled.")
                    Text("Routes begin and end at nearby nodes on the main connected network: \(Int(comparison.originSnapMeters.rounded())) m from the start place and \(Int(comparison.destinationSnapMeters.rounded())) m from the destination. These gaps are not routed or included in time. Pins mark the route endpoints, not verified entrances.")
                    Text("There is no background location tracking or automatic rerouting. Comparisons change only when you edit the places, mode, or time budget.")
                }.font(.subheadline)
                Section("Streets in the selected candidates") {
                    Text("FASTEST").font(.caption.weight(.bold)).foregroundStyle(Palette.muted)
                    Text(comparison.fastest.streetNames.joined(separator: " → ")).font(.subheadline)
                    if let calmer = comparison.calmer {
                        Text("CALMER").font(.caption.weight(.bold)).foregroundStyle(Palette.forest)
                        Text(calmer.streetNames.joined(separator: " → ")).font(.subheadline)
                    }
                }
            }.scrollContentBackground(.hidden).background(Palette.paper)
                .navigationTitle("Behind the routes").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("close-details") } }
        }
    }
    private func percent(_ value: Double, of route: Route) -> String { "\(Int((value / max(1, route.metrics.meters) * 100).rounded()))%" }
    private func metricsRow(_ name: String, _ fastest: String, _ calmer: String?) -> some View {
        HStack { Text(name).font(.subheadline); Spacer(); Text(fastest).font(.subheadline.monospacedDigit()).foregroundStyle(Palette.muted); Text(calmer ?? "—").font(.subheadline.monospacedDigit()).foregroundStyle(Palette.forest).frame(minWidth: 70, alignment: .trailing) }
    }
}

struct AboutView: View {
    let graph: StreetGraph
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("A map with room for people") {
                    Text("Choose a little more time when a route asks less of you. No sponsored ranking. Clear reasons. Your time budget.")
                    Text("Peoplemaps is a working name for a Seattle proof of concept.").font(.caption).foregroundStyle(Palette.muted)
                }
                Section("Open foundations") {
                    Text("Native SwiftUI · MapLibre Native · OpenStreetMap")
                    Text("\(graph.places.count) places and \(graph.edges.count.formatted()) directed road segments are bundled. Routing and comfort costs run entirely on this device. No account or location permission is needed.")
                    Link("OpenStreetMap contributors · ODbL 1.0", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    Link("MapLibre Native · BSD 2-Clause", destination: URL(string: "https://github.com/maplibre/maplibre-native")!)
                }
                Section("Seattle, with boundaries") {
                    Text("Snapshot: 11 October 2026. Coverage: north of Denny Way through southern Green Lake, from east Ballard to the University District. Map detail stops at the extract boundary.")
                    Text("Missing restrictions, conditional access, temporary closures, and entrances can affect feasibility. Unsupported turn-restriction forms are conservatively excluded. This prototype has not been field validated.")
                    Text("Driving favors fewer turns, fewer arterial lefts, fewer highway entries, and less residential shortcutting. Cycling favors cycleway/track tags and quieter road classes. These are transparent preferences, not safety ratings.")
                }
            }.scrollContentBackground(.hidden).background(Palette.paper)
                .navigationTitle("About Peoplemaps").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
