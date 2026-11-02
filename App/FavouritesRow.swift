import SwiftUI
import PeoplemapsCore

/// Home's favourites, as in Apple Maps: round badges with short names, then Add. Long-press a badge to remove it.
/// Only shown once there is a favourite.
struct FavouritesRow: View {
    let favourites: [Place]
    let onOpen: (Place) -> Void
    let onRemove: (Place) -> Void
    let onAdd: () -> Void
    let onEdit: () -> Void
    @ScaledMetric(relativeTo: .caption) private var width: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Favourites").font(.footnote.weight(.semibold)).foregroundStyle(GuidanceOverlay.onGlass)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Edit", action: onEdit).font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                    .accessibilityLabel("Edit favourites").accessibilityIdentifier("edit-favourites")
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(favourites) { place in
                        Button { onOpen(place) } label: { item(place.shortName) { CategoryBadge(badge: place.badge, raw: place.category, size: 56) } }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { onRemove(place) } label: { Label("Remove from Favourites", systemImage: "star.slash") }
                            }
                            .accessibilityLabel("\(place.shortName), \(place.categoryLabel)")
                            .accessibilityAction(named: "Remove from Favourites") { onRemove(place) }
                            .accessibilityIdentifier("favourite-\(place.id)")
                    }
                    Button(action: onAdd) {
                        item("Add") {
                            Image(systemName: "plus").font(.title2.weight(.semibold)).foregroundStyle(.primary)
                                .frame(width: badge, height: badge).background(Color(uiColor: .systemGray5), in: Circle())
                        }
                    }
                    .buttonStyle(.plain).accessibilityLabel("Add a favourite").accessibilityIdentifier("add-favourite")
                }
            }
            .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    @ScaledMetric(relativeTo: .caption) private var badge: CGFloat = 56

    private func item<Badge: View>(_ name: String, @ViewBuilder badge: () -> Badge) -> some View {
        VStack(spacing: 4) {
            badge()
            Text(name).font(.caption).foregroundStyle(.primary).multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: width).contentShape(Rectangle())
    }
}

/// The same favourites as a list: swipe to delete, or Edit for the delete buttons.
struct FavouritesEditor: View {
    let saved: SavedPlacesStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(saved.favourites) { place in
                    HStack(spacing: 12) {
                        CategoryBadge(badge: place.badge, raw: place.category)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.shortName).font(.body)
                            Text(place.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("edit-favourite-\(place.id)")
                }
                .onDelete { offsets in
                    let places = offsets.map { saved.favourites[$0] }
                    places.forEach(saved.removeFavourite)
                    if saved.favourites.isEmpty { dismiss() }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Favourites").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { EditButton().accessibilityIdentifier("edit-favourites-list") }
                ToolbarItem(placement: .confirmationAction) { Button(role: .confirm) { dismiss() }.accessibilityIdentifier("close-favourites") }
            }
        }
        .tint(.primary).presentationDetents([.medium, .large])
    }
}
