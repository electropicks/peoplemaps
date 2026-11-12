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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { close?() }.accessibilityIdentifier("close-settings") }
            }
    }
}

extension View {
    /// The chrome every Settings page shares: grouped list, inline title, and the sheet's close button.
    func settingsPage(_ title: String) -> some View { modifier(SettingsPage(title: title)) }
}

/// A section header in Settings, as the system sets one.
struct SettingsHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(title) }
}

/// A section footer under the group it explains, as the system sets one. A paragraph to a string; the root list keeps to one
/// sentence, two at most.
struct SettingsFooter: View {
    let paragraphs: [String]
    init(_ text: String) { paragraphs = [text] }
    init(_ paragraphs: [String]) { self.paragraphs = paragraphs }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { ForEach(paragraphs, id: \.self) { Text($0) } }
    }
}

/// A row with its value trailing: the system's `LabeledContent`, which stacks at accessibility sizes.
struct SettingsValueRow: View {
    let title: String
    let value: String
    var body: some View { LabeledContent(title, value: value) }
}

/// The label of a row that does something when tapped: a system `Label`, its symbol leading, with the row's value trailing
/// when it has one. A destructive row takes the system's red from its button's role.
struct SettingsAction<Value: View>: View {
    let title: String
    let symbol: String
    var destructive = false
    @ViewBuilder var value: Value

    var body: some View {
        LabeledContent { value } label: { Label(title, systemImage: symbol) }
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
