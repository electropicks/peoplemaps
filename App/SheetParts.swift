import SwiftUI

extension Layout {
    /// Content inset of the portrait sheet, or of the landscape card.
    static func inset(landscape: Bool) -> CGFloat { landscape ? cardInset : inset }
}

extension EnvironmentValues {
    /// The explore panel is the landscape card at the leading edge, not the portrait sheet.
    @Entry var landscapeCard = false
}

/// Scrolls whenever the content is taller than the room it has. In landscape the card also sizes itself to the content.
struct SheetScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.landscapeCard) private var landscape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, Layout.inset(landscape: landscape)).padding(.top, landscape ? Layout.cardInset : Layout.sheetTop).padding(.bottom, Layout.sheetBottom)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    // The first measurement sizes the card at launch without animating it open.
                    var launch = Transaction(); launch.disablesAnimations = contentHeight == 0
                    withTransaction(launch) { contentHeight = height }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: landscape ? contentHeight : .infinity)
        .animation(landscape ? Motion.panel(reduceMotion) : nil, value: contentHeight)
    }
}

/// The xmark in a well that closes the place card or the preview.
struct CloseButton: View {
    let label: String
    let id: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.primary)
                .frame(width: 30, height: 30).background(.glassWell, in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }
}
