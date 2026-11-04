import SwiftUI
import UIKit
import PeoplemapsCore

private enum Sheet: String, Identifiable { case origin, destination, details, about, favourites, preferences; var id: String { rawValue } }

private enum Screen: Equatable {
    case home, search, place(Place), preview, navigating
    /// Identity of the panel content, so a new screen crossfades in place.
    var panelID: String { if case let .place(place) = self { "place-\(place.id)" } else { "\(self)" } }
}

/// Where the portrait sheet rests. Fit is sized to what's essential: home's search capsule and favourites, the place card, or
/// the preview's rating and buttons. Raised is the preview with its start, swap and extra time as well.
private enum Stop { case fit, medium, raised, large }

/// Why location can't do what was just asked of it.
private enum LocationNotice: String, Identifiable {
    case startGuidance, locate, outside, noFix, record
    var id: String { rawValue }
    var title: String {
        switch self {
        case .startGuidance, .locate, .record: "Location is off for PeopleMaps"
        case .outside: "You\u{2019}re outside the area we cover"
        case .noFix: "Can\u{2019}t find you right now"
        }
    }
    var message: String {
        switch self {
        case .startGuidance: "Turn on location in Settings to start guidance. You can still compare routes without it."
        case .locate: "Turn on location in Settings to see where you are and start routes from there. You can still choose a start yourself."
        case .record: "Turn on location in Settings to record. A recording keeps running in the background until you stop it."
        case .outside: RegionSelection.usesCounty ? "\(RegionSelection.coverageSentence) It can\u{2019}t show where you are from here. You can still choose a start inside it."
            : "The map covers Seattle for now, so it can\u{2019}t show where you are. You can still choose a start inside it."
        case .noFix: "Your iPhone hasn\u{2019}t given a location yet. Try again in a moment, or choose a start yourself."
        }
    }
    var offersSettings: Bool { self == .startGuidance || self == .locate || self == .record }
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
    /// Compass heading, only while the map shows the user outside guidance; nil draws a plain dot.
    @State private var compass = CompassHeading()
    /// The nearest indexed address of the open place when it has none of its own.
    @State private var placeNear: String?
    /// The place card's comparison and the request it answers; nil when no route could be found.
    @State private var estimate: (request: RouteRequest, comparison: RouteComparison?)?
    @State private var recenter = 0
    @State private var locateCount = 0
    /// The map is on the user because of Locate; a gesture ends it.
    @State private var centred = false
    /// Height of what the fit stop has to show: home or the place card, or the preview's scrolling part and its pinned part.
    @State private var fitContent: CGFloat = 60
    @State private var previewBlock: CGFloat = 200
    @State private var previewPinned: CGFloat = 110
    @State private var screenHeight: CGFloat = 852
    @State private var safeBottom: CGFloat = 0
    /// Height the sheet covers now, and at its last rest short of large, which is what the map keeps clear of.
    @State private var sheetCover: CGFloat = 0
    @State private var mapCover: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var camera = GuidanceCamera()
    @State private var guidanceInset = UIEdgeInsets.zero
    @State private var permission = LocationPermission()
    @State private var recorder = ManualRecorder.shared
    @AppStorage(DriveLogger.enabledKey, store: ExploreView.voiceStore) private var detailedLogOn = false
    @State private var asking = false
    @State private var notice: LocationNotice?
    @State private var saved = SavedPlacesStore()
    /// The map's place markers, ready shortly after launch; home never waits for them.
    @State private var markerFeed: PlaceMarkerFeed?
    /// What the map last drew, for VoiceOver.
    @State private var visiblePlaces: [VisiblePlace] = []
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var preferences = RoutePreferencesStore()
    @AppStorage("voiceMuted", store: ExploreView.voiceStore) private var voiceMuted = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
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
    private var userInCoverage: Coordinate? { userLocation.flatMap { graph.coverage.contains($0) ? $0 : nil } }
    /// The selected place, or the destination of a preview that has no route yet.
    private var mapSelection: Place? { selectedPlace ?? (screen == .preview && request == nil ? destination : nil) }
    /// Stays set while guiding, so the comparison survives and End returns to the same routes.
    private var previewRequest: RouteRequest? { screen == .preview || screen == .navigating ? request : nil }
    /// The map's own arrow: the user is on it and not guiding (guidance draws its marker from the navigator).
    private var wantsCompass: Bool { userInCoverage != nil && !guiding && scenePhase == .active }
    /// Core Location's heading is wanted outside guidance for that arrow, and while guiding for the marker and camera at a stop.
    private var runsCompass: Bool { (userInCoverage != nil || guiding) && scenePhase == .active }
    private func updateCompass() {
        permission.onHeading = { [compass, navigator] degrees in compass.degrees = degrees; navigator.setCompass(degrees) }
        permission.compass(on: runsCompass, precise: guiding)
    }
    private var guiding: Bool { screen == .navigating && navigator.isActive }
    private var guidance: Guidance? {
        guard guiding, !navigator.routeGeometry.isEmpty else { return nil }
        return Guidance(version: navigator.routeVersion, coordinates: navigator.routeGeometry, calmer: navigator.calmerRoute,
                        destination: navigator.routeGeometry.last!, user: navigator.coordinate, rawUser: navigator.rawCoordinate,
                        reachedRoute: navigator.hasReachedRoute, heading: navigator.heading, compass: navigator.compass, moving: navigator.isMoving, travelled: navigator.travelledMeters,
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
        guard graph.coverage.contains(userLocation) else { notice = .outside; return }
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

    /// Places show while browsing, never over a route or guidance.
    private var showsPlaces: Bool { screen == .home || screen == .search || selectedPlace != nil }
    /// Map symbols are invisible to VoiceOver, so the ones on screen get elements of their own. UI tests read them too.
    private var reportsPlaces: Bool { voiceOver || Motion.off }
    /// `--no-place-markers`, in debug builds: the map without markers, to measure what they cost.
    private static var markersOff: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--no-place-markers")
        #else
        return false
        #endif
    }

    private func openMarker(_ id: String) {
        guard showsPlaces, let place = search.place(id: id) else { return }
        open(place)
    }

    /// One element per marker on screen, at its place on the map. Taps fall through to the map, which is what opens the card.
    private var placeElements: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(visiblePlaces) { place in
                Color.clear.frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityElement()
                    .accessibilityLabel("\(place.name), \(place.kind)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { openMarker(place.id) }
                    .accessibilityIdentifier("map-place-\(place.id)")
                    .position(place.point)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Every change of screen goes through here, so the sheet's stop always belongs to the screen's detents.
    private func show(_ next: Screen) {
        if screen == .home, next != .home { homeStop = stop }
        switch next {
        case .home: stop = homeStop
        case .search: stop = .large
        case .place: stop = typeSize.isAccessibilitySize ? .large : .fit
        case .preview: stop = typeSize.isAccessibilitySize ? .large : .fit
        case .navigating: break
        }
        centred = false
        screen = next
    }

    /// What the detailed log's app-use file watches (`App/Reports/DriveLogHooks.swift`).
    private var driveLogSnapshot: DriveLogSnapshot {
        DriveLogSnapshot(screen: String(String(describing: screen).prefix { $0 != "(" }), place: selectedPlace, query: query, mode: mode, budget: budget,
                         sheet: sheet?.rawValue, calmer: selectedCalmer,
                         request: previewRequest.map { "\($0.destination.id) \($0.mode) \($0.extraMinutes)" }, destination: previewRequest?.destination,
                         routeReady: session.comparison != nil)
    }

    private func open(_ place: Place) {
        let place = search.withAddress(place)
        query = ""
        placeNear = place.address == nil && place.kind == .place && !place.isDroppedPin ? search.nearestAddress(to: place.coordinate)?.name : nil
        show(.place(place))
    }
    /// A search result: its place card, or a new favourite when Add opened the search.
    private func picked(_ place: Place) {
        DriveLogger.use("search_pick", ["query": .string(query), "id": .string(place.id), "name": .string(place.name),
                                        "rank": .num(results.firstIndex { $0.id == place.id } ?? -1), "results": .num(results.count), "addingFavourite": .bool(addingFavourite)])
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
        guard let origin, let destination, graph.coverage.contains(origin.coordinate) else { return nil }
        return .init(origin: origin, destination: destination, mode: mode, extraMinutes: budget, preferences: preferences[mode])
    }
    /// Landscape on a phone: the panel becomes a floating card at the leading edge.
    private var landscape: Bool { verticalSizeClass == .compact }
    private var coverage: [Coordinate] { [Coordinate(lat: graph.bounds[0], lon: graph.bounds[1]), Coordinate(lat: graph.bounds[2], lon: graph.bounds[3])] }
    private let cardWidth: CGFloat = 330
    private var inset: CGFloat { landscape ? Layout.cardInset : Layout.inset }

    // MARK: Sheet stops

    private let raisedDetent = PresentationDetent.fraction(0.72)
    /// The least the fit stop asks for: below this the system shrinks the sheet further (Docs/DESIGN.md 4.1), and the floating
    /// capsule with it. The room left over is empty glass-free space above the controls.
    private let leastFit: CGFloat = 100
    /// The fit stop holds its content plus the padding `scrolling` puts around it, or the last of the content is cut off by the
    /// sheet's edge. Never so tall that the map disappears; past that it scrolls.
    private var fitHeight: CGFloat {
        let content = screen == .preview ? previewBlock + previewPinned : fitContent
        // The system adds the bottom safe area to a height detent, and the panel lays out over it (`portraitSheet`).
        return min(max(content + Layout.sheetTop + Layout.sheetBottom - safeBottom, leastFit), screenHeight * 0.7)
    }
    private func detent(_ stop: Stop) -> PresentationDetent {
        switch stop {
        case .fit: .height(fitHeight)
        case .medium: .medium
        case .raised: raisedDetent
        case .large: .large
        }
    }
    private var detents: Set<PresentationDetent> {
        switch screen {
        case .home, .search: [.medium, .large]
        case .place: [detent(.fit), .medium, .large]
        case .preview, .navigating: [detent(.fit), raisedDetent, .large]
        }
    }
    private var stopBinding: Binding<PresentationDetent> {
        // Home's fit stop is the floating controls, with no sheet, so there the sheet is only ever on its way out.
        Binding(get: { screen == .home && stop == .fit ? .medium : detent(stop) }, set: { new in
            stop = new == .large ? .large : new == .medium ? .medium : new == raisedDetent ? .raised : .fit
        })
    }
    /// Home at rest has no sheet: the system's partial-height sheet always draws a panel, and at rest the controls float on their own glass.
    private var sheetUp: Binding<Bool> {
        Binding(get: { !landscape && screen != .navigating && !floatingHome }, set: { up in
            if !up, screen == .home { stop = .fit; homeStop = .fit }
        })
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                SeattleMap(comparison: screen == .preview ? session.comparison : nil, selectedCalmer: selectedCalmer, recenter: recenter, locate: locateCount, selected: mapSelection,
                           user: userInCoverage, compass: compass, showsHeading: wantsCompass, coverage: coverage, onLongPress: dropPin, guidance: guidance,
                           onCameraGesture: { if guiding { camera.pan() } else if centred { centred = false } }, padding: mapPadding(geo),
                           markerFeed: markerFeed, showsPlaces: showsPlaces, onPlaceTap: openMarker, reportsPlaces: reportsPlaces, onVisiblePlaces: { visiblePlaces = $0 })
                    .ignoresSafeArea()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(screen == .preview ? "\(RegionSelection.areaName) offline map. Routes are also described in the panel." : "\(RegionSelection.areaName) offline map")
                if reportsPlaces && showsPlaces { placeElements }
                if screen == .navigating {
                    GuidanceOverlay(navigator: navigator, landscape: landscape, cardWidth: cardWidth, attribution: AnyView(attribution), camera: $camera, muted: $voiceMuted,
                                    onInsets: { guidanceInset = $0 }, onEnd: endNavigation, onDone: finishNavigation)
                        .transition(.opacity)
                } else if landscape { landscapeLayout(geo).transition(.opacity) } else { portraitChrome(geo).transition(.opacity) }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") { NavigationDebugProbe(navigator: navigator) }
                #endif
                if let startedAt = recorder.startedAt { recordingPill(startedAt, geo) }
            }
            .animation(Motion.panel(reduceMotion), value: screen)
            .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: { screenHeight = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { safeBottom = $0 }
        }
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: sheetUp) { portraitSheet }
        .task(id: previewRequest) {
            if let previewRequest {
                selectedCalmer = true
                // The place card already ran this compare for its estimate.
                if let estimate, estimate.request == previewRequest, let seed = estimate.comparison { session.start(previewRequest, seed: seed) } else { session.start(previewRequest) }
            } else { session.cancel() }
        }
        .task { DriveLogger.resetForUITests(); recorder.closeLeftOpen() }
        .onChange(of: detailedLogOn) { if !detailedLogOn { recorder.stop(reason: "log_off") } }
        .task { await locate(prompting: true) }
        .task { if !Self.markersOff { markerFeed = await PlaceMarkerFeed.load(search) } }
        .onDisappear { session.cancel(); navigator.stop() }
        .onChange(of: voiceMuted) { navigator.setMuted(voiceMuted) }
        .driveLogUse(driveLogSnapshot)
        .reportContext(screen: String(String(describing: screen).prefix { $0 != "(" }), mode: mode, extraMinutes: budget, comparison: session.comparison, navigator: navigator, dataVersion: search.dataVersion)
        .onChange(of: userLocation) { followUser() }
        .onChange(of: runsCompass, initial: true) { updateCompass() }
        .onChange(of: guiding) { updateCompass() }
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
                    AboutView(graph: graph, canSwitchNow: screen != .preview && screen != .navigating)
                case .favourites:
                    FavouritesEditor(saved: saved)
                case .preferences:
                    RoutePreferencesView(store: preferences, mode: mode)
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

    /// The map buttons, attribution and home's floating controls over the map; the sheet itself is a system sheet above them. The buttons
    /// and credit give way once the sheet is large: only the status bar is left above it, so the credit moves into the sheet (`portraitSheet`).
    private func portraitChrome(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            HStack { Spacer(); mapButtons }.padding(.horizontal, 16).padding(.top, 8)
            Spacer(minLength: 0)
            if stop != .large {
                HStack { attribution; Spacer() }.padding(.horizontal, 12)
                    .padding(.bottom, floatingHome ? 8 : max(sheetCover - geo.safeAreaInsets.bottom, 0) + 8)
            }
            if floatingHome { presenting(homeControls).padding(.horizontal, 14) }
        }
        .opacity(stop == .large ? 0 : 1)
        .allowsHitTesting(stop != .large)
        .accessibilityHidden(stop == .large)
        .animation(Motion.content(reduceMotion), value: stop)
    }

    private var portraitSheet: some View {
        presenting(panel)
            .background { SheetGlass(detents: detents, screen: "\(screen)") }
            .presentationBackground { sheetBackdrop }
            .presentationCornerRadius(Layout.sheetRadius)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if stop == .large {
                    attributionLinks.frame(maxWidth: .infinity).padding(.vertical, 6).transition(.opacity)
                }
            }
            // At the partial stops the system floats the sheet clear of the home indicator, so its safe area would only be a gap.
            .ignoresSafeArea(.container, edges: stop == .large ? [] : .bottom)
            .animation(Motion.content(reduceMotion), value: stop == .large)
            .presentationDetents(detents, selection: stopBinding)
            .presentationBackgroundInteraction(.enabled(upThrough: screen == .preview ? raisedDetent : .medium))
            .presentationDragIndicator(floatingHome ? .hidden : .visible)
            // Home's raised sheet pulls down to the floating controls; every other screen stays until it's closed.
            .interactiveDismissDisabled(screen != .home)
            // At its lower stops the system shrinks the sheet and floats it above the screen's edge, so its own height says nothing
            // about where its top is. The global frame includes that.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                let height = screenHeight - top
                sheetCover = height
                if stop != .large, screen != .search { mapCover = height }
            }
            #if DEBUG
            .onGeometryChange(for: String.self) { "\(Int($0.frame(in: .global).minY)) \(Int($0.frame(in: .global).maxY)) \(Int($0.safeAreaInsets.bottom))" } action: { MapDebug.shared.sheet = $0 }
            #endif
    }

    /// What the sheet shows over its glass (`SheetGlass`): the tint that keeps text legible, or a solid panel when raised to read or when asked for.
    @ViewBuilder private var sheetBackdrop: some View {
        if reduceTransparency || GlassFlags.reduceTransparency || stop == .large { Color.panel }
        else if contrast == .increased { Color(uiColor: .glassVeilDense) }
        else { Color(uiColor: .glassSheetVeil) }
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
                .floatingSurface(in: RoundedRectangle(cornerRadius: Layout.groupRadius + Layout.cardInset), veil: .light)
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
        .environment(\.onGlassPanel, true).environment(\.solidSurface, stop == .large && !landscape)
        .animation(Motion.content(reduceMotion), value: screen.panelID)
    }

    /// Scrolls whenever the content is taller than the room it has. In landscape the card also sizes itself to the content.
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, inset).padding(.top, landscape ? Layout.cardInset : Layout.sheetTop).padding(.bottom, Layout.sheetBottom)
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
                .accessibilityLabel(screen == .preview && request != nil ? "Fit routes on map" : selectedPlace != nil ? "Centre on this place" : "Fit map to \(RegionSelection.areaName)")
                .accessibilityIdentifier("recenter")
            if detailedLogOn && !recorder.isRecording {
                Divider().frame(width: 44)
                Button(action: startRecording) { Image(systemName: "record.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("Start recording")
                    .accessibilityHint("Records your location in the detailed log until you stop it")
                    .accessibilityIdentifier("record-start")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 19)).foregroundStyle(.primary)
        .floatingSurface(in: Capsule(), interactive: true)
    }

    private func startRecording() {
        Task { if !(await recorder.start()), detailedLogOn, permission.access != .granted { notice = .record } }
    }

    /// Over every screen but the map's own controls: top leading in portrait (under the guidance banner while guiding), and left of
    /// the map buttons in landscape.
    private func recordingPill(_ startedAt: Date, _ geo: GeometryProxy) -> some View {
        let guidingPortrait = screen == .navigating && !landscape
        return RecordingPill(startedAt: startedAt) { recorder.stop() }
            .padding(.top, 8 + (guidingPortrait ? guidanceInset.top : 0))
            .padding(landscape ? .trailing : .leading, landscape ? 16 + 44 + 8 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: landscape ? .topTrailing : .topLeading)
            .transition(.opacity)
    }

    private var attribution: some View {
        attributionLinks.padding(.horizontal, 8).padding(.vertical, 3).floatingSurface(in: Capsule(), veil: .light)
    }

    private var attributionLinks: some View {
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

    // MARK: Home

    /// Home at rest: no panel, only the controls, each on its own glass over the map. Raised, they sit on the panel's glass instead.
    private var floatingHome: Bool { screen == .home && stop == .fit && !landscape }

    /// What home's panel and floating controls share: favourites, or the first-launch hint, over the search capsule.
    private var homeControls: some View {
        // One container for the whole cluster, so the chips, hint and search capsule sample and blend together.
        GlassEffectContainer(spacing: 2) {
            VStack(alignment: .leading, spacing: 8) {
                if !saved.favourites.isEmpty {
                    FavouritesRow(favourites: saved.favourites, floating: floatingHome, onOpen: open,
                                  onRemove: { place in withAnimation(Motion.panel(reduceMotion)) { saved.removeFavourite(place) } },
                                  onAdd: { addingFavourite = true; show(.search) })
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                }
                if saved.favourites.isEmpty && saved.recents.isEmpty {
                    Text("Search a place or address, or long-press the map").font(.footnote).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 6)
                        .chip(floating: floatingHome, in: Capsule())
                        .accessibilityIdentifier("home-hint")
                }
                HStack(spacing: 8) {
                    searchCapsule
                    if floatingHome { moreButton.transition(.opacity) }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fitContent = $0 }
        }
    }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            homeControls
            if !saved.recents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recents").font(.footnote.weight(.semibold)).foregroundStyle(GuidanceOverlay.onGlass).padding(.leading, 4)
                        .accessibilityAddTraits(.isHeader)
                    PlaceList(places: Array(saved.recents.prefix(landscape ? 3 : 5)), minHeight: landscape ? 46 : 52, identifier: { "home-recent-\($0.id)" }, action: open)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if !saved.favourites.isEmpty {
                    homeRow("Edit favourites", symbol: "star", id: "edit-favourites") { sheet = .favourites }
                    Hairline().padding(.leading, 4)
                }
                homeRow("About PeopleMaps", symbol: "info.circle", id: "about") { sheet = .about }
            }
        }
    }

    /// The way to search: its own glass over the map, a plain well on a panel.
    private var searchCapsule: some View {
        Button { show(.search) } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").fontWeight(.medium)
                Text("Where to?").fontWeight(.medium)
                Spacer(minLength: 0)
            }
            .font(.body).foregroundStyle(.primary).padding(.horizontal, 18).frame(minHeight: floatingHome ? 56 : 44)
            .contentShape(Capsule())
            .chip(floating: floatingHome, in: Capsule())
        }
        // Dragging it up raises the sheet, as dragging a sheet's handle would.
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { if floatingHome, $0.translation.height < -30 { raiseHome() } })
        .buttonStyle(.plain).accessibilityLabel("Where to?").accessibilityHint("Search places and addresses").accessibilityIdentifier("search-field")
    }

    /// Raises the sheet to what doesn't float: Recents and the rest.
    private var moreButton: some View {
        Button(action: raiseHome) {
            Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 56, height: 56).contentShape(Circle())
                .chip(floating: true, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel("More").accessibilityHint("Shows recents and About").accessibilityIdentifier("home-more")
    }

    private func raiseHome() { stop = .medium; homeStop = .medium }

    private func homeRow(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(GuidanceOverlay.onGlass)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.leading, 4).accessibilityIdentifier(id)
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
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(GuidanceOverlay.onGlass).padding(.leading, 4).accessibilityAddTraits(.isHeader)
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
            if graph.coverage.contains(place.coordinate) {
                directionsButton(place).dynamicTypeSize(...DynamicTypeSize.accessibility1)
                estimateNotes(place)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Outside the area we cover yet").font(.headline)
                    Text(RegionSelection.usesCounty ? RegionSelection.coverageSentence : "PeopleMaps can route only inside its offline Seattle area for now.").font(.footnote).foregroundStyle(GuidanceOverlay.onGlass)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
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
        guard graph.coverage.contains(place.coordinate), let from = start(for: place), graph.coverage.contains(from.coordinate) else { return nil }
        return .init(origin: from, destination: place, mode: mode, extraMinutes: budget, preferences: preferences[mode])
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
            .foregroundStyle(.primaryActionText)
            .frame(maxWidth: .infinity, minHeight: 32).padding(.vertical, 2)
        }
        .primaryAction(shape: typeSize.isAccessibilitySize ? .roundedRectangle(radius: Layout.groupRadius) : .capsule)
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
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30).background(.glassWell, in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(on ? "Remove from Favourites" : "Add to Favourites")
            .accessibilityIdentifier("favourite")
    }

    private func closeButton(label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.primary)
                .frame(width: 30, height: 30).background(.glassWell, in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    // MARK: Route preview

    /// Scrolls at any text size, with Why this route, the modes and Start pinned under it, so none is ever clipped. All of it sits straight
    /// on the panel's glass, separated by hairlines.
    private var previewPanel: some View {
        VStack(spacing: 0) {
            scrolling { previewContent }
            previewActions
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewPinned = $0 }
        }
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                previewHeader
                ZStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        if request == nil { needsPlace } else { stateContent }
                    }.id(request == nil ? "needs-place" : stateID).transition(.opacity)
                }
                .animation(Motion.content(reduceMotion), value: request == nil ? "needs-place" : stateID)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewBlock = $0 }
            if landscape || stop == .raised || stop == .large || typeSize.isAccessibilitySize {
                Hairline()
                swapRow
                Hairline()
                extraTime.sensoryFeedback(.selection, trigger: budget)
            }
        }
    }

    /// Where to, how far, and from where; the two places open their pickers. Times stay estimates, so that's said here too.
    private var previewHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                let line = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                line {
                    placeButton(place: destination, target: .destination)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    if let chosenRoute { Text(chosenRoute.distance).font(.subheadline.weight(.medium)).monospacedDigit().accessibilityIdentifier("preview-distance") }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        placeButton(place: origin, target: .origin).fixedSize()
                        Spacer(minLength: 0)
                        estimateCaveat.lineLimit(1).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        placeButton(place: origin, target: .origin).fixedSize(horizontal: false, vertical: true)
                        estimateCaveat.fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            closeButton(label: "Close routes", id: "close-preview") { show(.home) }
                .padding(.top, -7).padding(.trailing, -7)
        }
    }

    private var estimateCaveat: some View {
        Text("Estimate, no live traffic").font(.footnote).foregroundStyle(GuidanceOverlay.onGlass)
    }

    private var chosenRoute: Route? {
        guard request != nil, let comparison = session.comparison else { return nil }
        return selectedCalmer ? comparison.calmer ?? comparison.fastest : comparison.fastest
    }

    private func placeButton(place: Place?, target: Sheet) -> some View {
        let origin = target == .origin
        let empty = origin ? "Choose start" : "Choose destination"
        let shown = place.map { origin ? "From \($0.shortName)" : $0.shortName } ?? empty
        return Button { sheet = target } label: {
            Text(shown)
                .font(origin && place != nil ? .footnote : .subheadline.weight(place == nil ? .semibold : .medium))
                .foregroundStyle(origin && place != nil ? GuidanceOverlay.onGlass : .primary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .contentShape(Rectangle().inset(by: -6))
        }.buttonStyle(.plain)
            .accessibilityLabel(place.map { "\(origin ? "Starting from" : "Going to"), \($0.shortName)" } ?? empty)
            .accessibilityAddTraits(origin ? [] : .isHeader)
            .accessibilityIdentifier("choose-\(target.rawValue)")
    }

    private var swapRow: some View {
        Button {
            withAnimation(Motion.content(reduceMotion)) { let previous = origin; origin = destination; destination = previous }
        } label: {
            Label("Swap start and destination", systemImage: "arrow.up.arrow.down").font(.subheadline).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("swap")
    }

    private func extraLabel(_ minutes: Int) -> String { minutes == 0 ? "None" : "\(minutes) min" }

    private var extraTime: some View {
        let title = "Most extra time for a calmer route"
        return Menu {
            Picker("Extra time", selection: $budget) {
                ForEach([10, 5, 2, 0], id: \.self) { Text(extraLabel($0)).tag($0) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(title).foregroundStyle(.primary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(extraLabel(budget)).foregroundStyle(GuidanceOverlay.onGlass).monospacedDigit()
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(GuidanceOverlay.onGlass)
            }
            .font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(title).accessibilityValue(extraLabel(budget)).accessibilityIdentifier("extra-time-menu")
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

    /// Every state of the preview takes about the same room, so the panel doesn't jump when routes arrive.
    private var stateHeight: CGFloat { landscape ? 90 : 150 }

    /// No start (location off or unavailable), a start outside the area we cover, or no destination yet: say what to do, and show no route.
    private var needsPlace: some View {
        let outside = origin.map { !graph.coverage.contains($0.coordinate) } ?? false
        return VStack(alignment: .leading, spacing: 6) {
            Text(outside ? "Your start is outside the area we cover" : origin == nil ? "Choose a start to compare routes." : "Choose a destination to compare routes.")
                .font(outside ? .headline : .subheadline).foregroundStyle(outside ? .primary : GuidanceOverlay.onGlass).fixedSize(horizontal: false, vertical: true)
            if outside {
                Text(RegionSelection.usesCounty ? "\(RegionSelection.coverageSentence) Choose a start inside it." : "PeopleMaps can route only inside its offline Seattle area for now. Choose a start inside it.")
                    .font(.footnote).foregroundStyle(GuidanceOverlay.onGlass).fixedSize(horizontal: false, vertical: true)
                Button("Choose start") { sheet = .origin }.font(.subheadline.weight(.semibold)).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: stateHeight, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(outside ? "start-outside-coverage" : "needs-place")
    }

    @ViewBuilder private var stateContent: some View {
        switch session.state {
        case .idle, .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("Comparing \(RegionSelection.areaName) streets…").font(.subheadline).foregroundStyle(GuidanceOverlay.onGlass).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { session.cancel() }.font(.subheadline.weight(.semibold)).accessibilityIdentifier("cancel-route")
            }.frame(minHeight: stateHeight, alignment: .top)
        case .cancelled:
            status(title: "Comparison paused", message: "Your places are still here.", button: "Compare routes")
        case let .failed(message):
            status(title: "Try another route", message: message, button: "Try again")
        case let .ready(comparison):
            if let calmer = comparison.calmer, let score = comparison.calmerCalm {
                routeButton(calmer, title: "Calmer", score: score, spoken: "\(comparison.extraTimeLabel), \(comparison.spokenCalmSummary)", selected: selectedCalmer, calmer: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        rating(score, route: calmer)
                        Text(comparison.reasonLine).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Hairline()
                routeButton(comparison.fastest, title: "Fastest", score: comparison.fastestCalm, spoken: "Estimate, no live traffic", selected: !selectedCalmer, calmer: false) {
                    fastestRow(comparison, selected: !selectedCalmer)
                }
            } else {
                routeButton(comparison.fastest, title: "Fastest", score: comparison.fastestCalm, spoken: "Estimate, no live traffic", selected: true, calmer: false) {
                    rating(comparison.fastestCalm, route: comparison.fastest)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(comparison.noCalmer.title).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Text(comparison.noCalmer.detail).font(.footnote).foregroundStyle(GuidanceOverlay.onGlass).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("no-alternative")
            }
            if let note = comparison.tollNote(calmer: selectedCalmer && comparison.calmer != nil) {
                // The route Start takes, said before Start: the details sheet is a tap away.
                Text(note).font(.footnote).foregroundStyle(GuidanceOverlay.onGlass).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("toll-note")
            }
        }
    }

    /// The big word and time over the rating bar.
    private func rating(_ score: CalmScore, route: Route) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let line = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            line {
                Text(score.level.title).font(.largeTitle.weight(.semibold)).tracking(-0.5).foregroundStyle(Color.calmWord(score.level))
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text(route.timeRange).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
            }
            CalmMeter(score: score)
        }
    }

    /// The fastest route under the calmer one, smaller, with its own bar.
    private func fastestRow(_ comparison: RouteComparison, selected: Bool) -> some View {
        let score = comparison.fastestCalm
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Fastest: \(Text(score.level.title).fontWeight(.semibold).foregroundStyle(Color.calmWord(score.level)))")
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").fontWeight(.semibold).transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                Text(comparison.fastest.timeRange).monospacedDigit()
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            CalmMeter(score: score, height: 6)
        }
    }

    /// Picks which route the map shows and Start takes. VoiceOver hears the route, its time and distance, then the rating in words and score.
    private func routeButton<Label: View>(_ route: Route, title: String, score: CalmScore, spoken: String, selected: Bool, calmer: Bool, @ViewBuilder label: () -> Label) -> some View {
        Button { withAnimation(Motion.content(reduceMotion)) { selectedCalmer = calmer } } label: {
            label().contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(title) route, \(route.spokenTimeRange), \(DistanceFormat.distance(route.metrics.meters, spoken: true)). \(spoken)")
            .accessibilityValue(score.spoken)
            .accessibilityIdentifier(calmer ? "route-calmer" : "route-fastest")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func status(title: String, message: String, button: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(message).font(.footnote).foregroundStyle(GuidanceOverlay.onGlass).fixedSize(horizontal: false, vertical: true)
            Button(button) { if let request { session.start(request) } }.font(.subheadline.weight(.semibold)).padding(.top, 2)
                .accessibilityIdentifier("retry-route")
        }.frame(maxWidth: .infinity, minHeight: stateHeight, alignment: .topLeading)
    }

    // MARK: Pinned under the preview

    /// Why this route and Calmer means, then the modes beside Start.
    private var previewActions: some View {
        let comparison = request != nil ? session.comparison : nil
        // The landscape card has no height to spare, so the modes and Start stay side by side at a capped size.
        let stacked = typeSize.isAccessibilitySize && !landscape
        let line = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return VStack(spacing: 6) {
            Hairline()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    whyButton(comparison)
                    Spacer(minLength: 8)
                    RoutePreferencesRow(isCustom: !preferences[mode].isDefault(in: mode)) { sheet = .preferences }
                }
                VStack(alignment: .leading, spacing: 0) {
                    whyButton(comparison)
                    RoutePreferencesRow(isCustom: !preferences[mode].isDefault(in: mode)) { sheet = .preferences }
                }
            }
            line {
                modePicker(fullWidth: stacked)
                if let comparison {
                    Button { startNavigation(comparison) } label: {
                        Text(selectedCalmer || comparison.calmer == nil ? "Start" : "Start fastest").font(.body.weight(.semibold)).foregroundStyle(.primaryActionText)
                            .frame(maxWidth: .infinity, minHeight: landscape ? 28 : 34)
                    }
                    .primaryAction()
                    .accessibilityIdentifier("start-navigation")
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .dynamicTypeSize(...(landscape ? DynamicTypeSize.xxLarge : .accessibility2))
        .padding(.horizontal, inset).padding(.bottom, landscape ? Layout.cardInset : 8)
    }

    @ViewBuilder private func whyButton(_ comparison: RouteComparison?) -> some View {
        if let comparison {
            Button { sheet = .details } label: {
                Text("Why this route").font(.subheadline.weight(.semibold)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(comparison.spokenCalmSummary)
            .accessibilityIdentifier("route-details")
        }
    }

    /// Icon-only: each says its name to VoiceOver, and in the large content viewer at the largest text sizes.
    private func modePicker(fullWidth: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(TravelMode.displayOrder) { choice in
                Button { mode = choice } label: {
                    Image(systemName: choice.symbol).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        .frame(maxWidth: fullWidth ? .infinity : nil).frame(width: fullWidth ? nil : 46, height: landscape ? 38 : 46)
                        .background { if mode == choice { Capsule().fill(.glassChosen) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityShowsLargeContentViewer { Label(choice.title, systemImage: choice.symbol) }
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(mode == choice ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.glassWell, in: Capsule())
        .sensoryFeedback(.selection, trigger: mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Travel mode")
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
