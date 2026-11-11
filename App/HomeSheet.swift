import SwiftUI
import PeoplemapsCore

/// What home's panel and floating controls share: favourites over the search capsule, and the first-launch hint: a chip above the
/// capsule while floating, a caption under the field on a panel.
struct HomeControls: View {
    let model: ExploreModel
    /// Over the map on their own glass, at rest; otherwise on the sheet's panel or the landscape card.
    let floating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let hint = "Search a place or address, or long-press the map"

    var body: some View {
        // One container for the whole cluster, so the chips, hint and search capsule sample and blend together.
        GlassEffectContainer(spacing: 2) {
            VStack(alignment: .leading, spacing: 8) {
                if !model.saved.favourites.isEmpty {
                    FavouritesRow(favourites: model.saved.favourites, floating: floating, onOpen: model.open,
                                  onRemove: { place in withAnimation(Motion.panel(reduceMotion)) { model.saved.removeFavourite(place) } },
                                  onAdd: { model.addingFavourite = true; model.show(.search) })
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                }
                let firstLaunch = model.saved.favourites.isEmpty && model.saved.recents.isEmpty
                if firstLaunch && floating {
                    Text(Self.hint).font(.footnote).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 6)
                        .floatingSurface(in: Capsule())
                        .accessibilityIdentifier("home-hint")
                }
                HStack(spacing: 8) {
                    searchCapsule
                    if floating { moreButton.transition(.opacity) }
                }
                if firstLaunch && !floating {
                    // On a panel the hint is the field's caption. In a well of its own it passed for a second field.
                    Text(Self.hint).font(.footnote).foregroundStyle(GuidanceOverlay.onGlass)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 18)
                        .accessibilityIdentifier("home-hint")
                }
            }
        }
    }

    /// The way to search: its own glass over the map, a plain well on a panel.
    private var searchCapsule: some View {
        Button { model.show(.search) } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").fontWeight(.medium)
                Text("Where to?").fontWeight(.medium)
                Spacer(minLength: 0)
            }
            .font(.body).foregroundStyle(.primary).padding(.horizontal, 18).frame(minHeight: floating ? 56 : 44)
            .contentShape(Capsule())
            .chip(floating: floating, in: Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel("Where to?").accessibilityHint("Search places and addresses").accessibilityIdentifier("search-field")
    }

    /// Raises the sheet to what doesn't float: Recents and the rest.
    private var moreButton: some View {
        Button(action: model.raiseHome) {
            Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 56, height: 56).contentShape(Circle())
                .chip(floating: true, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel("More").accessibilityHint("Shows recents and Settings").accessibilityIdentifier("home-more")
    }
}

/// Home raised: its controls on the panel, then Recents, Edit favourites and Settings. Reports its height to `height`, which the
/// sheet's one stop follows.
struct HomeSheet: View {
    let model: ExploreModel
    let height: HomeHeight
    @Environment(\.landscapeCard) private var landscape

    var body: some View {
        SheetScroll {
            VStack(alignment: .leading, spacing: 20) {
                HomeControls(model: model, floating: false)
                if !model.saved.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recents").font(.footnote.weight(.semibold)).foregroundStyle(GuidanceOverlay.onGlass).padding(.leading, 4)
                            .accessibilityAddTraits(.isHeader)
                        PlaceList(places: Array(model.saved.recents.prefix(landscape ? 3 : 5)), minHeight: landscape ? 46 : 52, identifier: { "home-recent-\($0.id)" }, action: model.open)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !model.saved.favourites.isEmpty {
                        HomeRow(title: "Edit favourites", symbol: "star", minHeight: landscape ? 46 : 52) { model.sheet = .favourites }
                            .accessibilityIdentifier("edit-favourites")
                        Hairline().padding(.leading, 60)
                    }
                    HomeRow(title: "Settings", symbol: "gearshape", minHeight: landscape ? 46 : 52) { model.sheet = .settings }
                        .accessibilityIdentifier("settings")
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                // Only on the sheet: the landscape card sizes itself.
                if !landscape, self.height.block != height { self.height.block = height }
            }
        }
    }
}

/// Height of everything on home's raised sheet; zero until it has been laid out once. Outside `ExploreView`'s state, so a new
/// measure redraws the sheet that reads it (`PortraitSheet`) and not the map.
@MainActor @Observable final class HomeHeight {
    var block: CGFloat = 0
}
