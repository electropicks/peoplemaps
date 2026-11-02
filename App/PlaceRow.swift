import SwiftUI
import PeoplemapsCore

/// One place in a grouped list: category badge, name (matched text bold), subtitle, and a source line while searching.
/// Trailing: a checkmark when selected, else the distance from `near`, else a chevron.
struct PlaceRow: View {
    let place: Place
    var query = ""
    var selected = false
    var near: Coordinate?
    var minHeight: CGFloat = 52
    let action: () -> Void

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var meters: Double? { near.map { $0.distance(to: place.coordinate) } }

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.onGlassPanel) private var onGlass
    private var secondary: Color { onGlass ? GuidanceOverlay.onGlass : .secondary }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CategoryBadge(badge: place.badge, raw: place.category)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body).foregroundStyle(.primary).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    Text(place.subtitle).font(.subheadline).foregroundStyle(secondary)
                    if searching, let source = place.source {
                        Text(source).font(.caption).foregroundStyle(secondary)
                    }
                    if typeSize.isAccessibilitySize, !selected, let distance { distance }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.primary)
                } else if !typeSize.isAccessibilitySize, let distance {
                    distance
                } else if meters == nil {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: minHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var distance: Text? {
        meters.map { Text(NavigationFormat.distance($0)).font(.subheadline.monospacedDigit()).foregroundColor(secondary) }
    }

    private var label: String {
        var parts = [place.shortName] + place.subtitle.components(separatedBy: " · ")
        if let meters { parts.append(NavigationFormat.distance(meters, spoken: true)) }
        if searching, let source = place.source { parts.append(source) }
        return parts.joined(separator: ", ")
    }

    private var title: AttributedString {
        var text = AttributedString(place.shortName)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty, let range = place.shortName.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]),
           let lower = AttributedString.Index(range.lowerBound, within: text), let upper = AttributedString.Index(range.upperBound, within: text) {
            text[lower..<upper].font = .body.bold()
        }
        return text
    }
}

/// Rows in one rounded group, separated by hairlines inset past the badge.
struct PlaceList: View {
    let places: [Place]
    var query = ""
    var selectedID: String?
    var near: Coordinate?
    var minHeight: CGFloat = 52
    var identifier: (Place) -> String
    let action: (Place) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                if index > 0 { Hairline().padding(.leading, 60) }
                PlaceRow(place: place, query: query, selected: place.id == selectedID, near: near, minHeight: minHeight) { action(place) }
                    .accessibilityIdentifier(identifier(place))
            }
        }
        .rowGroup()
        .animation(Motion.content(reduceMotion), value: places.map(\.id))
    }
}
