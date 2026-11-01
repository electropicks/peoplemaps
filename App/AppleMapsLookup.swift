import SwiftUI

/// For a query we cannot answer: hands the user off to the Apple Maps app. Nothing from Apple is shown in PeopleMaps,
/// which is what Apple's terms allow with a non-Apple map (Docs/SEARCH.md).
struct AppleMapsLookup: View {
    let query: String
    @Environment(\.openURL) private var openURL
    @ScaledMetric private var diameter: CGFloat = 32

    /// `maps://?q=…` searched near the centre of our area.
    static func url(for query: String) -> URL? {
        var components = URLComponents(string: "maps://")
        components?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "sll", value: "47.649,-122.349")]
        return components?.url
    }

    var body: some View {
        Button { if let url = Self.url(for: query) { openURL(url) } } label: {
            HStack(spacing: 12) {
                Image(systemName: "map").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Color.categoryGlyph)
                    .frame(width: diameter, height: diameter).background(Color.categoryFill(.services), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Look up in Apple Maps").font(.body).foregroundStyle(.primary)
                    Text("Opens the Maps app").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.panelFill, in: RoundedRectangle(cornerRadius: Layout.groupRadius))
        .accessibilityLabel("Look up \u{201C}\(query)\u{201D} in Apple Maps")
        .accessibilityHint("Opens the Maps app")
        .accessibilityIdentifier("apple-maps-lookup")
    }
}
