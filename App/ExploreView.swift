import SwiftUI
import UIKit
import PeoplemapsCore

private enum Sheet: String, Identifiable { case origin, destination, details, about; var id: String { rawValue } }

private enum Screen: Equatable { case home, search, place(Place), preview, navigating }

struct ExploreView: View {
    static let gasWorks = "relation/1047789", kerryPark = "node/693337509"
    /// Shown on Home and on the map, in this order.
    static let featuredIDs = [gasWorks, "way/37058377", "way/160545994", kerryPark]

    let graph: StreetGraph
    @State private var session: RouteSession
    @State private var navigator: NavigationController
    @State private var origin: Place
    @State private var destination: Place
    @State private var mode: TravelMode = .drive
    @State private var budget = 5
    @State private var selectedCalmer = true
    @State private var sheet: Sheet?
    @State private var screen = Screen.home
    @State private var query = ""
    /// The origin the user chose last; a later Directions reuses it unless it is the new destination.
    @State private var lastOrigin: Place?
    @FocusState private var searchFocused: Bool
    @State private var recenter = 0
    @State private var panelHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var overview = false
    @State private var guidanceInset = UIEdgeInsets.zero
    @State private var permission = LocationPermission()
    @State private var asking = false
    @State private var locationOff = false
    @AppStorage("voiceMuted", store: ExploreView.voiceStore) private var voiceMuted = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

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

    init(graph: StreetGraph, router: NativeRouter) {
        self.graph = graph
        #if DEBUG
        let computing: any RouteComputing = ProcessInfo.processInfo.arguments.contains("--ui-testing") ? SlowTestRouter(base: router) : router
        #else
        let computing: any RouteComputing = router
        #endif
        _session = State(initialValue: RouteSession(router: computing))
        _navigator = State(initialValue: NavigationController(router: router))
        _origin = State(initialValue: graph.places.first { $0.id == Self.kerryPark } ?? graph.places[0])
        _destination = State(initialValue: graph.places.first { $0.id == Self.gasWorks } ?? graph.places[1])
    }

    private var featured: [Place] { Self.featuredIDs.compactMap { id in graph.places.first { $0.id == id } } }
    private var selectedPlace: Place? { if case let .place(place) = screen { place } else { nil } }
    /// Stays set while guiding, so the comparison survives and End returns to the same routes.
    private var previewRequest: RouteRequest? { screen == .preview || screen == .navigating ? request : nil }
    private var guiding: Bool { screen == .navigating && navigator.isActive }
    private var guidance: Guidance? {
        guard guiding, !navigator.routeGeometry.isEmpty else { return nil }
        return Guidance(version: navigator.routeVersion, coordinates: navigator.routeGeometry, calmer: navigator.calmerRoute,
                        destination: navigator.routeGeometry.last!, user: navigator.coordinate, overview: overview, inset: guidanceInset)
    }

    /// Guidance needs location, so Start is where permission is asked (never while browsing or comparing).
    /// The simulated provider path needs none.
    private func startNavigation(_ comparison: RouteComparison) {
        guard !asking else { return }
        #if DEBUG
        if NavigationController.simulating { beginNavigation(comparison); return }
        #endif
        switch permission.access {
        case .granted: beginNavigation(comparison)
        case .denied: locationOff = true
        case .undecided:
            asking = true
            Task {
                let answer = await permission.request()
                asking = false
                if answer == .granted { beginNavigation(comparison) } else { locationOff = true }
            }
        }
    }

    private func beginNavigation(_ comparison: RouteComparison) {
        overview = false; guidanceInset = .zero
        navigator.start(comparison: comparison, useCalmer: selectedCalmer && comparison.calmer != nil, muted: voiceMuted)
        if navigator.isActive { screen = .navigating }
    }
    private func endNavigation() { navigator.stop(); screen = .preview }
    private func finishNavigation() { navigator.stop(); screen = .home }

    private func open(_ place: Place) { query = ""; screen = .place(place) }
    private func openPin(_ id: String) { if let place = graph.places.first(where: { $0.id == id }) { open(place) } }

    private func startDirections(to place: Place) {
        let fallbackID = place.id == Self.kerryPark ? Self.gasWorks : Self.kerryPark
        let from = lastOrigin.flatMap { $0.id == place.id ? nil : $0 } ?? graph.places.first { $0.id == fallbackID } ?? origin
        origin = from; lastOrigin = from; destination = place
        screen = .preview
    }

    private var request: RouteRequest { .init(origin: origin, destination: destination, mode: mode, extraMinutes: budget) }
    /// Landscape on a phone: the panel becomes a floating card at the leading edge.
    private var landscape: Bool { verticalSizeClass == .compact }
    private let cardWidth: CGFloat = 330

    var body: some View {
        GeometryReader { geo in
            ZStack {
                SeattleMap(comparison: screen == .preview ? session.comparison : nil, selectedCalmer: selectedCalmer, recenter: recenter, pins: screen == .preview ? [] : featured,
                           selected: selectedPlace, onPin: openPin, guidance: guidance, padding: mapPadding(geo))
                    .ignoresSafeArea()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(screen == .preview ? "Seattle offline map. Routes are also described in the panel." : "Seattle offline map")
                if screen == .navigating {
                    GuidanceOverlay(navigator: navigator, landscape: landscape, cardWidth: cardWidth, attribution: AnyView(attribution), overview: $overview, muted: $voiceMuted,
                                    onInsets: { guidanceInset = $0 }, onEnd: endNavigation, onDone: finishNavigation)
                } else if landscape { landscapeLayout(geo) } else { portraitLayout(geo) }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") { NavigationDebugProbe(navigator: navigator) }
                #endif
            }
        }
        .task(id: previewRequest) {
            if let previewRequest { selectedCalmer = true; session.start(previewRequest) } else { session.cancel() }
        }
        .onDisappear { session.cancel(); navigator.stop() }
        .onChange(of: voiceMuted) { navigator.setMuted(voiceMuted) }
        .onChange(of: scenePhase) {
            if scenePhase == .background { navigator.pause() } else if scenePhase == .active { navigator.resume() }
        }
        .alert("Location is off for PeopleMaps", isPresented: $locationOff) {
            Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Turn on location in Settings to start guidance. You can still compare routes without it.")
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .origin:
                PlacePicker(title: "Starting from", graph: graph, selected: origin) { origin = $0; lastOrigin = $0 }
            case .destination:
                PlacePicker(title: "Going to", graph: graph, selected: destination) { destination = $0 }
            case .details:
                if let comparison = session.comparison { RouteDetails(comparison: comparison) }
            case .about:
                AboutView(graph: graph)
            }
        }
    }

    /// Keeps fitted routes clear of the panel, the map buttons and the attribution.
    private func mapPadding(_ geo: GeometryProxy) -> UIEdgeInsets {
        let safe = geo.safeAreaInsets
        if screen == .home {
            // Home frames the featured places: clear of the panel and the map buttons, 48 pt elsewhere.
            if landscape { return UIEdgeInsets(top: safe.top + 48, left: safe.leading + 12 + cardWidth + 24, bottom: safe.bottom + 48, right: safe.trailing + 16 + 44 + 24) }
            return UIEdgeInsets(top: safe.top + 48, left: 48, bottom: safe.bottom + panelHeight + 24, right: 16 + 44 + 24)
        }
        if landscape {
            return UIEdgeInsets(top: safe.top + 24, left: safe.leading + 12 + cardWidth + 32, bottom: safe.bottom + 36, right: safe.trailing + 16 + 44 + 24)
        }
        return UIEdgeInsets(top: safe.top + 24, left: 32, bottom: safe.bottom + panelHeight + 40, right: 16 + 44 + 16)
    }

    private func portraitLayout(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            HStack { Spacer(); if screen != .search { mapButtons } }.padding(.horizontal, 16).padding(.top, 8)
            Spacer(minLength: 0)
            if screen != .search { HStack { attribution; Spacer() }.padding(.horizontal, 12).padding(.bottom, 8) }
            VStack(spacing: 0) {
                Capsule().fill(Color(uiColor: .systemGray3)).frame(width: 36, height: 5).padding(.top, 6).padding(.bottom, 8)
                    .accessibilityHidden(true)
                if screen == .search {
                    searchPanel.frame(height: geo.size.height * 0.9 - 19)
                } else {
                    scrollingContent(maxHeight: geo.size.height * 0.6)
                }
            }
            .background {
                UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14).fill(.panel)
                    .shadow(color: .black.opacity(0.08), radius: 12, y: -1).ignoresSafeArea(edges: .bottom)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if screen != .search { panelHeight = $0 } }
        }
    }

    private func landscapeLayout(_ geo: GeometryProxy) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // The card may run into the bottom safe area: the home indicator sits clear of it, at the screen's centre.
            Group {
                if screen == .search { searchPanel.frame(height: geo.size.height + geo.safeAreaInsets.bottom - 24) }
                else { scrollingContent(maxHeight: geo.size.height + geo.safeAreaInsets.bottom - 24) }
            }
                .background(.panel, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.14), radius: 16, y: 2)
                .frame(width: cardWidth)
                .padding(.vertical, 12).padding(.leading, 12)
            Spacer(minLength: 16)
            VStack(alignment: .trailing) {
                mapButtons
                Spacer()
                attribution
            }.padding(.vertical, 12).padding(.trailing, 16)
        }.ignoresSafeArea(.container, edges: .bottom)
    }

    /// Sizes itself to the content and scrolls only once the content is taller than `maxHeight`.
    private func scrollingContent(maxHeight: CGFloat) -> some View {
        ScrollView {
            panelContent
                .padding(.horizontal, landscape ? 12 : 16)
                .padding(.top, landscape ? 12 : 0).padding(.bottom, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, maxHeight))
    }

    private var mapButtons: some View {
        VStack(spacing: 0) {
            Button { sheet = .about } label: { Image(systemName: "info.circle").frame(width: 44, height: 44) }
                .accessibilityLabel("About Peoplemaps").accessibilityIdentifier("about")
            Divider().frame(width: 44)
            Button { recenter += 1 } label: { Image(systemName: "viewfinder").frame(width: 44, height: 44) }
                .accessibilityLabel(screen == .preview ? "Fit routes on map" : "Fit map to Seattle").accessibilityIdentifier("recenter")
        }
        .font(.system(size: 19)).foregroundStyle(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 1)
    }

    private var attribution: some View {
        Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("Map data © OpenStreetMap contributors")
    }

    @ViewBuilder private var panelContent: some View {
        switch screen {
        case .home: homeContent
        case .search: EmptyView()
        case let .place(place): placeContent(place)
        case .preview: previewContent
        case .navigating: EmptyView()
        }
    }

    // MARK: Home

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: landscape ? 10 : 14) {
            Button { screen = .search } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Search places")
                    Spacer(minLength: 0)
                }
                .font(.body).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 44)
                .background(.panelFill, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Search places").accessibilityIdentifier("search-field")
            VStack(alignment: .leading, spacing: 6) {
                Text("Featured places").font(.footnote).textCase(.uppercase).foregroundStyle(.secondary).padding(.leading, 16)
                PlaceList(places: featured, minHeight: landscape ? 46 : 52, identifier: { "featured-\($0.id)" }, action: open)
            }
        }
    }

    // MARK: Search

    private var results: [Place] { query.isEmpty ? featured : Array(graph.search(query).prefix(60)) }

    private var searchPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SearchField(text: $query, focused: $searchFocused)
                Button("Cancel") { query = ""; screen = .home }.font(.body).accessibilityIdentifier("cancel-search-home")
            }.padding(.horizontal, landscape ? 12 : 16).padding(.top, landscape ? 12 : 4).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if results.isEmpty {
                        EmptySearch(count: graph.places.count).padding(.top, 48)
                    } else {
                        resultGroup(query.isEmpty ? "Featured places" : "Top match", Array(results.prefix(query.isEmpty ? results.count : 1)))
                        if !query.isEmpty && results.count > 1 { resultGroup("Other matches", Array(results.dropFirst())) }
                    }
                }.padding(.horizontal, landscape ? 12 : 16).padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively).scrollBounceBehavior(.basedOnSize)
        }
        .task { searchFocused = true }
    }

    private func resultGroup(_ title: String, _ places: [Place]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).textCase(.uppercase).foregroundStyle(.secondary).padding(.leading, 16)
            PlaceList(places: places, query: query, identifier: { "result-\($0.id)" }, action: open)
        }
    }

    // MARK: Place card

    private func placeContent(_ place: Place) -> some View {
        VStack(alignment: .leading, spacing: landscape ? 10 : 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.shortName).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(place.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }.padding(.top, 4)
                Spacer(minLength: 0)
                closeButton(label: "Close", id: "close-place") { screen = .home }
            }
            Button { startDirections(to: place) } label: {
                Label("Directions", systemImage: "arrow.right").font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .foregroundStyle(.directionsText).background(.directionsFill, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("directions")
            Text("Compares the fastest route with a calmer one. Works offline.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private func closeButton(label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30).background(Color(uiColor: .tertiarySystemFill), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    // MARK: Route preview

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: landscape ? 8 : 14) {
            HStack { Spacer(); closeButton(label: "Close routes", id: "close-preview") { screen = .home } }.frame(height: 30)
            places
            Picker("Travel mode", selection: $mode) {
                ForEach(TravelMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: landscape ? 4 : 6) {
                Text("Extra time you'd spend for an easier route").font(.footnote).foregroundStyle(.secondary)
                Picker("Extra time", selection: $budget) {
                    ForEach([0, 2, 5, 10], id: \.self) { Text($0 == 0 ? "None" : "\($0) min").tag($0) }
                }.pickerStyle(.segmented)
            }
            stateContent
        }
    }

    private var places: some View {
        HStack(spacing: 4) {
            VStack(spacing: 0) {
                placeButton(place: origin, target: .origin)
                Divider().padding(.leading, 26)
                placeButton(place: destination, target: .destination)
            }
            Button {
                let previous = origin; origin = destination; destination = previous
            } label: { Image(systemName: "arrow.up.arrow.down").font(.body).foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("Swap start and destination").accessibilityIdentifier("swap")
        }
        .padding(.leading, 14).padding(.trailing, 4)
        .background(.panelFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func placeButton(place: Place, target: Sheet) -> some View {
        let origin = target == .origin
        return Button { sheet = target } label: {
            HStack(spacing: 12) {
                Group {
                    if origin { Circle().strokeBorder(.primary, lineWidth: 2.5) } else { Circle().fill(.calmer) }
                }.frame(width: 14, height: 14)
                Text(place.shortName).font(.body).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 0)
            }.frame(minHeight: landscape ? 40 : 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(origin ? "Starting from" : "Going to"), \(place.shortName)")
            .accessibilityIdentifier("choose-\(target.rawValue)")
    }

    @ViewBuilder private var stateContent: some View {
        switch session.state {
        case .idle, .loading:
            card {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Comparing Seattle streets…").font(.subheadline).foregroundStyle(.secondary)
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
                    routeRow(calmer, title: "Calmer", detail: summary(comparison), selected: selectedCalmer, calmer: true)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "equal.circle").font(.title3).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No calmer route").font(.headline)
                            Text("Nothing easier within this extra time.").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: rowHeight)
                        .accessibilityElement(children: .combine).accessibilityIdentifier("no-alternative")
                }
                Divider().padding(.leading, 30)
                routeRow(comparison.fastest, title: "Fastest", detail: "Estimate, no live traffic", selected: !selectedCalmer || comparison.calmer == nil, calmer: false)
            }
            Button { startNavigation(comparison) } label: {
                Text("Start").font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .foregroundStyle(.directionsText).background(.directionsFill, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("start-navigation")
            Button { sheet = .details } label: {
                HStack {
                    Text("Why this route").font(.subheadline).foregroundStyle(.calmerText)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }.frame(minHeight: landscape ? 32 : 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Why this route")
                .accessibilityHint(summary(comparison))
                .accessibilityIdentifier("route-details")
        }
    }

    private var rowHeight: CGFloat { landscape ? 50 : 60 }
    private var routeListHeight: CGFloat { rowHeight * 2 + 1 }

    /// The main benefit, then what it costs in time.
    private func summary(_ comparison: RouteComparison) -> String {
        [comparison.reasons.first, comparison.extraTimeLabel].compactMap { $0 }.joined(separator: " · ")
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.panelFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func routeRow(_ route: Route, title: String, detail: String, selected: Bool, calmer: Bool) -> some View {
        Button { selectedCalmer = calmer } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(calmer ? Color.calmer : Color.fastest).frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title).font(.headline).foregroundStyle(.primary)
                        Text("\(route.duration) · \(route.distance)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(detail).font(.footnote).foregroundStyle(calmer ? Color.calmerText : Color.secondary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(calmer ? Color.calmer : Color.fastest)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, landscape ? 6 : 10)
            .frame(minHeight: rowHeight).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(title) route, \(route.duration), \(route.distance). \(detail)")
            .accessibilityIdentifier(calmer ? "route-calmer" : "route-fastest")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func status(title: String, message: String, button: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(button) { session.start(request) }.font(.subheadline.weight(.semibold)).padding(.top, 2)
                    .accessibilityIdentifier("retry-route")
            }.padding(14).frame(maxWidth: .infinity, minHeight: routeListHeight, alignment: .leading)
        }
    }
}
