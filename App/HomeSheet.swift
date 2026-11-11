import SwiftUI
import PeoplemapsCore

/// What home shows at every stop: favourites over the one search field, and the first-launch hint as its caption.
struct HomeControls: View {
    let model: ExploreModel
    /// The sheet is at its lowest stop, so the More button is there to raise it for those who don't drag.
    let peek: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let hint = "Search a place or address, or long-press the map"

    var body: some View {
        // One container for the whole cluster, so the chips, hint and search capsule sample and blend together.
        GlassEffectContainer(spacing: 2) {
            VStack(alignment: .leading, spacing: 8) {
                if !model.saved.favourites.isEmpty {
                    FavouritesRow(favourites: model.saved.favourites, floating: false, onOpen: model.open,
                                  onRemove: { place in withAnimation(Motion.panel(reduceMotion)) { model.saved.removeFavourite(place) } },
                                  onAdd: { model.addingFavourite = true; model.show(.search) })
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                }
                let firstLaunch = model.saved.favourites.isEmpty && model.saved.recents.isEmpty
                HStack(spacing: 8) {
                    searchCapsule
                    if peek { moreButton.transition(.opacity) }
                }
                if firstLaunch {
                    // On a panel the hint is the field's caption. In a well of its own it passed for a second field.
                    Text(Self.hint).font(.footnote).foregroundStyle(GuidanceOverlay.onGlass)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 18)
                        .accessibilityIdentifier("home-hint")
                }
            }
        }
    }

    /// The way to search: one field, a plain well on the sheet at every stop.
    private var searchCapsule: some View {
        Button { model.show(.search) } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").fontWeight(.medium)
                Text("Where to?").fontWeight(.medium)
                Spacer(minLength: 0)
            }
            .font(.body).foregroundStyle(.primary).padding(.horizontal, 18).frame(minHeight: 44)
            .contentShape(Capsule())
            .chip(floating: false, in: Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel("Where to?").accessibilityHint("Search places and addresses").accessibilityIdentifier("search-field")
    }

    /// Raises the sheet to Recents and the rest.
    private var moreButton: some View {
        Button(action: model.raiseHome) {
            Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 44, height: 44).contentShape(Circle())
                .chip(floating: false, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel("More").accessibilityHint("Shows recents and Settings").accessibilityIdentifier("home-more")
    }
}

/// Home: the search field, then Recents, Edit favourites and Settings, which are below the fold at the sheet's lowest stop. Reports
/// the height of the controls and of everything to `height`, which the sheet's two stops follow.
struct HomeSheet: View {
    let model: ExploreModel
    let height: HomeHeight
    @Environment(\.landscapeCard) private var landscape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var peek: Bool { model.screen == .home && model.stop == .fit && !landscape }

    var body: some View {
        SheetScroll {
            VStack(alignment: .leading, spacing: 20) {
                HomeControls(model: model, peek: peek)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { controls in
                        if !landscape, height.controls != controls { height.controls = controls }
                    }
                // Below the fold at the lowest stop: there to slide into view as the sheet is raised, but not to tap or read out.
                Group {
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
                .opacity(peek ? 0 : 1).allowsHitTesting(!peek).accessibilityHidden(peek)
                .animation(Motion.content(reduceMotion), value: peek)
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
    /// Height of the controls alone, which is what the sheet's lowest stop shows.
    var controls: CGFloat = 0
}
