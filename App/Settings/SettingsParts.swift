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
            // 48 pt rows, not the system's 52: with them the root list and its version line fit one screen, clear of the home indicator.
            .environment(\.defaultMinListRowHeight, 48)
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

/// A section footer in the same grey, under the group it explains, as the system's Settings sets an explanation. A paragraph
/// to a string; the root list keeps to one sentence, two at most.
struct SettingsFooter: View {
    let paragraphs: [String]
    init(_ text: String) { paragraphs = [text] }
    init(_ paragraphs: [String]) { self.paragraphs = paragraphs }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(paragraphs, id: \.self) { Text($0).font(.footnote).foregroundStyle(GuidanceOverlay.onGlass) }
        }
    }
}

/// A short heading over a paragraph, one to a row. Only the log pages still use it, until their footers land (PR 73); new
/// explanations are a `SettingsFooter`.
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

/// The label of a row that does something when tapped. A row that leads to a page has its chevron and a row that only states a
/// value has nothing, so an action carries a trailing symbol in the secondary grey: the title stays label colour, and nothing takes
/// an accent. A destructive row's symbol takes the row's red. At accessibility sizes the value moves under the title.
struct SettingsAction<Value: View>: View {
    let title: String
    let symbol: String
    var destructive = false
    @ViewBuilder var value: Value
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 24

    var body: some View {
        HStack(spacing: 10) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    value.foregroundStyle(GuidanceOverlay.onGlass)
                }
                Spacer(minLength: 8)
            } else {
                Text(title)
                Spacer(minLength: 8)
                value.foregroundStyle(GuidanceOverlay.onGlass)
            }
            glyph.frame(width: symbolWidth).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var glyph: some View {
        let image = Image(systemName: symbol).font(.body)
        if destructive { image } else { image.foregroundStyle(GuidanceOverlay.onGlass) }
    }
}

extension SettingsAction where Value == EmptyView {
    init(_ title: String, symbol: String, destructive: Bool = false) {
        self.init(title: title, symbol: symbol, destructive: destructive) { EmptyView() }
    }
}

extension SettingsAction where Value == Text {
    init(_ title: String, value: String, symbol: String) {
        self.init(title: title, symbol: symbol) { Text(value) }
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
