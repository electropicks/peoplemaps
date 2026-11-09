import SwiftUI

extension EnvironmentValues {
    /// Closes the Settings sheet from any of its pages, where `dismiss` would only pop the page.
    @Entry var closeSettings: DismissAction?
}

private struct SettingsPage: ViewModifier {
    let title: String
    @Environment(\.closeSettings) private var close

    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            // A solid bar in the list's own colour: rows are cut off under the title, where the system's edge effect blurs
            // a section header into a ghost.
            .scrollEdgeEffectStyle(.hard, for: .top)
            .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { close?() }.accessibilityIdentifier("close-settings") }
            }
    }
}

extension View {
    /// The chrome every Settings page shares: grouped list, inline title, and the sheet's close button.
    func settingsPage(_ title: String) -> some View { modifier(SettingsPage(title: title)) }
}

/// A section header in Settings: sentence case, in a grey that holds 4.5:1 on the list's background (the list's own is about 3:1).
struct SettingsHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(GuidanceOverlay.onGlass).textCase(nil).accessibilityAddTraits(.isHeader)
    }
}

/// A section footer in the same grey. One sentence, two at most; anything longer is a `SettingsNote` on a page.
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.footnote).foregroundStyle(GuidanceOverlay.onGlass) }
}

/// A short heading over a paragraph: how every explanation in Settings is set, with a symbol when the heading is a travel mode.
struct SettingsNote: View {
    let title: String
    let text: String
    var symbol: String?
    @ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.body.weight(.medium)).frame(width: symbolWidth).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(text).font(.subheadline).foregroundStyle(GuidanceOverlay.onGlass)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// A row with its value trailing, in the grey the rest of Settings' secondary text uses. It stacks at accessibility sizes, as `LabeledContent` does.
struct SettingsValueRow: View {
    let title: String
    let value: String
    var body: some View {
        LabeledContent { Text(value).foregroundStyle(GuidanceOverlay.onGlass) } label: { Text(title) }
    }
}

/// An external link in label colour with the arrow-out glyph, not the global tint.
struct ExternalLink: View {
    let title: String
    let url: URL
    var font: Font = .body
    var body: some View {
        Link(destination: url) {
            HStack {
                Text(title).font(font)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }.foregroundStyle(.primary)
    }
}
