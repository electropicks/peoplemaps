import SwiftUI
import PeoplemapsCore

struct PlacePicker: View {
    let title: String
    let graph: StreetGraph
    let selected: Place
    let onSelect: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var results: [Place] {
        if query.isEmpty { return ExploreView.featuredIDs.compactMap { id in graph.places.first { $0.id == id } } }
        return Array(graph.search(query).prefix(60))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SearchField(text: $query, identifier: "place-search")
                    if results.isEmpty {
                        EmptySearch(count: graph.places.count).padding(.top, 40)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(query.isEmpty ? "Featured places" : "Matches").font(.footnote).textCase(.uppercase)
                                .foregroundStyle(.secondary).padding(.leading, 16)
                            PlaceList(places: results, query: query, selectedID: selected.id, identifier: { "place-\($0.id)" }) {
                                onSelect($0); dismiss()
                            }
                        }
                    }
                }.padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("cancel-search") } }
        }
    }
}

/// Native-style search field: gray rounded field, magnifier, clear button.
struct SearchField: View {
    @Binding var text: String
    var identifier = "search-input"
    var focused: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            field
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var field: some View {
        let base = TextField("Search places", text: $text).autocorrectionDisabled().submitLabel(.search).accessibilityIdentifier(identifier)
        if let focused { base.focused(focused) } else { base }
    }
}

struct EmptySearch: View {
    let count: Int
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text("No places match in this Seattle area").font(.headline).multilineTextAlignment(.center)
            Text("PeopleMaps searches \(count) places in this offline area.").font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 24)
        .accessibilityElement(children: .combine).accessibilityIdentifier("search-empty")
    }
}
