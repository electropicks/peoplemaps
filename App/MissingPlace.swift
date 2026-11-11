import SwiftUI
import PeoplemapsCore

/// Search found nothing. Never a dead end: the closest places we do have, then the ways to get there anyway (its street
/// address, a pin, the Apple Maps app), then why it can be missing. Nothing from Apple is shown in PeopleMaps (Docs/SEARCH.md).
struct MissingPlace: View {
    @Bindable var model: ExploreModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        let query = model.query, closest = model.closest
        if !closest.places.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.heading(closest)).font(.footnote.weight(.semibold)).foregroundStyle(GuidanceOverlay.onGlass).padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("closest-heading")
                PlaceList(places: closest.places, identifier: { "closest-" + $0.id }, action: model.picked)
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Other ways to get there").font(.footnote.weight(.semibold)).foregroundStyle(GuidanceOverlay.onGlass).padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                // The way out sits where a result would: under the explanation it fell behind the keyboard.
                WayRow(symbol: "map", title: "Look up in Apple Maps", detail: "Opens the Maps app", leaves: true) {
                    if let url = AppleMapsLookup.url(for: query) { openURL(url) }
                }
                .accessibilityLabel("Look up \u{201C}\(query)\u{201D} in Apple Maps").accessibilityHint("Opens the Maps app")
                .accessibilityIdentifier("apple-maps-lookup")
                Hairline().padding(.leading, 60)
                HStack(spacing: 12) {
                    WayRow.Labels(symbol: "doc.on.clipboard", title: "Paste its address", detail: "Copied from another app")
                    Spacer(minLength: 0)
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        model.remember(missed: query)
                        model.query = String(text.prefix(200))
                    }
                    .labelStyle(.titleOnly).buttonBorderShape(.capsule).tint(.accentColor).accessibilityIdentifier("paste-address")
                }
                .padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: 52)
                Hairline().padding(.leading, 60)
                WayRow(symbol: "mappin.and.ellipse", title: "Drop a pin", detail: "Touch and hold the spot on the map") {
                    model.remember(missed: query)
                    model.chooseOnMap()
                }
                .accessibilityIdentifier("drop-a-pin")
                Hairline().padding(.leading, 60)
                WayRow(symbol: "exclamationmark.bubble", title: "Report it missing", detail: "Opens a report you can add to and share") {
                    ReportCenter.shared.open(from: "search, missing place", note: "Missing place: \(query)")
                }
                .accessibilityIdentifier("report-missing-place")
            }
            .rowGroup()
        }
        ContentUnavailableView {
            Label("Not in this offline map", systemImage: "magnifyingglass")
        } description: {
            Text("PeopleMaps searches \(model.search.count.formatted()) places and addresses from OpenStreetMap and Overture Maps. A newer or smaller business can be missing.")
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier("search-empty").accessibilitySortPriority(1)
        .onAppear { model.remember(missed: query) }
        .onChange(of: query) { _, new in model.remember(missed: new) }
    }

    /// "Pharmacy near Capitol Hill", "Pharmacy nearby", or "Closest matches" when the text named no category.
    static func heading(_ closest: SearchIndex.Closest) -> String {
        guard let category = closest.category else { return "Closest matches" }
        let word = category.prefix(1).uppercased() + category.dropFirst()
        return closest.area.map { "\(word) near \($0)" } ?? "\(word) nearby"
    }
}

/// One way forward: a glyph in a well, what it does, and where it leads.
struct WayRow: View {
    let symbol: String, title: String, detail: String
    /// It opens another app.
    var leaves = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Labels(symbol: symbol, title: title, detail: detail)
                Spacer(minLength: 0)
                Image(systemName: leaves ? "arrow.up.forward" : "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    struct Labels: View {
        let symbol: String, title: String, detail: String
        @ScaledMetric private var diameter: CGFloat = 32
        var body: some View {
            Image(systemName: symbol).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Color.categoryGlyph)
                .frame(width: diameter, height: diameter).background(Color.categoryFill(.services), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Asks what to call a place being kept, with the system's alert and text field.
struct NamePlaceAlert: ViewModifier {
    /// Read by the caller's body, so the alert follows an `@Observable` model.
    let place: Place?
    @Binding var name: String
    let dismiss: () -> Void
    let save: (Place, String) -> Void

    func body(content: Content) -> some View {
        let shown = place != nil
        content.alert("Name this place", isPresented: Binding(get: { shown }, set: { if !$0 { dismiss() } }), presenting: place) { place in
            TextField("Name", text: $name).textInputAutocapitalization(.words).accessibilityIdentifier("place-name")
            Button("Save") { save(place, name) }.accessibilityIdentifier("save-place-name")
            Button("Not now", role: .cancel) {}
        } message: { place in
            Text("Search will find \(place.kind == .address && place.address == nil ? place.name : "it") by this name. It stays on this iPhone.")
        }
    }
}
