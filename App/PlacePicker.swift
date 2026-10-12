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
        if query.isEmpty {
            let featured = ["way/37056567", "relation/1047789", "way/37058377", "way/160545994", "node/693337509", "way/12903132"]
            return featured.compactMap { id in graph.places.first { $0.id == id } }
        }
        return Array(graph.search(query).prefix(60))
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search Seattle places", text: $query).autocorrectionDisabled().accessibilityIdentifier("place-search")
                }
                Section(query.isEmpty ? "Try a Seattle place" : "Matches in this extract") {
                    ForEach(results) { place in
                        Button {
                            onSelect(place); dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(place.category)).foregroundStyle(Palette.forest).frame(width: 22)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(place.shortName).foregroundStyle(Palette.ink)
                                    Text(place.category.capitalized).font(.caption).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                if place.id == selected.id { Image(systemName: "checkmark").foregroundStyle(Palette.forest) }
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("place-\(place.id)")
                    }
                    if results.isEmpty {
                        Text("No matching place in this offline extract. Try a park, library, museum, or café.").font(.subheadline).foregroundStyle(Palette.muted).accessibilityIdentifier("search-empty")
                    }
                }
                Section {
                    Text("\(graph.places.count) named places from OpenStreetMap. Alphabetical search; no sponsored results. This is a limited area, not all of Seattle.")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }.scrollContentBackground(.hidden).background(Palette.paper)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("cancel-search") } }
        }
    }
    private func icon(_ category: String) -> String {
        switch category { case "park": "tree"; case "library": "books.vertical"; case "cafe": "cup.and.saucer"; default: "mappin.and.ellipse" }
    }
}
