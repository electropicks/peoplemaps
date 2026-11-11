import SwiftUI
import PeoplemapsCore

/// The search field, then recents and shortcuts before anything is typed, the results after.
struct SearchSheet: View {
    @Bindable var model: ExploreModel
    @Environment(\.landscapeCard) private var landscape

    var body: some View {
        let inset = Layout.inset(landscape: landscape)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FocusedSearchField(text: $model.query, placeholder: model.addingFavourite ? "Add a favourite" : "Where to?")
                Button("Cancel", action: model.cancelSearch).font(.body).foregroundStyle(.primary).accessibilityIdentifier("cancel-search-home")
            }.padding(.horizontal, inset).padding(.top, landscape ? Layout.cardInset : 20).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.readingLink {
                        ProgressView("Reading link\u{2026}").frame(maxWidth: .infinity).padding(.top, 24).accessibilityIdentifier("reading-link")
                    } else if model.query.isEmpty {
                        // Never a blank page: what to type or the last places, then the searches people make most.
                        if !model.saved.recents.isEmpty { resultGroup("Recents", model.saved.recents, prefix: "recent-") }
                        else {
                            Text("Search a place, an address or a street").font(.subheadline).foregroundStyle(GuidanceOverlay.onGlass)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.top, 8)
                                .accessibilityIdentifier("search-hint")
                        }
                        SearchShortcuts(nearby: model.userInCoverage != nil) { model.query = $0 }
                    } else if model.results.isEmpty {
                        // The way out sits where a result would: under the empty state it fell behind the keyboard. VoiceOver still hears what happened first.
                        AppleMapsLookup(query: model.query)
                        EmptySearch(count: model.search.count).accessibilitySortPriority(1)
                    } else {
                        let results = model.results
                        resultGroup("Top match", Array(results.prefix(1)))
                        if results.count > 1 { resultGroup("Other matches", Array(results.dropFirst())) }
                    }
                    if let pin = model.shared?.pin, !model.readingLink { resultGroup("Or use the shared location", [pin], prefix: "shared-pin-") }
                }.padding(.horizontal, inset).padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively).scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .onChange(of: model.query) { old, text in model.searchChanged(from: old, to: text) }
    }

    private func resultGroup(_ title: String, _ places: [Place], prefix: String = "result-") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(GuidanceOverlay.onGlass).padding(.leading, 4).accessibilityAddTraits(.isHeader)
            PlaceList(places: places, query: model.query, identifier: { prefix + $0.id }, action: model.picked)
        }
    }
}

/// Focus has to live inside the sheet's own view tree, so the search field brings its own.
private struct FocusedSearchField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var focused: Bool
    var body: some View {
        SearchField(text: $text, placeholder: placeholder, focused: $focused).task { focused = true }
    }
}
