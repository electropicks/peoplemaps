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
                    CalmBar(comparison: comparison)
                    if comparison.calmer == nil { Text(comparison.noCalmer.title).font(.headline) }
                } header: {
                    Text("Calm estimate")
                } footer: {
                    Text("An estimate from 0 to 100, higher is calmer, from the things listed below per minute of the trip. It knows only what the map knows: no live traffic.")
                }
                Section {
                    ForEach(comparison.reasons, id: \.self) { reason in
                        let tradeoff = reason.hasPrefix("Tradeoff: ")
                        Label {
                            Text(tradeoff ? "Costs you " + reason.dropFirst("Tradeoff: ".count) : reason)
                                .foregroundStyle(tradeoff ? .secondary : .primary)
                        } icon: {
                            // With no calmer route the reason is a finding, not a benefit.
                            Image(systemName: tradeoff ? "minus" : comparison.calmer == nil ? "info.circle" : "checkmark").fontWeight(.semibold)
                                .foregroundStyle(tradeoff || comparison.calmer == nil ? Color.secondary : Color.primary)
                        }
                    }
                } header: {
                    Text(comparison.calmer == nil ? "Why one route" : comparison.tradesStress ? "What this route avoids" : "Why the calmer route")
                } footer: {
                    Text("The extra-time limit is a maximum, applied to unrounded estimates. A slower route must also remove enough estimated stress to be worth its extra time. \(comparison.candidateCount == 1 ? "1 distinct route was found" : "\(comparison.candidateCount) distinct candidates were compared"); the search does not guarantee the calmest possible route.")
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
                    Text(goodToKnowCalmer)
                    Text("Times use assumed speeds, hills and junction delays. They do not include live traffic, closures, parking, signal timing, or verified travel times.")
                    Text(modeNote)
                    Text("Hills come from a 16 ft USGS ground model; bridges and tunnels are interpolated between their ends.")
                    ForEach(comparison.caveats, id: \.self) { Text("Unknown in the map: \($0)") }
                    Text("Routes begin and end at nearby points on the main connected network: \(DistanceFormat.distance(comparison.originSnapMeters)) from the start place and \(DistanceFormat.distance(comparison.destinationSnapMeters)) from the destination. These gaps are not routed or included in time.")
                }.font(.subheadline).foregroundStyle(.secondary)
                Section("Streets") {
                    streets("Fastest", comparison.fastest, color: .fastest)
                    if let calmer = comparison.calmer { streets("Calmer", calmer, color: .calmer) }
                }
                Section { Button { ReportCenter.shared.open(from: "route details") } label: { Label("Report a problem", systemImage: "exclamationmark.bubble") }
                    .accessibilityIdentifier("report-problem-details") }
            }.listStyle(.insetGrouped)
                .navigationTitle("Behind the routes").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(role: .close) { dismiss() }.accessibilityIdentifier("close-details") } }
        // Long reading, with secondary text: solid, not glass.
        }.tint(.primary).presentationDetents([.medium, .large]).presentationBackground(Color.panel)
    }
    /// With the person's own Calmer means settings the second route is the one that avoids what they chose, which isn't always less stress overall.
    private var goodToKnowCalmer: String {
        let custom = !comparison.request.preferences.isDefault(in: comparison.request.mode)
        if comparison.tradesStress { return "No route is labeled safe. With your Calmer means settings, this route avoids more of what you chose to avoid, and by our estimates has more of other things listed above. It is not calmer overall." }
        if custom { return "No route is labeled safe. With your Calmer means settings, \"calmer\" means fewer of what you chose to avoid, which can come with more of something else." }
        return "No route is labeled safe; \"calmer\" means fewer of the things listed above."
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
            Text(calmer ?? "—").fontWeight(.semibold).frame(minWidth: 64, alignment: .trailing)
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
    /// The launch graph holds only its bounds, so the count comes from the graph file.
    @State private var edgeCount: Int?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Routes with fewer stressful turns, for a few minutes more. Driving avoids lefts and crossings without a signal, stop-and-go, confusing junctions and hill starts. Cycling avoids riding in traffic, busy crossings and climbs. Walking avoids unmarked crossings of busy streets, missing sidewalks and hills.")
                    Text("These are transparent preferences, not safety ratings. Times and stress are estimates, with no live traffic.").font(.footnote).foregroundStyle(.secondary)
                } header: { header("What calmer means") }
                Section {
                    Text("\(edgeCount.map { "\($0.formatted()) directed" } ?? "Directed") street and path segments are bundled, with USGS elevation. Routing runs entirely on this device. No account is needed. If you haven\u{2019}t answered yet, PeopleMaps asks to use your location when it opens. Your location stays on this iPhone.")
                    Text("Snapshot: 11 October 2026.").foregroundStyle(.secondary)
                    externalLink("OpenStreetMap contributors · ODbL 1.0", "https://www.openstreetmap.org/copyright")
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }.accessibilityIdentifier("acknowledgements")
                } header: { header("Data") }
                Section {
                    Text("North of Denny Way through southern Green Lake, from east Ballard to the University District. Map detail stops at the extract boundary.")
                    Text("Missing restrictions, conditional access, temporary closures, and entrances can affect feasibility. Unsupported turn-restriction forms are conservatively excluded. This prototype has not been field validated.").foregroundStyle(.secondary)
                } header: { header("Coverage") }
                ReportsAboutSection()
            }.listStyle(.insetGrouped)
                .task { edgeCount = graph.edges.isEmpty ? await Task.detached { try? StreetGraph.bundledEdgeCount() }.value : graph.edges.count }
                .navigationTitle("About PeopleMaps").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(role: .close) { dismiss() }.accessibilityIdentifier("close-about") } }
        }.tint(.primary).presentationDetents([.large])
    }
    private func header(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).textCase(nil).accessibilityAddTraits(.isHeader)
    }
}

/// An external link in label colour with the arrow-out glyph, not the global tint.
struct ExternalLink: View {
    let title: String
    let url: URL
    var font: Font = .body
    var body: some View {
        Link(destination: url) {
            HStack {
                Text(title).font(font)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }.foregroundStyle(.primary)
    }
}

private func externalLink(_ title: String, _ url: String) -> some View {
    ExternalLink(title: title, url: URL(string: url)!)
}
