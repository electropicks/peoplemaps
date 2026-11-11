import SwiftUI
import PeoplemapsCore

/// What the search sheet offers before anything is typed: the kinds of place people look for most, each a search for its word
/// (`SearchIndex.categoryWords`), so the results are the index's own, nearest first. Set like the favourite chips: a badge and a
/// word in a well.
struct SearchShortcuts: View {
    /// Location is known, so the results are the nearest ones.
    let nearby: Bool
    let onPick: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var chipHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var badgeSize: CGFloat = 30

    private struct Shortcut: Identifiable {
        let title: String
        let group: PlaceCategory
        /// The raw category whose glyph the badge takes.
        let raw: String
        var id: String { title.lowercased() }
    }
    private static let all = [
        Shortcut(title: "Coffee", group: .coffee, raw: "cafe"), Shortcut(title: "Food", group: .food, raw: "restaurant"),
        Shortcut(title: "Groceries", group: .shops, raw: "supermarket"), Shortcut(title: "Parks", group: .parks, raw: "park"),
        Shortcut(title: "Gas", group: .transit, raw: "fuel"), Shortcut(title: "Pharmacy", group: .health, raw: "pharmacy"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(nearby ? "Nearby" : "In \(RegionSelection.areaName)").font(.footnote.weight(.semibold)).foregroundStyle(GuidanceOverlay.onGlass)
                .padding(.leading, 4).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 8) {
                ForEach(Self.all) { shortcut in
                    Button { onPick(shortcut.title) } label: {
                        HStack(spacing: 8) {
                            CategoryBadge(badge: .category(shortcut.group), raw: shortcut.raw, size: 30)
                            Text(shortcut.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, (chipHeight - badgeSize) / 2).padding(.trailing, 14)
                        .frame(minHeight: chipHeight).contentShape(Capsule())
                        .background(.glassWell, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(nearby ? "Searches for \(shortcut.id) near you" : "Searches for \(shortcut.id)")
                    .accessibilityIdentifier("shortcut-\(shortcut.id)")
                }
            }
        }
    }
}
