import SwiftUI
import PeoplemapsCore

struct RouteDetails: View {
    let comparison: RouteComparison
    @Environment(\.dismiss) private var dismiss
    private var rows: [Factor] {
        let routes = [comparison.fastest, comparison.calmer].compactMap { $0 }
        return Factor.allCases.filter { f in !f.isUnknown && routes.contains { $0.metrics.breakdown[f].amount > 0 } }
            .sorted { comparison.fastest.metrics.breakdown[$0].cost > comparison.fastest.metrics.breakdown[$1].cost }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(comparison.reasons, id: \.self) { reason in
                        let tradeoff = reason.hasPrefix("Tradeoff: ")
                        Label {
                            Text(tradeoff ? "Costs you " + reason.dropFirst("Tradeoff: ".count) : reason)
                                .foregroundStyle(tradeoff ? .secondary : .primary)
                        } icon: {
                            Image(systemName: tradeoff ? "minus" : "checkmark").fontWeight(.semibold)
                                .foregroundStyle(tradeoff ? Color.secondary : Color.calmer)
                        }
                    }
                } header: {
                    Text(comparison.calmer == nil ? "Why one route" : "Why the calmer route")
                } footer: {
                    Text("The extra-time limit is applied to unrounded estimates. \(comparison.candidateCount) distinct candidates were compared; the search does not guarantee the calmest possible route.")
                }
                Section {
                    metricsRow("Time", comparison.fastest.duration, comparison.calmer?.duration)
                    metricsRow("Distance", comparison.fastest.distance, comparison.calmer?.distance)
                    ForEach(rows, id: \.self) { f in
                        metricsRow(f.title, f.formatted(comparison.fastest.metrics.breakdown[f].amount),
                                   comparison.calmer.map { f.formatted($0.metrics.breakdown[f].amount) })
                    }
                } header: {
                    HStack {
                        Text("What each route asks")
                        Spacer()
                        Text("Fastest").frame(minWidth: 64, alignment: .trailing)
                        Text("Calmer").frame(minWidth: 64, alignment: .trailing)
                    }
                } footer: {
                    Text("Ordered by how much each adds to the fastest route's stress.")
                }
                Section("Good to know") {
                    Text("This is a route-comparison prototype, not turn-by-turn navigation. No route is labeled safe; \"calmer\" means fewer of the things listed above.")
                    Text("Times use assumed speeds, hills and junction delays. They do not include live traffic, closures, parking, signal timing, or verified travel times.")
                    Text(modeNote)
                    Text("Hills come from a 5 m USGS ground model; bridges and tunnels are interpolated between their ends.")
                    ForEach(comparison.caveats, id: \.self) { Text("Unknown in the map: \($0)") }
                    Text("Routes begin and end at nearby points on the main connected network: \(Int(comparison.originSnapMeters.rounded())) m from the start place and \(Int(comparison.destinationSnapMeters.rounded())) m from the destination. These gaps are not routed or included in time.")
                }.font(.subheadline).foregroundStyle(.secondary)
                Section("Streets") {
                    streets("Fastest", comparison.fastest, color: .fastest)
                    if let calmer = comparison.calmer { streets("Calmer", calmer, color: .calmer) }
                }
            }.listStyle(.insetGrouped)
                .navigationTitle("Behind the routes").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("close-details") } }
        }.presentationDetents([.medium, .large])
    }
    private var modeNote: String {
        switch comparison.request.mode {
        case .drive: "Signals, stop signs and turn lanes come from the map; turn-arrow phases and merge difficulty do not. Stop-and-go counts signs and signals only, not traffic queues."
        case .bike: "Bike lane and track tags are not a physical inspection of separation. Traffic stress is estimated from lanes, speed limits and bike facilities."
        case .walk: "Crossings use their mapped markings and signals. Sidewalk condition, lighting and curb ramps are not checked."
        }
    }
    private func metricsRow(_ name: String, _ fastest: String, _ calmer: String?) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(fastest).foregroundStyle(.secondary).frame(minWidth: 64, alignment: .trailing)
            Text(calmer ?? "—").fontWeight(.semibold).foregroundStyle(.calmerText).frame(minWidth: 64, alignment: .trailing)
        }.font(.subheadline.monospacedDigit())
    }
    private func streets(_ title: String, _ route: Route, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(route.streetNames.joined(separator: " → ")).font(.subheadline).foregroundStyle(.secondary)
            }
        }
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
                    Text("Peoplemaps is a working name for a Seattle proof of concept.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Open foundations") {
                    Text("Native SwiftUI · MapLibre Native · Ferrostar · OpenStreetMap")
                    Text("\(graph.places.count) places and \(graph.edges.count.formatted()) directed street and path segments are bundled, with USGS elevation. Routing runs entirely on this device. No account is needed. Location is asked for only when you start guidance, and it stays on this iPhone.")
                    Link("OpenStreetMap contributors · ODbL 1.0", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }.accessibilityIdentifier("acknowledgements")
                }
                Section("Seattle, with boundaries") {
                    Text("Snapshot: 11 October 2026. Coverage: north of Denny Way through southern Green Lake, from east Ballard to the University District. Map detail stops at the extract boundary.")
                    Text("Missing restrictions, conditional access, temporary closures, and entrances can affect feasibility. Unsupported turn-restriction forms are conservatively excluded. This prototype has not been field validated.")
                    Text("Driving avoids lefts and crossings without a signal, stop-and-go, confusing junctions and hill starts. Cycling avoids riding in traffic, busy crossings and climbs. Walking avoids unmarked crossings of busy streets, missing sidewalks and hills. These are transparent preferences, not safety ratings.")
                }
            }.listStyle(.insetGrouped)
                .navigationTitle("About Peoplemaps").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}
