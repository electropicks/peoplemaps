import SwiftUI
import UIKit
import PeoplemapsCore

private enum Sheet: String, Identifiable { case origin, destination, details, about, favourites; var id: String { rawValue } }

private enum Screen: Equatable {
    case home, search, place(Place), preview, navigating
    /// Identity of the panel content, so a new screen crossfades in place.
    var panelID: String { if case let .place(place) = self { "place-\(place.id)" } else { "\(self)" } }
}

/// Where the portrait sheet rests. Fit is sized to what's essential: home's search field and favourites, or the place
/// card; preview is tall enough for the routes and the pinned buttons together.
private enum Stop { case fit, medium, preview, large }

/// Why location can't do what was just asked of it.
private enum LocationNotice: String, Identifiable {
    case startGuidance, locate, outside, noFix
    var id: String { rawValue }
    var title: String {
        switch self {
        case .startGuidance, .locate: "Location is off for PeopleMaps"
        case .outside: "You\u{2019}re outside the area we cover"
        case .noFix: "Can\u{2019}t find you right now"
        }
    }
    var message: String {
        switch self {
        case .startGuidance: "Turn on location in Settings to start guidance. You can still compare routes without it."
        case .locate: "Turn on location in Settings to see where you are and start routes from there. You can still choose a start yourself."
        case .outside: "The map covers Seattle for now, so it can\u{2019}t show where you are. You can still choose a start inside it."
        case .noFix: "Your iPhone hasn\u{2019}t given a location yet. Try again in a moment, or choose a start yourself."
        }
    }
    var offersSettings: Bool { self == .startGuidance || self == .locate }
}

extension TravelMode {
    /// Left to right in every mode picker, as in Apple Maps; the enum's own order stays as it is.
    static let displayOrder: [TravelMode] = [.drive, .bike, .walk]
    /// "18 min drive", "18 min cycle", "18 min walk".
    var trip: String { switch self { case .walk: "walk"; case .bike: "cycle"; case .drive: "drive" } }
    var symbol: String { switch self { case .walk: "figure.walk"; case .bike: "bicycle"; case .drive: "car.fill" } }
}

struct ExploreView: View {
    let graph: StreetGraph
    let search: SearchIndex
    private let router: any RouteComputing
    @State private var session: RouteSession
    @State private var navigator: NavigationController
    /// Nil shows an empty "Choose start" or "Choose destination" field, and no route.
    @State private var origin: Place?
    @State private var destination: Place?
    /// The last mode used; the place card's estimate uses it too.
    @State private var mode: TravelMode = .drive
    @State private var budget = 10
    @State private var selectedCalmer = true
    @State private var sheet: Sheet?
    @State private var screen = Screen.home
    @State private var stop = Stop.fit
    /// Where home was resting, to go back to.
    @State private var homeStop = Stop.fit
    @State private var query = ""
    /// Search was opened by Add in the favourites row: the place picked becomes a favourite.
    @State private var addingFavourite = false
    /// The start the user chose last. Without location, a later Directions reuses it unless it is the new destination.
    @State private var lastOrigin: Place?
    /// The device's last fix, kept only while location is allowed.
    @State private var userLocation: Coordinate?
    /// The nearest indexed address of the open place when it has none of its own.
    @State private var placeNear: String?
    /// The place card's comparison and the request it answers; nil when no route could be found.
    @State private var estimate: (request: RouteRequest, comparison: RouteComparison?)?
    @State private var recenter = 0
    @State private var locateCount = 0
    /// The map is on the user because of Locate; a gesture ends it.
    @State private var centred = false
    /// Height of what the fit stop has to show.
    @State private var fitContent: CGFloat = 60
    @State private var screenHeight: CGFloat = 852
    /// Height the sheet covers now, and at its last rest short of large, which is what the map keeps clear of.
    @State private var sheetCover: CGFloat = 0
    @State private var mapCover: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var camera = GuidanceCamera()
    @State private var guidanceInset = UIEdgeInsets.zero
    @State private var permission = LocationPermission()
    @State private var asking = false
    @State private var notice: LocationNotice?
    @State private var saved = SavedPlacesStore()
    @AppStorage("voiceMuted", store: ExploreView.voiceStore) private var voiceMuted = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    /// UI tests start muted and in their own defaults, so they never change the real preference.
    static let voiceStore: UserDefaults = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), let store = UserDefaults(suiteName: "peoplemaps.uitests") {
            store.set(true, forKey: "voiceMuted")
            return store
        }
        #endif
        return .standard
    }()

    init(graph: StreetGraph, router: any RouteComputing, search: SearchIndex) {
        self.graph = graph; self.search = search
        #if DEBUG
        let computing: any RouteComputing = ProcessInfo.processInfo.arguments.contains("--ui-testing") ? SlowTestRouter(base: router) : router
        #else
        let computing: any RouteComputing = router
        #endif
        self.router = computing
        _session = State(initialValue: RouteSession(router: computing))
        _navigator = State(initialValue: NavigationController(router: router))
    }

    private var selectedPlace: Place? { if case let .place(place) = screen { place } else { nil } }
    /// Where the device is, as a start; nil without location.
    private var here: Place? { userLocation.map(Place.currentLocation(at:)) }
    /// The user's location when the map can show it: inside the area we cover.
    private var userInCoverage: Coordinate? { userLocation.flatMap { graph.contains($0) ? $0 : nil } }
    /// The selected place, or the destination of a preview that has no route yet.
    private var mapSelection: Place? { selectedPlace ?? (screen == .preview && request == nil ? destination : nil) }
    /// Stays set while guiding, so the comparison survives and End returns to the same routes.
    private var previewRequest: RouteRequest? { screen == .preview || screen == .navigating ? request : nil }
    private var guiding: Bool { screen == .navigating && navigator.isActive }
    private var guidance: Guidance? {
        guard guiding, !navigator.routeGeometry.isEmpty else { return nil }
        return Guidance(version: navigator.routeVersion, coordinates: navigator.routeGeometry, calmer: navigator.calmerRoute,
                        destination: navigator.routeGeometry.last!, user: navigator.coordinate, rawUser: navigator.rawCoordinate,
                        reachedRoute: navigator.hasReachedRoute, heading: navigator.heading, moving: navigator.isMoving,
                        camera: camera, inset: guidanceInset)
    }

    /// Asks once, after the map shows on first launch, then takes a fix when allowed. Coming back to the app reads the
    /// answer again (it may have changed in Settings) without asking.
    private func locate(prompting: Bool) async {
        if prompting, permission.access == .undecided {
            if !Motion.off { try? await Task.sleep(for: .milliseconds(600)) }
            asking = true
            _ = await permission.request()
            asking = false
        }
        guard permission.access == .granted else { userLocation = nil; return }
        if let c = await permission.currentCoordinate() { userLocation = Coordinate(lat: c.latitude, lon: c.longitude) }
    }

    /// A start that follows the user moves with each new fix; an empty start fills in once one arrives.
    private func followUser() {
        guard screen != .navigating else { return }
        if origin?.isCurrentLocation ?? true { origin = here }
    }

    /// Locate is always there: it centres on the user when it can, asks if nobody has answered yet, and otherwise says why not.
    private func locateTapped() {
        guard !asking else { return }
        switch permission.access {
        case .denied: notice = .locate
        case .undecided:
            asking = true
            Task {
                _ = await permission.request()
                asking = false
                if permission.access == .granted { await centreOnUser() }
            }
        case .granted: Task { await centreOnUser() }
        }
    }

    private func centreOnUser() async {
        if userLocation == nil { await locate(prompting: false) }
        guard let userLocation else { notice = .noFix; return }
        guard graph.contains(userLocation) else { notice = .outside; return }
        locateCount += 1; centred = true
    }

    /// Guidance needs location, so Start checks permission again and asks if it is still undecided.
    /// The simulated provider path needs none.
    private func startNavigation(_ comparison: RouteComparison) {
        guard !asking else { return }
        #if DEBUG
        if NavigationController.simulating { beginNavigation(comparison); return }
        #endif
        switch permission.access {
        case .granted: beginNavigation(comparison)
        case .denied: notice = .startGuidance
        case .undecided:
            asking = true
            Task {
                let answer = await permission.request()
                asking = false
                if answer == .granted { beginNavigation(comparison) } else { notice = .startGuidance }
            }
        }
    }

    private func beginNavigation(_ comparison: RouteComparison) {
        camera = GuidanceCamera(); guidanceInset = .zero
        navigator.start(comparison: comparison, useCalmer: selectedCalmer && comparison.calmer != nil, muted: voiceMuted)
        if navigator.isActive { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); show(.navigating) }
    }
    private func endNavigation() { navigator.stop(); show(.preview) }
    private func finishNavigation() { navigator.stop(); show(.home) }

    /// Every change of screen goes through here, so the sheet's stop always belongs to the screen's detents.
    private func show(_ next: Screen) {
        if screen == .home, next != .home { homeStop = stop }
        switch next {
        case .home: stop = homeStop
        case .search: stop = .large
        case .place: stop = typeSize.isAccessibilitySize ? .large : .fit
        case .preview: stop = typeSize.isAccessibilitySize ? .large : .preview
        case .navigating: break
        }
        centred = false
        screen = next
    }

    private func open(_ place: Place) {
        let place = search.withAddress(place)
        query = ""
        placeNear = place.address == nil && place.kind == .place && !place.isDroppedPin ? search.nearestAddress(to: place.coordinate)?.name : nil
        show(.place(place))
    }
    /// A search result: its place card, or a new favourite when Add opened the search.
    private func picked(_ place: Place) {
        guard addingFavourite else { open(place); return }
        let place = search.withAddress(place)
        if !saved.isFavourite(place) { saved.toggleFavourite(place) }
        cancelSearch()
    }
    private func cancelSearch() { query = ""; addingFavourite = false; show(.home) }
    /// Long-press drops a pin while browsing, never over a route or guidance.
    private func dropPin(_ c: Coordinate) {
        guard screen == .home || selectedPlace != nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        open(search.droppedPin(at: c))
    }

    /// Current location when allowed; otherwise the start the user chose last, unless that is where they are going.
    private func start(for place: Place) -> Place? {
        here ?? lastOrigin.flatMap { $0.id == place.id || $0.isCurrentLocation ? nil : $0 }
    }

    private func startDirections(to place: Place) {
        origin = start(for: place); destination = place
        saved.addRecent(place)
        show(.preview)
    }

    private var request: RouteRequest? {
        guard let origin, let destination, graph.contains(origin.coordinate) else { return nil }
        return .init(origin: origin, destination: destination, mode: mode, extraMinutes: budget)
    }
    /// Landscape on a phone: the panel becomes a floating card at the leading edge.
    private var landscape: Bool { verticalSizeClass == .compact }
    private var coverage: [Coordinate] { [Coordinate(lat: graph.bounds[0], lon: graph.bounds[1]), Coordinate(lat: graph.bounds[2], lon: graph.bounds[3])] }
    private let cardWidth: CGFloat = 330
    private var inset: CGFloat { landscape ? Layout.cardInset : Layout.inset }

    // MARK: Sheet stops

    private let previewDetent = PresentationDetent.fraction(0.66)
    /// The system adds room for the home indicator itself. Never so tall that the map disappears; past that it scrolls.
    private var fitHeight: CGFloat { min(fitContent + 6, screenHeight * 0.7) }
    private func detent(_ stop: Stop) -> PresentationDetent {
        switch stop {
        case .fit: .height(fitHeight)
        case .medium: .medium
        case .preview: previewDetent
        case .large: .large
        }
    }
    private var detents: Set<PresentationDetent> {
        switch screen {
        case .home, .search, .place: [detent(.fit), .medium, .large]
        case .preview, .navigating: [.medium, previewDetent, .large]
        }
    }
    private var stopBinding: Binding<PresentationDetent> {
        Binding(get: { detent(stop) }, set: { new in
            stop = new == .large ? .large : new == .medium ? .medium : new == previewDetent ? .preview : .fit
        })
    }
    private var sheetUp: Binding<Bool> { Binding(get: { !landscape && screen != .navigating }, set: { _ in }) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                SeattleMap(comparison: screen == .preview ? session.comparison : nil, selectedCalmer: selectedCalmer, recenter: recenter, locate: locateCount, selected: mapSelection,
                           user: userInCoverage, coverage: coverage, onLongPress: dropPin, guidance: guidance,
                           onCameraGesture: { if guiding { camera.pan() } else if centred { centred = false } }, padding: mapPadding(geo))
                    .ignoresSafeArea()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(screen == .preview ? "Seattle offline map. Routes are also described in the panel." : "Seattle offline map")
                if screen == .navigating {
                    GuidanceOverlay(navigator: navigator, landscape: landscape, cardWidth: cardWidth, attribution: AnyView(attribution), camera: $camera, muted: $voiceMuted,
                                    onInsets: { guidanceInset = $0 }, onEnd: endNavigation, onDone: finishNavigation)
                        .transition(.opacity)
                } else if landscape { landscapeLayout(geo).transition(.opacity) } else { portraitChrome(geo).transition(.opacity) }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") { NavigationDebugProbe(navigator: navigator) }
                #endif
            }
            .animation(Motion.panel(reduceMotion), value: screen)
            .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: { screenHeight = $0 }
        }
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: sheetUp) { portraitSheet }
        .task(id: previewRequest) {
            if let previewRequest { selectedCalmer = true; session.start(previewRequest) } else { session.cancel() }
        }
        .task { await locate(prompting: true) }
        .onDisappear { session.cancel(); navigator.stop() }
        .onChange(of: voiceMuted) { navigator.setMuted(voiceMuted) }
        .reportContext(screen: String(String(describing: screen).prefix { $0 != "(" }), mode: mode, extraMinutes: budget, comparison: session.comparison, navigator: navigator, dataVersion: search.dataVersion)
        .onChange(of: userLocation) { followUser() }
        // Pulling the search sheet down is the same as Cancel, at wherever it was let go.
        .onChange(of: stop) { if screen == .search, stop != .large { homeStop = stop; query = ""; addingFavourite = false; screen = .home } }
        .onChange(of: scenePhase) {
            if scenePhase == .background { navigator.pause() } else if scenePhase == .active {
                navigator.resume()
                if !asking { Task { await locate(prompting: false) } }
            }
        }
    }

    /// Alerts and sheets belong to whatever is on top: the persistent sheet in portrait, the card in landscape.
    private func presenting<Content: View>(_ content: Content) -> some View {
        content
            .alert(notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }), presenting: notice) { notice in
                if notice.offersSettings {
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    Button("Not Now", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { Text($0.message) }
            .sheet(item: $sheet) { item in
                switch item {
                case .origin:
                    PlacePicker(title: "Starting from", search: search, selected: origin, saved: saved, location: permission) { place in
                        origin = place; lastOrigin = place
                        if place.isCurrentLocation { userLocation = place.coordinate }
                    }
                case .destination:
                    PlacePicker(title: "Going to", search: search, selected: destination, saved: saved) { destination = $0; saved.addRecent($0) }
                case .details:
                    if let comparison = session.comparison { RouteDetails(comparison: comparison) }
                case .about:
                    AboutView(graph: graph)
                case .favourites:
                    FavouritesEditor(saved: saved)
                }
            }
    }

    /// Keeps fitted routes clear of the panel, the map buttons and the attribution. Home keeps clear of the fit stop only,
    /// so pulling the sheet up never moves a map the user has panned.
    private func mapPadding(_ geo: GeometryProxy) -> UIEdgeInsets {
        let safe = geo.safeAreaInsets
        if screen == .home {
            // Home frames the user's neighbourhood or the area we cover: clear of the panel and the map buttons, 48 pt elsewhere.
            if landscape { return UIEdgeInsets(top: safe.top + 48, left: safe.leading + 12 + cardWidth + 24, bottom: safe.bottom + 48, right: safe.trailing + 16 + 44 + 24) }
            return UIEdgeInsets(top: safe.top + 48, left: 48, bottom: fitHeight + 48, right: 16 + 44 + 24)
        }
        if landscape {
            return UIEdgeInsets(top: safe.top + 24, left: safe.leading + 12 + cardWidth + 32, bottom: safe.bottom + 36, right: safe.trailing + 16 + 44 + 24)
        }
        return UIEdgeInsets(top: safe.top + 24, left: 32, bottom: max(mapCover, safe.bottom) + 40, right: 16 + 44 + 16)
    }

    /// The map buttons and attribution over the map; the sheet itself is a system sheet above them. Both fade out once the sheet is large.
    private func portraitChrome(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            HStack { Spacer(); mapButtons }.padding(.horizontal, 16).padding(.top, 8)
            Spacer(minLength: 0)
            HStack { attribution; Spacer() }.padding(.horizontal, 12)
                .padding(.bottom, max(sheetCover - geo.safeAreaInsets.bottom, 0) + 8)
        }
        .opacity(stop == .large ? 0 : 1)
        .allowsHitTesting(stop != .large)
        .accessibilityHidden(stop == .large)
        .animation(Motion.content(reduceMotion), value: stop)
    }

    private var portraitSheet: some View {
        presenting(panel)
            .presentationDetents(detents, selection: stopBinding)
            .presentationBackgroundInteraction(.enabled(upThrough: screen == .preview ? previewDetent : .medium))
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
            .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.bottom } action: { height in
                sheetCover = height
                if stop != .large, screen != .search { mapCover = height }
            }
    }

    private func landscapeLayout(_ geo: GeometryProxy) -> some View {
        // The card may run into the bottom safe area: the home indicator sits clear of it, at the screen's centre.
        let height = geo.size.height + geo.safeAreaInsets.bottom - 24
        return HStack(alignment: .top, spacing: 0) {
            presenting(panel)
                .frame(width: cardWidth)
                .frame(maxHeight: height)
                .frame(height: screen == .search ? height : nil)
                .clipShape(RoundedRectangle(cornerRadius: Layout.groupRadius + Layout.cardInset))
                .floatingSurface(in: RoundedRectangle(cornerRadius: Layout.groupRadius + Layout.cardInset))
                .padding(.vertical, 12).padding(.leading, 12)
            Spacer(minLength: 16)
            VStack(alignment: .trailing) {
                mapButtons
                Spacer()
                attribution
            }.padding(.vertical, 12).padding(.trailing, 16)
        }.ignoresSafeArea(.container, edges: .bottom)
    }

    /// Whichever screen is up. Old and new content overlap while they crossfade.
    private var panel: some View {
        ZStack(alignment: .top) {
            Group {
                switch screen {
                case .home: scrolling { homeContent }
                case .search: searchPanel
                case let .place(place): scrolling { placeContent(place) }
                case .preview: previewPanel
                case .navigating: EmptyView()
                }
            }.id(screen.panelID).transition(.opacity)
        }
        .tint(.primary)
        .animation(Motion.content(reduceMotion), value: screen.panelID)
    }

    /// Scrolls whenever the content is taller than the room it has. In landscape the card also sizes itself to the content.
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, inset).padding(.top, landscape ? Layout.cardInset : 20).padding(.bottom, 12)
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

    /// One glass capsule: Locate, always there, and Fit.
    private var mapButtons: some View {
        GlassEffectContainer {
            VStack(spacing: 0) {
                Button(action: locateTapped) {
                    Image(systemName: centred ? "location.fill" : "location").frame(width: 44, height: 44)
                        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                }
                .accessibilityLabel("Show my location")
                .accessibilityValue(centred ? "Centred" : userInCoverage != nil ? "Found" : "")
                .accessibilityIdentifier("locate")
                Divider().frame(width: 44)
                Button { recenter += 1; centred = false } label: { Image(systemName: "viewfinder").frame(width: 44, height: 44) }
                    .accessibilityLabel(screen == .preview && request != nil ? "Fit routes on map" : selectedPlace != nil ? "Centre on this place" : "Fit map to Seattle")
                    .accessibilityIdentifier("recenter")
            }
            .buttonStyle(.plain)
            .font(.system(size: 19)).foregroundStyle(.primary)
            .floatingSurface(in: Capsule())
        }
    }

    private var attribution: some View {
        HStack(spacing: 4) {
            Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                .accessibilityLabel("Map data © OpenStreetMap contributors")
            Text("·")
            Link("Overture Maps Foundation", destination: URL(string: "https://docs.overturemaps.org/attribution/")!)
                .accessibilityLabel("Places from Overture Maps Foundation")
        }
        .font(.caption2).foregroundStyle(GuidanceOverlay.onGlass).lineLimit(1)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .floatingSurface(in: Capsule())
    }

    // MARK: Home

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Button { show(.search) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("Where to?")
                        Spacer(minLength: 0)
                    }
                    .font(.body).foregroundStyle(GuidanceOverlay.onGlass).padding(.horizontal, 12).frame(minHeight: 44)
                    .background(.fill.tertiary, in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityLabel("Where to?").accessibilityHint("Search places and addresses").accessibilityIdentifier("search-field")
                if !saved.favourites.isEmpty {
                    FavouritesRow(favourites: saved.favourites, onOpen: open,
                                  onRemove: { place in withAnimation(Motion.panel(reduceMotion)) { saved.removeFavourite(place) } },
                                  onAdd: { addingFavourite = true; show(.search) },
                                  onEdit: { sheet = .favourites })
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                }
                if saved.favourites.isEmpty && saved.recents.isEmpty {
                    Text("Search a place or address, or long-press the map").font(.footnote).foregroundStyle(GuidanceOverlay.onGlass)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4).accessibilityIdentifier("home-hint")
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fitContent = $0 }
            if !saved.recents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recents").font(.footnote.weight(.semibold)).foregroundStyle(GuidanceOverlay.onGlass).padding(.leading, 4)
                        .accessibilityAddTraits(.isHeader)
                    PlaceList(places: Array(saved.recents.prefix(landscape ? 3 : 5)), minHeight: landscape ? 46 : 52, identifier: { "home-recent-\($0.id)" }, action: open)
                }
            }
            Button { sheet = .about } label: {
                Label("About PeopleMaps", systemImage: "info.circle").font(.subheadline).foregroundStyle(GuidanceOverlay.onGlass)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.leading, 4).accessibilityIdentifier("about")
        }
    }

    // MARK: Search

    private var results: [Place] { search.search(query, near: userLocation ?? origin?.coordinate ?? lastOrigin?.coordinate) }

    private var searchPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FocusedSearchField(text: $query, placeholder: addingFavourite ? "Add a favourite" : "Where to?")
                Button("Cancel", action: cancelSearch).font(.body).foregroundStyle(.primary).accessibilityIdentifier("cancel-search-home")
            }.padding(.horizontal, inset).padding(.top, landscape ? Layout.cardInset : 20).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if query.isEmpty {
                        if !saved.recents.isEmpty { resultGroup("Recents", saved.recents, prefix: "recent-") }
                    } else if results.isEmpty {
                        EmptySearch(count: search.count).padding(.top, 48)
                        AppleMapsLookup(query: query)
                    } else {
                        resultGroup("Top match", Array(results.prefix(1)))
                        if results.count > 1 { resultGroup("Other matches", Array(results.dropFirst())) }
                    }
                }.padding(.horizontal, inset).padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively).scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    private func resultGroup(_ title: String, _ places: [Place], prefix: String = "result-") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4).accessibilityAddTraits(.isHeader)
            PlaceList(places: places, query: query, identifier: { prefix + $0.id }, action: picked)
        }
    }

    // MARK: Place card

    private func placeContent(_ place: Place) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if typeSize.isAccessibilitySize {
                // The name needs the full width at these sizes, or it breaks mid-word beside the buttons.
                HStack(alignment: .top, spacing: 12) {
                    placeBadge(place)
                    Spacer(minLength: 0)
                    favouriteButton(place)
                    closeButton(label: "Close", id: "close-place") { show(.home) }
                }
                placeTitle(place)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    placeBadge(place)
                    placeTitle(place)
                    Spacer(minLength: 0)
                    favouriteButton(place)
                    closeButton(label: "Close", id: "close-place") { show(.home) }
                }
            }
            if graph.contains(place.coordinate) {
                directionsButton(place).dynamicTypeSize(...DynamicTypeSize.accessibility1)
                estimateNotes(place)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Outside the area we cover yet").font(.headline)
                    Text("PeopleMaps can route only inside its offline Seattle area for now.").font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.panelFill, in: RoundedRectangle(cornerRadius: Layout.groupRadius))
                .accessibilityElement(children: .combine).accessibilityIdentifier("outside-coverage")
            }
            if let source = place.source { Text(source).font(.caption).foregroundStyle(GuidanceOverlay.onGlass).accessibilityIdentifier("place-source") }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fitContent = $0 }
        .task(id: estimateRequest(for: place)) { await loadEstimate(estimateRequest(for: place)) }
    }

    private func placeBadge(_ place: Place) -> some View {
        CategoryBadge(badge: place.badge, raw: place.category, size: 44).dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func placeTitle(_ place: Place) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(place.shortName).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(place.subtitle(near: placeNear)).font(.subheadline).foregroundStyle(GuidanceOverlay.onGlass)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("place-subtitle")
        }
    }

    /// From where Directions would start, in the last-used mode, when both ends are inside the area we cover.
    private func estimateRequest(for place: Place) -> RouteRequest? {
        guard graph.contains(place.coordinate), let from = start(for: place), graph.contains(from.coordinate) else { return nil }
        return .init(origin: from, destination: place, mode: mode, extraMinutes: budget)
    }

    /// Runs off the main thread; SwiftUI cancels it when the card closes or shows another place.
    private func loadEstimate(_ request: RouteRequest?) async {
        guard let request else { return }
        let comparison = try? await router.compare(request)
        guard !Task.isCancelled else { return }
        estimate = (request, comparison)
    }

    /// The route Start will default to, never the fastest when a calmer one exists: "Calmer: 16–19 min, 6.2 mi" over
    /// "Yikes → Chill, mostly fewer unsignalled lefts". Plain "Directions" until it's estimated.
    private func directionsButton(_ place: Place) -> some View {
        let ready = readyEstimate(for: place)
        return Button { startDirections(to: place) } label: {
            Group {
                if let ready {
                    VStack(spacing: 2) {
                        Label(ready.comparison.startHeadline, systemImage: ready.request.mode.symbol).font(.body.weight(.semibold))
                        Text(ready.comparison.calmSummary).font(.subheadline)
                    }
                } else {
                    Label("Directions", systemImage: "arrow.right").font(.body.weight(.semibold))
                }
            }
            .monospacedDigit().multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.directionsText)
            .frame(maxWidth: .infinity, minHeight: 32).padding(.vertical, 2)
        }
        .buttonStyle(.glassProminent).buttonBorderShape(typeSize.isAccessibilitySize ? .roundedRectangle(radius: Layout.groupRadius) : .capsule)
        .tint(.directionsFill).controlSize(.large)
        .accessibilityLabel("Directions")
        .accessibilityValue(ready.map { spokenEstimate($0.comparison, mode: $0.request.mode) } ?? "")
        .accessibilityIdentifier("directions")
    }

    private func spokenEstimate(_ comparison: RouteComparison, mode: TravelMode) -> String {
        let route = comparison.calmer ?? comparison.fastest
        let name = comparison.calmer == nil ? "" : "Calmer route, "
        return "\(name)\(route.spokenTimeRange) \(mode.trip), \(DistanceFormat.distance(route.metrics.meters, spoken: true)), \(comparison.spokenCalmSummary), estimate without live traffic"
    }

    private func readyEstimate(for place: Place) -> (request: RouteRequest, comparison: RouteComparison)? {
        guard let request = estimateRequest(for: place), let estimate, estimate.request == request,
              let comparison = estimate.comparison else { return nil }
        return (request, comparison)
    }

    /// What the button can't say: where the estimate starts when that isn't here, and that it is an estimate.
    @ViewBuilder private func estimateNotes(_ place: Place) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let ready = readyEstimate(for: place) {
                if !ready.request.origin.isCurrentLocation {
                    Text("From \(ready.request.origin.shortName)").font(.subheadline).foregroundStyle(GuidanceOverlay.onGlass)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("place-estimate")
                }
                Text("Estimate, no live traffic").font(.footnote).foregroundStyle(GuidanceOverlay.onGlass)
            } else if estimateRequest(for: place) != nil, estimate?.request != estimateRequest(for: place) {
                Text("Estimating\u{2026}").font(.subheadline).foregroundStyle(GuidanceOverlay.onGlass).accessibilityIdentifier("place-estimate-loading")
            } else {
                Text("Compares the fastest route with a calmer one. Works offline.").font(.footnote).foregroundStyle(GuidanceOverlay.onGlass)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 4)
    }

    private func favouriteButton(_ place: Place) -> some View {
        let on = saved.isFavourite(place)
        return Button { withAnimation(Motion.content(reduceMotion)) { saved.toggleFavourite(place) } } label: {
            Image(systemName: on ? "star.fill" : "star").font(.system(size: 14, weight: .semibold))
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .frame(width: 30, height: 30).background(Color(uiColor: .tertiarySystemFill), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(on ? "Remove from Favourites" : "Add to Favourites")
            .accessibilityIdentifier("favourite")
    }

    private func closeButton(label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30).background(Color(uiColor: .tertiarySystemFill), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    // MARK: Route preview

    /// Scrolls at any text size, with Start and Why this route pinned under it, so neither is ever clipped.
    private var previewPanel: some View {
        VStack(spacing: 0) {
            scrolling { previewContent }
            if request != nil, let comparison = session.comparison {
                // The landscape card has no height to spare, so its buttons stay side by side at a capped size.
                let stacked = typeSize.isAccessibilitySize && !landscape
                let line = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                line {
                    Button { startNavigation(comparison) } label: {
                        Text("Start").font(.body.weight(.semibold)).foregroundStyle(.directionsText).frame(maxWidth: .infinity, minHeight: landscape ? 22 : 32)
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(.directionsFill).controlSize(.large)
                    .accessibilityIdentifier("start-navigation")
                    Button { sheet = .details } label: {
                        Text("Why this route").font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(stacked ? 2 : 1)
                            .fixedSize(horizontal: !stacked, vertical: false)
                            .frame(maxWidth: stacked ? .infinity : nil, minHeight: landscape ? 22 : 32)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.secondary).controlSize(.large)
                    .accessibilityHint(comparison.spokenCalmSummary)
                    .accessibilityIdentifier("route-details")
                }
                .dynamicTypeSize(...(landscape ? DynamicTypeSize.xxLarge : .accessibility2))
                .padding(.horizontal, inset).padding(.top, 8).padding(.bottom, landscape ? Layout.cardInset : 8)
            }
        }
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: landscape ? 8 : 12) {
            HStack {
                Text("Directions").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                closeButton(label: "Close routes", id: "close-preview") { show(.home) }
            }.frame(minHeight: 30)
            places
            Picker("Travel mode", selection: $mode) {
                ForEach(TravelMode.displayOrder) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).sensoryFeedback(.selection, trigger: mode)
            extraTime.sensoryFeedback(.selection, trigger: budget)
            // Route preferences add their "Calmer means" row here, directly under extra time (Docs/DESIGN.md 4.5).
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: landscape ? 8 : 12) {
                    if request == nil { needsPlace } else { stateContent }
                }.id(request == nil ? "needs-place" : stateID).transition(.opacity)
            }
            .animation(Motion.content(reduceMotion), value: request == nil ? "needs-place" : stateID)
            // Pulled all the way up there's room to explain the rating here too.
            if stop == .large, !landscape, request != nil, let comparison = session.comparison {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calm estimate").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    CalmBar(comparison: comparison)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.panelFill, in: RoundedRectangle(cornerRadius: Layout.groupRadius))
            }
        }
    }

    private func extraLabel(_ minutes: Int) -> String { minutes == 0 ? "None" : "\(minutes) min" }

    /// A menu at the shorter stops; the full segmented control when there's room.
    @ViewBuilder private var extraTime: some View {
        let title = "Most extra time for a calmer route"
        if landscape || stop == .large {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.footnote).foregroundStyle(GuidanceOverlay.onGlass).fixedSize(horizontal: false, vertical: true)
                Picker("Extra time", selection: $budget) {
                    ForEach([0, 2, 5, 10], id: \.self) { Text(extraLabel($0)).tag($0) }
                }.pickerStyle(.segmented)
            }
        } else {
            Menu {
                Picker("Extra time", selection: $budget) {
                    ForEach([10, 5, 2, 0], id: \.self) { Text(extraLabel($0)).tag($0) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(title).foregroundStyle(.primary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(extraLabel(budget)).foregroundStyle(.secondary).monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .font(.subheadline).padding(.horizontal, 14).frame(minHeight: 44)
                .background(.panelFill, in: RoundedRectangle(cornerRadius: Layout.groupRadius)).contentShape(Rectangle())
            }
            .accessibilityLabel(title).accessibilityValue(extraLabel(budget)).accessibilityIdentifier("extra-time-menu")
        }
    }

    /// Identity of the comparison state, so loading, results and errors crossfade.
    private var stateID: String {
        switch session.state {
        case .idle, .loading: "loading"
        case .cancelled: "cancelled"
        case let .failed(message): "failed-\(message)"
        case let .ready(comparison): "ready-\(comparison.fastest.id)-\(comparison.calmer?.id ?? "none")"
        }
    }

    /// No start (location off or unavailable), a start outside the area we cover, or no destination yet: say what to do, and show no route.
    private var needsPlace: some View {
        let outside = origin.map { !graph.contains($0.coordinate) } ?? false
        return card {
            VStack(alignment: .leading, spacing: 6) {
                Text(outside ? "Your start is outside the area we cover" : origin == nil ? "Choose a start to compare routes." : "Choose a destination to compare routes.")
                    .font(outside ? .headline : .subheadline).foregroundStyle(outside ? .primary : .secondary).fixedSize(horizontal: false, vertical: true)
                if outside {
                    Text("PeopleMaps can route only inside its offline Seattle area for now. Choose a start inside it.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Choose start") { sheet = .origin }.font(.subheadline.weight(.semibold)).padding(.top, 2)
                }
            }.padding(14).frame(maxWidth: .infinity, minHeight: routeListHeight, alignment: .leading)
        }.accessibilityIdentifier(outside ? "start-outside-coverage" : "needs-place")
    }

    private var places: some View {
        HStack(spacing: 4) {
            VStack(spacing: 0) {
                placeButton(place: origin, target: .origin)
                Divider().padding(.leading, 26)
                placeButton(place: destination, target: .destination)
            }
            Button {
                withAnimation(Motion.content(reduceMotion)) { let previous = origin; origin = destination; destination = previous }
            } label: { Image(systemName: "arrow.up.arrow.down").font(.body).foregroundStyle(.secondary).dynamicTypeSize(...DynamicTypeSize.xxLarge).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("Swap start and destination").accessibilityIdentifier("swap")
        }
        .padding(.leading, 14).padding(.trailing, 4)
        .background(.panelFill, in: RoundedRectangle(cornerRadius: Layout.groupRadius))
    }

    private func placeButton(place: Place?, target: Sheet) -> some View {
        let origin = target == .origin
        let empty = origin ? "Choose start" : "Choose destination"
        return Button { sheet = target } label: {
            HStack(spacing: 12) {
                Group {
                    if origin { Circle().strokeBorder(.primary, lineWidth: 2.5) } else { Circle().fill(.calmer) }
                }.frame(width: 14, height: 14)
                Text(place?.shortName ?? empty).font(.body).foregroundStyle(place == nil ? .secondary : .primary).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                Spacer(minLength: 0)
            }.frame(minHeight: landscape ? 40 : 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(place.map { "\(origin ? "Starting from" : "Going to"), \($0.shortName)" } ?? empty)
            .accessibilityIdentifier("choose-\(target.rawValue)")
    }

    @ViewBuilder private var stateContent: some View {
        switch session.state {
        case .idle, .loading:
            card {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Comparing Seattle streets…").font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Cancel") { session.cancel() }.font(.subheadline).accessibilityIdentifier("cancel-route")
                }.padding(.horizontal, 14).frame(minHeight: routeListHeight)
            }
        case .cancelled:
            status(title: "Comparison paused", message: "Your places are still here.", button: "Compare routes")
        case let .failed(message):
            status(title: "Try another route", message: message, button: "Try again")
        case let .ready(comparison):
            card {
                if let calmer = comparison.calmer {
                    routeRow(calmer, title: "Calmer", extra: comparison.extraTimeLabel, detail: comparison.calmSummary,
                             spoken: "\(comparison.extraTimeLabel), \(comparison.spokenCalmSummary)", selected: selectedCalmer, calmer: true)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "equal.circle").font(.title3).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(comparison.noCalmer.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                            Text(comparison.noCalmer.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: rowHeight)
                        .accessibilityElement(children: .combine).accessibilityIdentifier("no-alternative")
                }
                Divider().padding(.leading, 30)
                let word = comparison.fastestCalm.level.title
                routeRow(comparison.fastest, title: "Fastest", detail: "\(word) · Estimate, no live traffic", spoken: "\(word), estimate, no live traffic",
                         selected: !selectedCalmer || comparison.calmer == nil, calmer: false)
            }
        }
    }

    private var rowHeight: CGFloat { landscape ? 50 : 60 }
    private var routeListHeight: CGFloat { rowHeight * 2 + 1 }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.panelFill, in: RoundedRectangle(cornerRadius: Layout.groupRadius))
    }

    private func routeRow(_ route: Route, title: String, extra: String? = nil, detail: String, spoken: String, selected: Bool, calmer: Bool) -> some View {
        Button { withAnimation(Motion.content(reduceMotion)) { selectedCalmer = calmer } } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(calmer ? Color.calmer : Color.fastest).frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    let line = typeSize.isAccessibilitySize || landscape ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                    line {
                        Text(title).font(.headline).foregroundStyle(.primary)
                        Text([route.timeRange, route.distance, extra].compactMap { $0 }.joined(separator: " · ")).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(detail).font(.footnote).foregroundStyle(calmer ? Color.calmerText : Color.secondary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(calmer ? Color.calmer : Color.fastest)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, landscape ? 6 : 10)
            .frame(minHeight: rowHeight).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(title) route, \(route.spokenTimeRange), \(DistanceFormat.distance(route.metrics.meters, spoken: true)). \(spoken)")
            .accessibilityIdentifier(calmer ? "route-calmer" : "route-fastest")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func status(title: String, message: String, button: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(button) { if let request { session.start(request) } }.font(.subheadline.weight(.semibold)).padding(.top, 2)
                    .accessibilityIdentifier("retry-route")
            }.padding(14).frame(maxWidth: .infinity, minHeight: routeListHeight, alignment: .leading)
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
