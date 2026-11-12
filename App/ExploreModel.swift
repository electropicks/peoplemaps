import SwiftUI
import PeoplemapsCore

enum Sheet: String, Identifiable { case origin, destination, details, settings, favourites, preferences; var id: String { rawValue } }

enum Screen: Equatable {
    case home, search, place(Place), preview, navigating
    /// Identity of the panel content, so a new screen crossfades in place.
    var panelID: String { if case let .place(place) = self { "place-\(place.id)" } else { "\(self)" } }
    /// The screen's name without its place, for logs and reports.
    var name: String { String(String(describing: self).prefix { $0 != "(" }) }
}

/// Where the portrait sheet rests. Fit is sized to what's essential: home's search capsule and favourites, the place card, or
/// the preview's rating and buttons. Raised is the preview with its start, swap and extra time as well.
enum Stop { case fit, medium, raised, large }

/// Why location, or a pasted maps link, can't do what was just asked of it.
enum LocationNotice: String, Identifiable {
    case startGuidance, locate, outside, noFix, record, sharedOutside, sharedUnreadable
    var id: String { rawValue }
    var title: String {
        switch self {
        case .startGuidance, .locate, .record: "Location is off for PeopleMaps"
        case .outside: "You\u{2019}re outside the area we cover"
        case .noFix: "Can\u{2019}t find you right now"
        case .sharedOutside: "This place is outside your map area"
        case .sharedUnreadable: "PeopleMaps couldn\u{2019}t read this link"
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
        case .sharedOutside: RegionSelection.usesCounty ? RegionSelection.coverageSentence : "PeopleMaps can route only inside its offline Seattle area for now."
        case .sharedUnreadable: "Short links need a connection to open, and some link formats aren\u{2019}t supported yet. You can search for the place by name or address instead."
        }
    }
    var offersSettings: Bool { self == .startGuidance || self == .locate || self == .record }
}

/// Where the explore screens are and what they show, read by the map, each of the sheet's screens and the landscape card. Sizes and
/// measurements stay in the views that lay them out, so a row being measured redraws that screen and not the map.
@MainActor @Observable final class ExploreModel {
    let graph: StreetGraph
    let search: SearchIndex
    let router: any RouteComputing
    let session: RouteSession
    let saved = SavedPlacesStore()
    let preferences = RoutePreferencesStore()

    /// Nil shows an empty "Choose start" or "Choose destination" field, and no route.
    var origin: Place?
    var destination: Place?
    /// The last mode used; the place card's estimate uses it too.
    var mode: TravelMode = .drive
    var budget = 10
    var selectedCalmer = true
    var sheet: Sheet?
    var notice: LocationNotice?
    private(set) var screen = Screen.home
    var stop = Stop.fit
    /// Where home was resting, to go back to.
    var homeStop = Stop.fit
    var query = ""
    /// A pasted maps link that needs a choice: the search it filled in, where its results rank from, and the pin at its point.
    var shared: (query: String, near: Coordinate?, pin: Place?)?
    var readingLink = false
    /// The place a pasted link was matched to, so its card can say so.
    var sharedMatchID: String?
    /// Search was opened by Add in the favourites row: the place picked becomes a favourite.
    var addingFavourite = false
    /// The last name search had no answer for, offered as the name when the address or pin found next is kept.
    private(set) var missed: String?
    /// The place being named, and the name so far.
    var naming: Place?
    var nameDraft = ""
    /// The start the user chose last. Without location, a later Directions reuses it unless it is the new destination.
    var lastOrigin: Place?
    /// The device's last fix, kept only while location is allowed.
    var userLocation: Coordinate?
    /// The map is on the user because of Locate; a gesture ends it.
    var centred = false
    /// The nearest indexed address of the open place when it has none of its own.
    private(set) var placeNear: String?
    /// The place card's comparison and the request it answers; nil when no route could be found.
    private(set) var estimate: (request: RouteRequest, comparison: RouteComparison?)?
    /// Accessibility text sizes open the preview raised. Kept in step with the environment by `ExploreView`.
    var accessibilitySize = false

    init(graph: StreetGraph, search: SearchIndex, router: any RouteComputing) {
        self.graph = graph; self.search = search; self.router = router
        session = RouteSession(router: router)
    }

    var selectedPlace: Place? { if case let .place(place) = screen { place } else { nil } }
    /// Where the device is, as a start; nil without location.
    var here: Place? { userLocation.map(Place.currentLocation(at:)) }
    /// The user's location when the map can show it: inside the area we cover.
    var userInCoverage: Coordinate? { userLocation.flatMap { graph.coverage.contains($0) ? $0 : nil } }
    /// The selected place, or the destination of a preview that has no route yet.
    var mapSelection: Place? { selectedPlace ?? (screen == .preview && request == nil ? destination : nil) }
    /// Stays set while guiding, so the comparison survives and End returns to the same routes.
    var previewRequest: RouteRequest? { screen == .preview || screen == .navigating ? request : nil }
    /// Places show while browsing, never over a route or guidance.
    var showsPlaces: Bool { screen == .home || screen == .search || selectedPlace != nil }

    var request: RouteRequest? {
        guard let origin, let destination, graph.coverage.contains(origin.coordinate) else { return nil }
        return .init(origin: origin, destination: destination, mode: mode, extraMinutes: budget, preferences: preferences[mode])
    }
    private var searchCentre: Coordinate? { shared?.near ?? userLocation ?? origin?.coordinate ?? lastOrigin?.coordinate }
    /// Places kept under the user's own name lead, then the index, each under the name it was kept with.
    var results: [Place] {
        let found = search.search(query, near: searchCentre).map { saved.favourite(at: $0) ?? $0 }
        let keys = Set(found.map(SavedPlaces.key))
        return saved.matching(query).filter { !keys.contains(SavedPlaces.key($0)) } + found
    }
    /// What to offer when `results` is empty: three, so the other ways to get there stay above the keyboard.
    var closest: SearchIndex.Closest { search.closest(query, near: searchCentre, limit: 3) }
    var chosenRoute: Route? {
        guard request != nil, let comparison = session.comparison else { return nil }
        return selectedCalmer ? comparison.calmer ?? comparison.fastest : comparison.fastest
    }

    /// Every change of screen goes through here, so the sheet's stop always belongs to the screen's detents.
    func show(_ next: Screen) {
        if screen == .home, next != .home { homeStop = stop }
        switch next {
        case .home: stop = homeStop
        case .search: stop = .large
        case .place: stop = .fit
        case .preview: stop = accessibilitySize ? .raised : .fit
        case .navigating: break
        }
        centred = false
        screen = next
    }

    func raiseHome() { stop = .medium; homeStop = .medium }
    func lowerHome() { stop = .fit; homeStop = .fit }
    /// Pulling the search sheet down is the same as Cancel, at wherever it was let go.
    func searchLowered() { homeStop = stop; query = ""; addingFavourite = false; screen = .home }

    func open(_ place: Place) {
        let place = saved.favourite(at: place) ?? search.withAddress(place)
        query = ""
        if !place.canBeNamed { missed = nil }
        placeNear = place.address == nil && place.kind == .place && !place.isDroppedPin ? search.nearestAddress(to: place.coordinate)?.name : nil
        show(.place(place))
    }
    /// A search result: its place card, or a new favourite when Add opened the search.
    func picked(_ place: Place) {
        sharedMatchID = nil
        DriveLogger.use("search_pick", ["query": .string(query), "id": .string(place.id), "name": .string(place.name),
                                        "rank": .num(results.firstIndex { $0.id == place.id } ?? -1), "results": .num(results.count), "addingFavourite": .bool(addingFavourite)])
        guard addingFavourite else { open(place); return }
        let place = search.withAddress(place)
        if !saved.isFavourite(place) { saved.toggleFavourite(place) }
        cancelSearch()
    }
    func cancelSearch() { query = ""; addingFavourite = false; show(.home) }
    /// A maps link or coordinates pasted into search: our own matching place, a choice of near ones, or a pin
    /// (Docs/SEARCH.md, "Shared links"). Only a paste counts, so coordinates typed digit by digit don't jump early.
    func searchChanged(from old: String, to text: String) {
        if shared?.query != text { shared = nil }
        guard text.count > old.count + 1, let link = SharedLink.parse(text) else { return }
        take(link)
    }
    /// The Share Extension's hand-off (`peoplemaps://share?text=…`): the same handling as a paste. A link opens its
    /// place; plain words become the search. Guidance is never interrupted.
    func opened(_ url: URL) {
        guard let text = SharedLink.sharedText(opened: url), screen != .navigating else { return }
        sheet = nil; addingFavourite = false
        show(.search)
        if let link = SharedLink.parse(text) { take(link) }
        else { query = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ") }
    }
    func take(_ link: SharedLink) {
        switch link {
        case let .short(url, text):
            query = ""; readingLink = true
            Task {
                let found = await SharedLinkExpander().expand(url, text: text)
                readingLink = false
                if screen == .search { take(found) }
            }
        case let .unreadable(text): query = text ?? ""; notice = .sharedUnreadable
        // One destination at a time for now: a shared route gives its last stop.
        case let .route(_, stops, _): if let last = stops.last { take(.place(last)) }
        case let .place(stop):
            switch search.match(stop, covers: graph.coverage.contains, near: userLocation ?? origin?.coordinate ?? lastOrigin?.coordinate) {
            case let .place(place): addingFavourite = false; open(place); sharedMatchID = place.id
            case let .pin(place): addingFavourite = false; open(place)
            case let .candidates(text, near, pin): shared = (text, near, pin); query = text
            case .outside: query = ""; notice = .sharedOutside
            }
        }
    }

    // MARK: Places the map lacks

    /// Text search found nothing for. An address is not a name, so it is not kept.
    func remember(missed text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first, !first.isNumber, text.count <= SavedPlaces.nameLimit else { return }
        missed = text
    }
    /// Search gives way to the map at its lowest stop, to touch and hold the spot.
    func chooseOnMap() { query = ""; addingFavourite = false; homeStop = .fit; show(.home) }

    /// The star: an address or pin being kept is offered a name, since its own says only where it is.
    func toggleFavourite(_ place: Place) {
        let adding = !saved.isFavourite(place)
        saved.toggleFavourite(place)
        if adding, place.canBeNamed { nameDraft = missed ?? ""; naming = place }
    }
    func name(_ place: Place, _ name: String) {
        let named = saved.name(place, name)
        missed = nil
        if selectedPlace.map(SavedPlaces.key) == SavedPlaces.key(named) { screen = .place(named) }
        if let destination, SavedPlaces.key(destination) == SavedPlaces.key(named) { self.destination = named }
    }

    /// A start that follows the user moves with each new fix; an empty start fills in once one arrives.
    func followUser() {
        guard screen != .navigating else { return }
        if origin?.isCurrentLocation ?? true { origin = here }
    }

    /// Current location when allowed; otherwise the start the user chose last, unless that is where they are going.
    func start(for place: Place) -> Place? {
        here ?? lastOrigin.flatMap { $0.id == place.id || $0.isCurrentLocation ? nil : $0 }
    }

    func startDirections(to place: Place) {
        origin = start(for: place); destination = place
        saved.addRecent(place)
        show(.preview)
    }

    // MARK: The place card's estimate

    /// From where Directions would start, in the last-used mode, when both ends are inside the area we cover.
    func estimateRequest(for place: Place) -> RouteRequest? {
        guard graph.coverage.contains(place.coordinate), let from = start(for: place), graph.coverage.contains(from.coordinate) else { return nil }
        return .init(origin: from, destination: place, mode: mode, extraMinutes: budget, preferences: preferences[mode])
    }

    /// Runs off the main thread; SwiftUI cancels it when the card closes or shows another place.
    func loadEstimate(_ request: RouteRequest?) async {
        guard let request else { return }
        let comparison = try? await router.compare(request)
        guard !Task.isCancelled else { return }
        estimate = (request, comparison)
    }

    func readyEstimate(for place: Place) -> (request: RouteRequest, comparison: RouteComparison)? {
        guard let request = estimateRequest(for: place), let estimate, estimate.request == request,
              let comparison = estimate.comparison else { return nil }
        return (request, comparison)
    }

    /// An estimate is on its way for this place.
    func estimating(_ place: Place) -> Bool {
        guard let request = estimateRequest(for: place) else { return false }
        return estimate?.request != request
    }

    /// Starts the preview's comparison, reusing the place card's when it answered the same request.
    func compareForPreview() {
        guard let previewRequest else { session.cancel(); return }
        selectedCalmer = true
        if let estimate, estimate.request == previewRequest, let seed = estimate.comparison { session.start(previewRequest, seed: seed) } else { session.start(previewRequest) }
    }
}
