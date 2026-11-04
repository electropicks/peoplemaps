import SwiftUI
import PeoplemapsCore

/// Home's favourites: one glass chip each over the map, with its badge and short name, then Add. On the raised sheet or the
/// landscape card, where glass doesn't go on glass, the chips use a plain well instead. Long-press a chip to remove it.
/// Only shown once there is a favourite.
struct FavouritesRow: View {
    let favourites: [Place]
    let floating: Bool
    let onOpen: (Place) -> Void
    let onRemove: (Place) -> Void
    let onAdd: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var chipHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var badgeSize: CGFloat = 30

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(favourites) { place in
                    Button { onOpen(place) } label: {
                        HStack(spacing: 8) {
                            CategoryBadge(badge: place.badge, raw: place.category, size: 30)
                            Text(place.shortName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                        }
                        .padding(.leading, (chipHeight - badgeSize) / 2).padding(.trailing, 14)
                        .frame(minHeight: chipHeight).contentShape(Capsule())
                        .chip(floating: floating, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { onRemove(place) } label: { Label("Remove from Favourites", systemImage: "star.slash") }
                    }
                    .accessibilityLabel("\(place.shortName), \(place.categoryLabel)")
                    .accessibilityAction(named: "Remove from Favourites") { onRemove(place) }
                    .accessibilityIdentifier("favourite-\(place.id)")
                }
                Button(action: onAdd) {
                    Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(.primary)
                        .frame(width: chipHeight, height: chipHeight).contentShape(Circle())
                        .chip(floating: floating, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Add a favourite").accessibilityIdentifier("add-favourite")
            }
        }
        .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollClipDisabled()
    }
}

extension View {
    /// Its own glass while floating over the map; a plain well once it sits on a panel.
    @ViewBuilder func chip<S: Shape>(floating: Bool, in shape: S) -> some View {
        if floating { floatingSurface(in: shape, interactive: true) } else { background(.glassWell, in: shape) }
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
                ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { dismiss() }.accessibilityIdentifier("close-favourites") }
            }
        }
        .tint(.primary).presentationDetents([.medium, .large])
    }
}
