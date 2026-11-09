import SwiftUI

/// A row on the home sheet that opens a screen, set like the place rows above it: a glyph where the badge sits, the title in
/// label colour, a chevron.
struct HomeRow: View {
    let title: String
    let symbol: String
    var minHeight: CGFloat = 52
    let action: () -> Void
    @ScaledMetric private var badge: CGFloat = 32
    /// Grows with the text, but not so far that "Settings" breaks in two at the largest sizes.
    private var side: CGFloat { min(badge, 44) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: side * 0.5, weight: .medium)).foregroundStyle(.primary)
                    .frame(width: side, height: side).background(.glassWell, in: Circle()).accessibilityHidden(true)
                Text(title).font(.body).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: minHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
