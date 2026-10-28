import SwiftUI
import PeoplemapsCore

/// One place in a grouped list: gray category icon, name (matched text bold), "Category · Neighbourhood".
struct PlaceRow: View {
    enum Trailing { case chevron, checkmark }
    let place: Place
    var query = ""
    var trailing = Trailing.chevron
    var minHeight: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: place.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(Color(uiColor: .systemGray), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body).foregroundStyle(.primary).lineLimit(1)
                    Text(place.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                switch trailing {
                case .chevron: Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                case .checkmark: Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 14).frame(minHeight: minHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(place.shortName), \(place.subtitle)")
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

/// Rows in one rounded group, separated by hairlines inset past the icon.
struct PlaceList: View {
    let places: [Place]
    var query = ""
    var selectedID: String?
    var minHeight: CGFloat = 52
    var identifier: (Place) -> String
    let action: (Place) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                if index > 0 { Divider().padding(.leading, 58) }
                PlaceRow(place: place, query: query, trailing: place.id == selectedID ? .checkmark : .chevron, minHeight: minHeight) { action(place) }
                    .accessibilityIdentifier(identifier(place))
            }
        }
        .background(.panelFill, in: RoundedRectangle(cornerRadius: 12))
    }
}
