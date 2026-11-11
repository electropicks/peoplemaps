import SwiftUI
import PeoplemapsCore

/// The portrait sheet: a system sheet over the map with a stop per screen, the system's background interaction and drag indicator.
/// Its own view, so home's measured height redraws the sheet and not the map.
struct PortraitSheet<Content: View>: View {
    let model: ExploreModel
    let homeHeight: HomeHeight
    let cover: SheetCover
    let screenHeight: CGFloat
    let safeBottom: CGFloat
    /// Home at rest: the controls float on the map and the sheet is on its way out.
    let floatingHome: Bool
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Height of home's content as last laid out; zero before the first layout.
    @State private var homeBlock: CGFloat = 0
    /// Home's previous stop, kept in the detents while the sheet glides from it to the new one (`measuredHome`).
    @State private var leavingHome: PresentationDetent?

    private var screen: Screen { model.screen }
    private var stop: Stop { model.stop }

    var body: some View {
        content
            // The sheet's background is the system's: Liquid Glass at the partial stops, opaque at large, frosted or solid under
            // Reduce Transparency and Increase Contrast. Nothing of ours is painted over it (owner's decision, 10 November 2026).
            .modifier(DebugOpaqueSheet())
            .presentationCornerRadius(Layout.sheetRadius)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if stop == .large {
                    AttributionLinks().frame(maxWidth: .infinity).padding(.vertical, 6).transition(.opacity)
                }
            }
            // At the partial stops the system floats the sheet clear of the home indicator, so its safe area would only be a gap.
            .ignoresSafeArea(.container, edges: stop == .large ? [] : .bottom)
            .animation(Motion.content(reduceMotion), value: stop == .large)
            .presentationDetents(detents, selection: stopBinding)
            .presentationBackgroundInteraction(.enabled(upThrough: screen == .preview ? raisedDetent : detent(.medium)))
            .presentationDragIndicator(floatingHome ? .hidden : .visible)
            // Home's raised sheet pulls down to the floating controls; every other screen stays until it's closed.
            .interactiveDismissDisabled(screen != .home)
            // At its lower stops the system shrinks the sheet and floats it above the screen's edge, so its own height says nothing
            // about where its top is. The global frame includes that.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY.rounded() } action: { top in
                cover.update(height: screenHeight - top, restsShortOfLarge: stop != .large && screen != .search)
            }
            .onChange(of: homeHeight.block, initial: true) { measuredHome(homeHeight.block) }
            #if DEBUG
            .onGeometryChange(for: String.self) { "\(Int($0.frame(in: .global).minY)) \(Int($0.frame(in: .global).maxY)) \(Int($0.safeAreaInsets.bottom))" } action: { MapDebug.shared.sheet = $0 }
            #endif
    }

    // MARK: Stops

    private let raisedDetent = PresentationDetent.fraction(0.72)
    /// The least the fit stop asks for: below this the system shrinks the sheet further (Docs/DESIGN.md 4.1), and the floating
    /// capsule with it. The room left over is empty glass-free space above the controls.
    private let leastFit: CGFloat = 100
    /// The fit stop holds its content plus the padding `SheetScroll` puts around it, designed per screen (`SheetHeights`) so the
    /// detent stays the same while the content lays out. Never so tall that the map disappears; past that it scrolls.
    private var fitHeight: CGFloat {
        let content: CGFloat = switch screen {
        case let .place(place): SheetHeights.place(typeSize, fromLine: model.estimateRequest(for: place).map { !$0.origin.isCurrentLocation } ?? false)
        default: SheetHeights.preview(typeSize)
        }
        return sheetHeight(content)
    }
    /// The system adds the bottom safe area to a height detent, and the panel lays out over it.
    private func sheetHeight(_ content: CGFloat) -> CGFloat {
        min(max(content + Layout.sheetTop + Layout.sheetBottom - safeBottom, leastFit), screenHeight * 0.7)
    }
    /// Home's raised sheet is as tall as what it holds: the field, favourites, Recents and its rows, which change as places are used.
    /// At the system's medium it was half a screen of panel under a field and one row. Before the first layout it is sized from what
    /// the rows will take.
    private func homeStopHeight(_ block: CGFloat) -> CGFloat {
        let saved = model.saved
        let rows = CGFloat(min(saved.recents.count, 5) + (saved.favourites.isEmpty ? 1 : 2)) * 52 + (saved.recents.isEmpty ? 0 : 54)
        return sheetHeight(block > 0 ? block : 68 + (saved.favourites.isEmpty ? 0 : 52) + 20 + rows)
    }
    /// A new measure of home adds its stop beside the old one and selects it; the old one goes once the sheet has glided there.
    /// Swapping the one detent for another made the sheet jump.
    private func measuredHome(_ block: CGFloat) {
        let old = PresentationDetent.height(homeStopHeight(homeBlock)), new = PresentationDetent.height(homeStopHeight(block))
        guard old != new else { homeBlock = block; return }
        leavingHome = old
        withAnimation(Motion.panel(reduceMotion)) { homeBlock = block }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if leavingHome == old { leavingHome = nil }
        }
    }
    private func detent(_ stop: Stop) -> PresentationDetent {
        switch stop {
        case .fit: .height(fitHeight)
        case .medium: screen == .home ? .height(homeStopHeight(homeBlock)) : .medium
        case .raised: raisedDetent
        case .large: .large
        }
    }
    private var detents: Set<PresentationDetent> {
        switch screen {
        // Home has one stop, sized to its content: at large it was a flat opaque page holding a search field and one row. Search is the screen that goes large.
        case .home: Set([detent(.medium)] + (leavingHome.map { [$0] } ?? []))
        case .search: [.medium, .large]
        // The place card is all there is to show, so it rests at its own height: raised, it was the card over a blank panel.
        // At accessibility sizes the card can outgrow the fit stop, so large stays.
        case .place: typeSize.isAccessibilitySize ? [detent(.fit), .large] : [detent(.fit)]
        case .preview, .navigating: [detent(.fit), raisedDetent, .large]
        }
    }
    private var stopBinding: Binding<PresentationDetent> {
        // Home's fit stop is the floating controls, with no sheet, so there the sheet is only ever on its way out.
        Binding(get: { screen == .home ? detent(.medium) : detent(stop) }, set: { new in
            model.stop = new == .large ? .large : new == .medium || screen == .home ? .medium : new == raisedDetent ? .raised : .fit
        })
    }
}

/// The map's credits: OpenStreetMap for the streets, Overture for the places.
struct AttributionLinks: View {
    var body: some View {
        HStack(spacing: 4) {
            Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                .accessibilityLabel("Map data © OpenStreetMap contributors")
            Text("·")
            Link("Overture Maps Foundation", destination: URL(string: "https://docs.overturemaps.org/attribution/")!)
                .accessibilityLabel("Places from Overture Maps Foundation")
        }
        .font(.caption2).foregroundStyle(GuidanceOverlay.onGlass).lineLimit(1)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}
