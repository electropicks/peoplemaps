import SwiftUI
import UIKit
import PeoplemapsCore

extension TravelMode {
    /// Left to right in every mode picker, as in Apple Maps; the enum's own order stays as it is.
    static let displayOrder: [TravelMode] = [.drive, .bike, .walk]
    /// "18 min drive", "18 min cycle", "18 min walk".
    var trip: String { switch self { case .walk: "walk"; case .bike: "cycle"; case .drive: "drive" } }
    var symbol: String { switch self { case .walk: "figure.walk"; case .bike: "bicycle"; case .drive: "car.fill" } }
}

/// The map with its controls, and over it the screen the person is on (`ExploreModel`): the portrait sheet's home, search, place
/// card and preview (`HomeSheet`, `SearchSheet`, `PlaceCard`, `RoutePreview`), the landscape card, or guidance.
struct ExploreView: View {
    let graph: StreetGraph
    let search: SearchIndex
    @State private var model: ExploreModel
    @State private var navigator: NavigationController
    /// Compass heading, only while the map shows the user outside guidance; nil draws a plain dot.
    @State private var compass = CompassHeading()
    @State private var recenter = 0
    @State private var locateCount = 0
    @State private var screenHeight: CGFloat = 852
    @State private var safeBottom: CGFloat = 0
    /// Height the sheet covers now, and at its last rest short of large, which is what the map keeps clear of. Read only by the
    /// attribution row and the map's padding (`CoverReader`), so a drag redraws those and not the screen.
    @State private var cover = SheetCover()
    /// Home's raised content, as last measured; read only by the sheet (`PortraitSheet`).
    @State private var homeHeight = HomeHeight()
    @State private var camera = GuidanceCamera()
    @State private var guidanceInset = UIEdgeInsets.zero
    @State private var permission = LocationPermission()
    @State private var recorder = ManualRecorder.shared
    @AppStorage(DriveLogger.enabledKey, store: ExploreView.voiceStore) private var detailedLogOn = false
    @State private var asking = false
    /// The map's place markers, ready shortly after launch; home never waits for them.
    @State private var markerFeed: PlaceMarkerFeed?
    /// What the map last drew, for VoiceOver.
    @State private var visiblePlaces: [VisiblePlace] = []
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
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
        _model = State(initialValue: ExploreModel(graph: graph, search: search, router: computing))
        _navigator = State(initialValue: NavigationController(router: router))
    }

    private var screen: Screen { model.screen }
    /// The map's own arrow: the user is on it and not guiding (guidance draws its marker from the navigator).
    private var wantsCompass: Bool { model.userInCoverage != nil && !guiding && scenePhase == .active }
    /// Core Location's heading is wanted outside guidance for that arrow, and while guiding for the marker and camera at a stop.
    private var runsCompass: Bool { (model.userInCoverage != nil || guiding) && scenePhase == .active }
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
        guard permission.access == .granted else { model.userLocation = nil; return }
        if let c = await permission.currentCoordinate() { model.userLocation = Coordinate(lat: c.latitude, lon: c.longitude) }
    }

    /// Locate is always there: it centres on the user when it can, asks if nobody has answered yet, and otherwise says why not.
    private func locateTapped() {
        guard !asking else { return }
        switch permission.access {
        case .denied: model.notice = .locate
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
        if model.userLocation == nil { await locate(prompting: false) }
        guard let userLocation = model.userLocation else { model.notice = .noFix; return }
        guard graph.coverage.contains(userLocation) else { model.notice = .outside; return }
        locateCount += 1; model.centred = true
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
        case .denied: model.notice = .startGuidance
        case .undecided:
            asking = true
            Task {
                let answer = await permission.request()
                asking = false
                if answer == .granted { beginNavigation(comparison) } else { model.notice = .startGuidance }
            }
        }
    }

    private func beginNavigation(_ comparison: RouteComparison) {
        camera = GuidanceCamera(); guidanceInset = .zero
        navigator.start(comparison: comparison, useCalmer: model.selectedCalmer && comparison.calmer != nil, muted: voiceMuted)
        if navigator.isActive { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); model.show(.navigating) }
    }
    private func endNavigation() { navigator.stop(); model.show(.preview) }
    private func finishNavigation() { navigator.stop(); model.show(.home) }

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
        guard model.showsPlaces, let place = search.place(id: id) else { return }
        model.open(place)
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

    /// What the detailed log's app-use file watches (`App/Reports/DriveLogHooks.swift`).
    private var driveLogSnapshot: DriveLogSnapshot {
        DriveLogSnapshot(screen: screen.name, place: model.selectedPlace, query: model.query, mode: model.mode, budget: model.budget,
                         sheet: model.sheet?.rawValue, calmer: model.selectedCalmer,
                         request: model.previewRequest.map { "\($0.destination.id) \($0.mode) \($0.extraMinutes)" }, destination: model.previewRequest?.destination,
                         routeReady: model.session.comparison != nil)
    }

    /// Long-press drops a pin while browsing, never over a route or guidance.
    private func dropPin(_ c: Coordinate) {
        guard screen == .home || model.selectedPlace != nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        model.open(search.droppedPin(at: c))
    }

    /// Landscape on a phone: the panel becomes a floating card at the leading edge.
    private var landscape: Bool { verticalSizeClass == .compact }
    private var coverage: [Coordinate] { [Coordinate(lat: graph.bounds[0], lon: graph.bounds[1]), Coordinate(lat: graph.bounds[2], lon: graph.bounds[3])] }
    private let cardWidth: CGFloat = 330

    /// The sheet is up on every portrait screen but guidance. It is never dismissed, only moved between its stops: home is one
    /// sheet that is always there, with the one search field in it, as in Apple's Maps (owner, 10 November 2026).
    private var sheetUp: Binding<Bool> {
        Binding(get: { !landscape && screen != .navigating }, set: { _ in })
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CoverReader(cover) { cover in
                    SeattleMap(comparison: screen == .preview ? model.session.comparison : nil, selectedCalmer: model.selectedCalmer, recenter: recenter, locate: locateCount, selected: model.mapSelection,
                               user: model.userInCoverage, compass: compass, showsHeading: wantsCompass, coverage: coverage, onLongPress: dropPin, guidance: guidance,
                               onCameraGesture: { if guiding { camera.pan() } else if model.centred { model.centred = false } }, padding: mapPadding(geo, cover.map),
                               markerFeed: markerFeed, showsPlaces: model.showsPlaces, onPlaceTap: openMarker, reportsPlaces: reportsPlaces, onVisiblePlaces: { visiblePlaces = $0 })
                }
                    .ignoresSafeArea()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(screen == .preview ? "\(RegionSelection.areaName) offline map. Routes are also described in the panel." : "\(RegionSelection.areaName) offline map")
                if reportsPlaces && model.showsPlaces { placeElements }
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
        }
        .ignoresSafeArea(.keyboard)
        // On the GeometryReader, which takes what it is offered, and not on the ZStack in it: the chrome's bottom padding follows the
        // sheet, and once that outgrew the screen the ZStack grew, which raised `screenHeight`, which raised the padding.
        .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: { screenHeight = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { safeBottom = $0 }
        .sheet(isPresented: sheetUp) {
            PortraitSheet(model: model, homeHeight: homeHeight, cover: cover, screenHeight: screenHeight, safeBottom: safeBottom) {
                presenting(panel)
            }
        }
        .task(id: model.previewRequest) { model.compareForPreview() }
        .task { DriveLogger.resetForUITests(); recorder.closeLeftOpen() }
        .onChange(of: detailedLogOn) { if !detailedLogOn { recorder.stop(reason: "log_off") } }
        .task { await locate(prompting: true) }
        .task { if !Self.markersOff { markerFeed = await PlaceMarkerFeed.load(search) } }
        .onDisappear { model.session.cancel(); navigator.stop() }
        .onChange(of: voiceMuted) { navigator.setMuted(voiceMuted) }
        .onChange(of: typeSize, initial: true) { model.accessibilitySize = typeSize.isAccessibilitySize }
        .driveLogUse(driveLogSnapshot)
        .reportContext(screen: screen.name, mode: model.mode, extraMinutes: model.budget, comparison: model.session.comparison, navigator: navigator, dataVersion: search.dataVersion)
        .onChange(of: model.userLocation) { model.followUser() }
        .onChange(of: runsCompass, initial: true) { updateCompass() }
        .onChange(of: guiding) { updateCompass() }
        .onChange(of: model.stop) { if screen == .search, model.stop != .large { model.searchLowered() } }
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
            .alert(model.notice?.title ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }), presenting: model.notice) { notice in
                if notice.offersSettings {
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    Button("Not Now", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { Text($0.message) }
            .sheet(item: $model.sheet) { item in
                switch item {
                case .origin:
                    PlacePicker(title: "Starting from", search: search, selected: model.origin, saved: model.saved, location: permission) { place in
                        model.origin = place; model.lastOrigin = place
                        if place.isCurrentLocation { model.userLocation = place.coordinate }
                    }
                case .destination:
                    PlacePicker(title: "Going to", search: search, selected: model.destination, saved: model.saved) { model.destination = $0; model.saved.addRecent($0) }
                case .details:
                    if let comparison = model.session.comparison { RouteDetails(comparison: comparison) }
                case .settings:
                    SettingsView(graph: graph, dataVersion: search.dataVersion, canSwitchNow: screen != .preview && screen != .navigating)
                case .favourites:
                    FavouritesEditor(saved: model.saved)
                case .preferences:
                    RoutePreferencesView(store: model.preferences, mode: model.mode)
                }
            }
    }

    /// Keeps fitted routes clear of the panel, the map buttons and the attribution. Home keeps clear of the fit stop only,
    /// so pulling the sheet up never moves a map the user has panned.
    private func mapPadding(_ geo: GeometryProxy, _ mapCover: CGFloat) -> UIEdgeInsets {
        let safe = geo.safeAreaInsets
        if screen == .home {
            // Home frames the user's neighbourhood or the area we cover: clear of the map buttons, 48 pt elsewhere, and of the bottom
            // half, so the location dot sits about 30% down at rest instead of where the raised sheet's edge lands. It never reads the
            // stop, so pulling the sheet up moves nothing.
            if landscape { return UIEdgeInsets(top: safe.top + 48, left: safe.leading + 12 + cardWidth + 24, bottom: safe.bottom + 48, right: safe.trailing + 16 + 44 + 24) }
            return UIEdgeInsets(top: safe.top + 48, left: 48, bottom: screenHeight * 0.5 + 24, right: 16 + 44 + 24)
        }
        if landscape {
            return UIEdgeInsets(top: safe.top + 24, left: safe.leading + 12 + cardWidth + 32, bottom: safe.bottom + 36, right: safe.trailing + 16 + 44 + 24)
        }
        return UIEdgeInsets(top: safe.top + 24, left: 32, bottom: max(mapCover, safe.bottom) + 40, right: 16 + 44 + 16)
    }

    /// The map buttons, attribution and home's floating controls over the map; the sheet itself is a system sheet above them. The buttons
    /// and credit give way once the sheet is large: only the status bar is left above it, so the credit moves into the sheet (`PortraitSheet`).
    private func portraitChrome(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            HStack { Spacer(); mapButtons }.padding(.horizontal, 16).padding(.top, 8)
            Spacer(minLength: 0)
            if model.stop != .large {
                CoverReader(cover) { cover in
                    HStack { attribution; Spacer() }.padding(.horizontal, 12)
                        .padding(.bottom, max(cover.sheet - geo.safeAreaInsets.bottom, 0) + 8)
                        // The sheet's measured top is not steady while the system moves it between stops: it reports the new stop for
                        // one frame, then the old one, then the new one again. Followed directly, the credit skipped up and back on a
                        // tap of More. A spring takes it to wherever the sheet settles and passes over a one-frame report.
                        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1), value: cover.sheet)
                }
            }
        }
        .opacity(model.stop == .large ? 0 : 1)
        .allowsHitTesting(model.stop != .large)
        .accessibilityHidden(model.stop == .large)
        .animation(Motion.content(reduceMotion), value: model.stop)
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
                case .home: HomeSheet(model: model, height: homeHeight)
                case .search: SearchSheet(model: model)
                case let .place(place): PlaceCard(model: model, place: place)
                case .preview: RoutePreview(model: model, onStart: startNavigation)
                case .navigating: EmptyView()
                }
            }.id(screen.panelID).transition(.opacity)
        }
        .environment(\.onGlassPanel, true)
        .environment(\.landscapeCard, landscape)
        .animation(Motion.content(reduceMotion), value: screen.panelID)
    }

    /// One glass capsule: Locate, always there, and Fit.
    private var mapButtons: some View {
        VStack(spacing: 0) {
            Button(action: locateTapped) {
                Image(systemName: model.centred ? "location.fill" : "location").frame(width: 44, height: 44)
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            }
            .accessibilityLabel("Show my location")
            .accessibilityValue(model.centred ? "Centred" : model.userInCoverage != nil ? "Found" : "")
            .accessibilityIdentifier("locate")
            Divider().frame(width: 44)
            Button { recenter += 1; model.centred = false } label: { Image(systemName: "viewfinder").frame(width: 44, height: 44) }
                .accessibilityLabel(screen == .preview && model.request != nil ? "Fit routes on map" : model.selectedPlace != nil ? "Centre on this place" : "Fit map to \(RegionSelection.areaName)")
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
        Task { if !(await recorder.start()), detailedLogOn, permission.access != .granted { model.notice = .record } }
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
        AttributionLinks().padding(.horizontal, 8).padding(.vertical, 3).floatingSurface(in: Capsule(), veil: .light)
    }
}

/// Where the sheet's top is, in whole points. A drag or a detent animation moves it every frame, so it lives outside `ExploreView`'s
/// state: only a `CoverReader` that reads it redraws.
@MainActor @Observable final class SheetCover {
    /// Height the sheet covers now.
    private(set) var sheet: CGFloat = 0
    /// Height it covered at its last rest short of large (not search, which the keyboard moves).
    private(set) var map: CGFloat = 0

    /// Assigns only what changed, since an `@Observable` property notifies on every set.
    func update(height: CGFloat, restsShortOfLarge: Bool) {
        let height = height.rounded()
        if sheet != height { sheet = height }
        if restsShortOfLarge, map != height { map = height }
    }
}

/// Reads `cover` in its own body, so a change redraws this view and not the one that made it.
struct CoverReader<Content: View>: View {
    let cover: SheetCover
    let content: (SheetCover) -> Content
    init(_ cover: SheetCover, @ViewBuilder content: @escaping (SheetCover) -> Content) { self.cover = cover; self.content = content }
    var body: some View { content(cover) }
}
