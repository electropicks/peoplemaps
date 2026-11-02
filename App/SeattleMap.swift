import SwiftUI
import MapLibre
import PeoplemapsCore

/// How the map's camera behaves while guiding (`Docs/NAVIGATION.md`, "Camera modes").
struct GuidanceCamera: Equatable {
    enum Mode { case followCourseUp, followNorthUp, overview, free }
    private(set) var mode = Mode.followCourseUp
    /// The follow mode Re-centre and leaving the overview return to.
    private(set) var follow = Mode.followCourseUp
    private var turnedWhenFreed = false
    var isFollowing: Bool { mode == .followCourseUp || mode == .followNorthUp }
    var courseUp: Bool { follow == .followCourseUp }
    /// Whether the map is turned to the heading right now: following heading-up, or a free look that began from it.
    var isTurned: Bool { mode == .followCourseUp || (mode == .free && turnedWhenFreed) }
    mutating func toggleOverview() { mode = mode == .overview ? follow : .overview }
    /// Flips between heading-up and north-up and follows again, wherever the camera was.
    mutating func toggleHeading() { follow = courseUp ? .followNorthUp : .followCourseUp; mode = follow }
    /// The user panned or pinched: the map stays where they left it until Re-centre.
    mutating func pan() { turnedWhenFreed = mode == .followCourseUp; mode = .free }
    mutating func recenter() { mode = follow }
}

/// What the map shows while guiding: only the route being followed, its destination and the user's puck.
struct Guidance: Equatable {
    let version: Int
    let coordinates: [Coordinate]
    let calmer: Bool
    let destination: Coordinate
    let user: Coordinate?
    /// The device's own fix, not snapped onto the route; the leader starts here. Nil falls back to `user`.
    var rawUser: Coordinate?
    /// The reroute gate has seen a good fix on the route: the leader is gone for the rest of this route.
    var reachedRoute = false
    /// Smoothed course in degrees from north, kept while stopped; nil until known.
    var heading: Double?
    /// The puck shows its heading wedge only while moving.
    var moving = false
    /// Metres of `coordinates` already driven, 0 on a fresh or rerouted line. The line is drawn in two parts at this point.
    var travelled = 0.0
    var camera = GuidanceCamera()
    /// Space the guidance chrome covers; the puck is centred in the rest.
    var inset = UIEdgeInsets.zero
}

struct SeattleMap: UIViewRepresentable {
    let comparison: RouteComparison?
    let selectedCalmer: Bool
    let recenter: Int
    /// Bumped by Locate: frames the user at neighbourhood zoom, whatever else is on the map.
    var locate = 0
    /// The selected place: the only green pin, centred in the visible map.
    var selected: Place?
    /// Where the device is, when known and inside coverage: a blue dot, and what Home frames at neighbourhood zoom.
    var user: Coordinate?
    /// Which way the device faces, in degrees from north, when known outside guidance. Nil draws a plain dot: no direction is invented.
    var userHeading: Double?
    /// South-west and north-east corners of the area we cover, framed by Home when the user's location is unknown.
    var coverage: [Coordinate] = []
    /// A long-press on the map, at that spot.
    var onLongPress: (Coordinate) -> Void = { _ in }
    var guidance: Guidance?
    /// The user panned or pinched: following stops while guiding, and Locate is no longer centred otherwise.
    var onCameraGesture: () -> Void = {}
    /// Space covered by the panel and map buttons, kept clear when fitting routes.
    let padding: UIEdgeInsets
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: Bundle.main.url(forResource: "offline-style", withExtension: "json"))
        map.delegate = context.coordinator
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true // Linked OSM attribution is always visible in SwiftUI map chrome.
        map.compassView.isHidden = true
        map.automaticallyAdjustsContentInset = false // Fitting uses explicit padding instead.
        map.showsUserLocation = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.minimumZoomLevel = 11
        map.maximumZoomLevel = 18
        map.setCenter(CLLocationCoordinate2D(latitude: 47.649, longitude: -122.349), zoomLevel: 12, animated: false)
        map.addGestureRecognizer(UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPressed(_:))))
        context.coordinator.latest = self
        return map
    }
    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.latest = self
        // Read here, where the environment is live, not later from a stored copy of this struct.
        context.coordinator.reduce = reduceMotion
        context.coordinator.update(map)
    }

    // MapLibre delivers its view delegate callbacks on the UI thread; its ObjC protocol predates Swift concurrency.
    @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        var latest: SeattleMap?
        /// Reduce Motion, copied from the environment on every update.
        var reduce = false
        private var routeKey = ""
        private var recenterID = -1
        private var locateID = -1
        private var fittedPadding = UIEdgeInsets.zero
        private var styleReady = false
        private var appliedScheme: ColorScheme?
        private var traits = UITraitCollection(userInterfaceStyle: .light)
        private var labels: [MapLabel] = []
        private var endpoints: [MLNPointAnnotation] = []
        private var pinAnnotations: [MLNPointAnnotation] = []
        private var pinKey = ""
        private var userDot: MapPuck?
        private var focusKey = ""
        private var guiding = false
        private var guidanceKey = ""
        private var guidanceMode = ""
        private var lastUser: Coordinate?
        private var lastRaw: Coordinate?
        private var lastReached = false
        private var lastHeading: Double?
        private var guidanceAnnotations: [MLNPointAnnotation] = []
        private var puck: MapPuck?
        /// Puck-to-route gap under which no leader is drawn.
        private static let leaderMeters = RerouteGate.reachedMeters
        /// What the puck's wedge shows, re-applied when its view is rebuilt for a colour change.
        private var puckHeading: Double?
        private var cameraMode: GuidanceCamera.Mode?
        /// The first fit after launch cuts; later ones glide.
        private var hasFitted = false
        /// Following zooms back in after the overview or when guidance starts.
        private var followZoom = true
        private var lastFollow = Date.distantPast
        /// While the zoom-in runs, later positions retarget it instead of cutting it short.
        private var zoomUntil = Date.distantPast
        /// While a fly runs, follow ticks leave the camera alone: a new `setCamera` would cancel the flight.
        private var flyUntil = Date.distantPast
        /// Padding follows the sheet's live height, so a refit waits until it has stopped changing.
        private var paddingRefit: DispatchWorkItem?
        private var paddingSettled = false
        /// Where the passed/ahead split was last drawn, in metres along the line; -1 forces a redraw.
        private var splitAt = -1.0
        private var userDotHeading: Double?

        private static let baseLayers: [(id: String, color: UIColor)] = [
            ("water", .mapWater), ("parks", .mapPark), ("roads", .mapStreet), ("arterials", .mapArterial), ("paths", .mapPath),
        ]

        func mapViewDidBecomeIdle(_ map: MLNMapView) {
            AppEvents.shared.log(.map, "map idle", coalesce: true, ["zoom": map.zoomLevel])
            #if DEBUG
            MapDebug.shared.baseFeatures = map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: ["water", "roads", "arterials"]).count
            #endif
        }

        func mapView(_ map: MLNMapView, didFinishLoading style: MLNStyle) {
            AppEvents.shared.log(.map, "map style loaded")
            guard let url = StreetGraph.mapURL, let tiles = URL(string: "pmtiles://" + url.absoluteString) else { return }
            let source = MLNVectorTileSource(identifier: "seattle", configurationURL: tiles)
            style.addSource(source)
            for (id, kind) in [("water", "water"), ("parks", "park")] {
                let layer = MLNFillStyleLayer(identifier: id, source: source)
                layer.sourceLayerIdentifier = kind
                style.addLayer(layer)
            }
            for (id, kind, width) in [("roads", "road", 2.0), ("arterials", "arterial", 2.7), ("paths", "path", 0.8)] {
                let layer = MLNLineStyleLayer(identifier: id, source: source)
                layer.sourceLayerIdentifier = kind
                // The same widths as before from z13; narrower when zoomed out, or downtown's grid merges into a block.
                layer.lineWidth = kind == "path" ? NSExpression(forConstantValue: width)
                    : NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)", [10: width * 0.5, 13: width])
                layer.lineOpacity = NSExpression(forConstantValue: kind == "path" ? 0.7 : 1)
                style.addLayer(layer)
            }
            for (id, width) in [("fastest-casing", 8.0), ("fastest", 4.5), ("calmer-casing", 9.5), ("calmer", 5.5)] {
                let source = MLNShapeSource(identifier: id, shape: nil, options: nil)
                style.addSource(source)
                let layer = MLNLineStyleLayer(identifier: id, source: source)
                layer.lineWidth = NSExpression(forConstantValue: width)
                layer.lineJoin = NSExpression(forConstantValue: "round")
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineOpacityTransition = MLNTransition(duration: 0.25, delay: 0)
                style.addLayer(layer)
            }
            // The part of the followed route already driven: thinner and muted, above the route lines and below the leader.
            for (id, width) in [("passed-casing", 6.0), ("passed", 3.5)] {
                let source = MLNShapeSource(identifier: id, shape: nil, options: nil)
                style.addSource(source)
                let layer = MLNLineStyleLayer(identifier: id, source: source)
                layer.lineWidth = NSExpression(forConstantValue: width)
                layer.lineJoin = NSExpression(forConstantValue: "round")
                layer.lineCap = NSExpression(forConstantValue: "round")
                style.addLayer(layer)
            }
            // Dashed line from the puck to a route that starts some way off, in the route's colour.
            let leaderSource = MLNShapeSource(identifier: "leader", shape: nil, options: nil)
            style.addSource(leaderSource)
            let leader = MLNLineStyleLayer(identifier: "leader", source: leaderSource)
            leader.lineWidth = NSExpression(forConstantValue: 4.5)
            leader.lineDashPattern = NSExpression(forConstantValue: [1.5, 1.5])
            leader.lineOpacity = NSExpression(forConstantValue: 0.9)
            style.addLayer(leader)
            let places: [(String, Double, Double)] = [("BALLARD",47.668,-122.382),("FREMONT",47.652,-122.351),("WALLINGFORD",47.663,-122.335),("QUEEN ANNE",47.637,-122.360),("LAKE UNION",47.639,-122.335),("UNIVERSITY\nDISTRICT",47.665,-122.313)]
            labels = places.map { title, lat, lon in
                let annotation = MapLabel(); annotation.title = title
                annotation.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                return annotation
            }
            styleReady = true; routeKey = ""; appliedScheme = nil; update(map)
        }

        func update(_ map: MLNMapView) {
            guard styleReady, let latest, let style = map.style else { return }
            let c = latest.comparison
            if appliedScheme != latest.colorScheme {
                applyColors(latest.colorScheme, map: map, style: style)
            }
            if let guidance = latest.guidance { updateGuidance(guidance, map: map, style: style); return }
            if guiding { endGuidance(map: map, style: style) }
            let key = "\(c?.fastest.id ?? "none")|\(c?.calmer?.id ?? "none")|\(latest.selectedCalmer)"
            let changed = key != routeKey
            if changed {
                let appearing = c != nil && !routeKey.hasPrefix(c!.fastest.id)
                for id in ["fastest-casing", "fastest"] { (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = shape(c?.fastest) }
                for id in ["calmer-casing", "calmer"] { (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = shape(c?.calmer) }
                let opacities = ["fastest": latest.selectedCalmer && c?.calmer != nil ? 0.55 : 1.0, "calmer": latest.selectedCalmer ? 1.0 : 0.4]
                // New routes fade in over the opacity transition; switching calmer and fastest crossfades the same way.
                raiseRoute(latest.selectedCalmer ? "calmer" : "fastest", style)
                if appearing { setRouteOpacity(style) { _ in 0 } }
                let apply: () -> Void = { [weak self] in self?.setRouteOpacity(style) { opacities[$0] ?? 1 } }
                if appearing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { apply() } } else { apply() }
                map.removeAnnotations(endpoints); endpoints = []
                if let c {
                    let start = MapOrigin(), end = MapDestination()
                    start.coordinate = CLLocationCoordinate2D(latitude: c.snappedOrigin.lat, longitude: c.snappedOrigin.lon)
                    end.coordinate = CLLocationCoordinate2D(latitude: c.snappedDestination.lat, longitude: c.snappedDestination.lon)
                    endpoints = [start, end]
                    map.addAnnotations(endpoints)
                }
            }
            let pk = pinKey(latest)
            if pk != pinKey {
                map.removeAnnotations(pinAnnotations)
                pinAnnotations = latest.selected.map { [MapPin(place: $0)] } ?? []
                map.addAnnotations(pinAnnotations)
                pinKey = pk
            }
            if userDot?.coordinate.latitude != latest.user?.lat || userDot?.coordinate.longitude != latest.user?.lon {
                if let userDot { map.removeAnnotation(userDot) }
                userDot = latest.user.map { user in
                    let dot = MapPuck(); dot.coordinate = CLLocationCoordinate2D(latitude: user.lat, longitude: user.lon); return dot
                }
                userDotHeading = latest.userHeading
                if let userDot { map.addAnnotation(userDot) }
            } else if let userDot, latest.userHeading != userDotHeading {
                userDotHeading = latest.userHeading
                (map.view(for: userDot) as? PuckView)?.show(heading: latest.userHeading, arrow: false, duration: Motion.camera(reduce, 0.25))
            }
            #if DEBUG
            MapDebug.shared.marker = latest.user == nil ? "none" : latest.userHeading.map { "dot \(Int($0.rounded()))" } ?? "dot"
            #endif
            // Home refits once when the user's location first becomes known, never on later fixes.
            let focus = c != nil ? "route" : latest.selected?.id ?? (latest.user != nil ? "home-user" : "home")
            let focusChanged = focus != focusKey
            let paddingChanged = (abs(fittedPadding.bottom - latest.padding.bottom) > 1 || abs(fittedPadding.left - latest.padding.left) > 1)
            let recentered = recenterID >= 0 && recenterID != latest.recenter
            let located = locateID >= 0 && locateID != latest.locate && latest.user != nil
            // Padding tracks the sheet's live height, so it changes on every frame of a detent move or drag. Fitting on each
            // one restarted the camera animation 60 times a second; it refits once, after the sheet has stopped.
            let refit = paddingChanged && paddingSettled
            if paddingChanged && !refit && !(focusChanged || recentered || located || (changed && c != nil)) { schedulePaddingRefit(map) }
            if focusChanged || refit || recentered || located || (changed && c != nil) {
                paddingRefit?.cancel(); paddingSettled = false
                var points = located ? [] : (c?.fastest.coordinates ?? []) + (c?.calmer?.coordinates ?? [])
                if !located, points.isEmpty, let place = latest.selected {
                    // A neighbourhood-sized window around the place, so it lands in the middle of the visible map.
                    points = [Coordinate(lat: place.lat - 0.004, lon: place.lon - 0.006), Coordinate(lat: place.lat + 0.004, lon: place.lon + 0.006)]
                }
                if points.isEmpty, !recentered, let user = latest.user {
                    points = [Coordinate(lat: user.lat - 0.004, lon: user.lon - 0.006), Coordinate(lat: user.lat + 0.004, lon: user.lon + 0.006)]
                }
                if points.isEmpty { points = latest.coverage }
                if !points.isEmpty {
                    let sw = CLLocationCoordinate2D(latitude: points.map(\.lat).min()!, longitude: points.map(\.lon).min()!)
                    let ne = CLLocationCoordinate2D(latitude: points.map(\.lat).max()!, longitude: points.map(\.lon).max()!)
                    let pad = fitting(latest.padding, in: map.bounds.size)
                    let camera = map.cameraThatFitsCoordinateBounds(MLNCoordinateBounds(sw: sw, ne: ne), edgePadding: pad)
                    // A padding-only refit is a small correction; a real change of focus may be a long way.
                    move(map, to: camera, duration: hasFitted ? 0.5 : 0, padding: pad, mayFly: !refit)
                    fittedPadding = latest.padding; hasFitted = true
                }
            }
            focusKey = focus
            routeKey = key; recenterID = latest.recenter; locateID = latest.locate
        }

        private func setRouteOpacity(_ style: MLNStyle, _ value: (String) -> Double) {
            guard latest?.guidance == nil else { return }
            for id in ["fastest", "calmer"] {
                for layer in [id, id + "-casing"] { (style.layer(withIdentifier: layer) as? MLNLineStyleLayer)?.lineOpacity = NSExpression(forConstantValue: value(id)) }
            }
        }

        /// The selected route draws on top, so it stays visible where the two nearly overlap.
        private func raiseRoute(_ id: String, _ style: MLNStyle) {
            guard let passed = style.layer(withIdentifier: "passed-casing") else { return }
            for layerID in [id + "-casing", id] {
                guard let layer = style.layer(withIdentifier: layerID) else { continue }
                style.removeLayer(layer)
                style.insertLayer(layer, below: passed)
            }
            #if DEBUG
            let drawn = style.layers.map(\.identifier)
            MapDebug.shared.topRoute = (drawn.firstIndex(of: "fastest") ?? -1) > (drawn.firstIndex(of: "calmer") ?? -1) ? "fastest" : "calmer"
            #endif
        }

        /// Refits once the padding has stopped changing, not on each frame of the sheet's move.
        private func schedulePaddingRefit(_ map: MLNMapView) {
            paddingRefit?.cancel()
            let work = DispatchWorkItem { [weak self, weak map] in
                guard let self, let map else { return }
                self.paddingSettled = true
                self.update(map)
                self.paddingSettled = false
            }
            paddingRefit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        /// The one place the camera moves. `duration` is what a normal move takes; Reduce Motion and `--ui-testing` drop it here,
        /// so no caller can cut by accident, and a move that crosses a lot of map flies instead of sweeping.
        ///
        /// - Near: a timed ease (`timing`).
        /// - Far (more than three-quarters of the screen away, or more than 2.5 zoom levels apart): `fly(to:)`, which
        ///   zooms out and back in, so the tiles in between are loaded at a coarse zoom instead of flashing past blank.
        /// - Reduce Motion: near moves cut; far moves dip the map out and in (a cross-fade), never a sweep.
        /// A fitted camera is centred on its bounds, so it needs the same padding it was fitted with; following uses the content inset.
        private func move(_ map: MLNMapView, to camera: MLNMapCamera, duration: TimeInterval, timing: CAMediaTimingFunctionName = .easeInEaseOut,
                          padding: UIEdgeInsets? = nil, mayFly: Bool = true) {
            let pad = padding ?? .zero
            let far = mayFly && duration > 0 && crossesALot(map, to: camera)
            AppEvents.shared.log(.map, "camera move", coalesce: true, ["ms": (Motion.off ? 0 : duration) * 1000, "animated": duration > 0 && !Motion.off ? 1 : 0, "zoom": map.zoomLevel])
            #if DEBUG
            let kind = far ? (reduce ? "fade" : "fly") : duration > 0 ? "glide" : "cut"; if mayFly || kind != "cut" { MapDebug.shared.moves = Array((MapDebug.shared.moves + [kind]).suffix(12)) }
            #endif
            let cut = { map.setCamera(camera, withDuration: 0, animationTimingFunction: nil, edgePadding: pad, completionHandler: nil) }
            if Motion.off || duration <= 0 {
                cut()
            } else if reduce {
                if far { crossFade(map, jump: cut) } else { cut() }
            } else if far {
                let span = Double(map.bounds.width) * map.metersPerPoint(atLatitude: map.centerCoordinate.latitude)
                let ratio = Self.distance(map.centerCoordinate, camera.centerCoordinate) / max(span, 1)
                let flight = min(1.8, max(1.0, 0.7 + 0.25 * log2(1 + ratio)))
                flyUntil = Date().addingTimeInterval(flight)
                map.fly(to: camera, edgePadding: pad, withDuration: flight, completionHandler: nil)
            } else {
                flyUntil = .distantPast
                map.setCamera(camera, withDuration: duration, animationTimingFunction: CAMediaTimingFunction(name: timing), edgePadding: pad, completionHandler: nil)
            }
        }

        private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
            Coordinate(lat: a.latitude, lon: a.longitude).distance(to: Coordinate(lat: b.latitude, lon: b.longitude))
        }

        private func crossesALot(_ map: MLNMapView, to camera: MLNMapCamera) -> Bool {
            guard map.bounds.width > 0 else { return false }
            let span = Double(map.bounds.width) * map.metersPerPoint(atLatitude: map.centerCoordinate.latitude)
            let zoom = MLNZoomLevelForAltitude(camera.altitude, camera.pitch, camera.centerCoordinate.latitude, map.bounds.size)
            return Self.distance(map.centerCoordinate, camera.centerCoordinate) > span * 0.75 || abs(zoom - map.zoomLevel) > 2.5
        }

        /// Reduce Motion's stand-in for a long camera move: the map fades out, jumps while unseen and fades back in.
        private func crossFade(_ map: MLNMapView, jump: @escaping () -> Void) {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) { map.alpha = 0 } completion: { _ in
                jump()
                UIView.animate(withDuration: 0.25, delay: 0.1, options: [.beginFromCurrentState, .curveEaseOut]) { map.alpha = 1 }
            }
        }

        /// Changing the inset directly cuts the camera to the new centre; this eases it over the same time as the move around it.
        private func setInset(_ map: MLNMapView, _ inset: UIEdgeInsets) {
            guard map.contentInset != inset else { return }
            let animated = !Motion.off && !reduce
            map.setContentInset(inset, animated: animated, completionHandler: nil)
        }

        private func clearRoutes(_ style: MLNStyle) {
            for id in ["fastest-casing", "fastest", "calmer-casing", "calmer"] {
                (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = nil
                (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineOpacity = NSExpression(forConstantValue: 1.0)
            }
            for id in ["passed-casing", "passed"] { (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = nil }
            splitAt = -1
            #if DEBUG
            if guiding { MapDebug.shared.routeClears += 1 }
            #endif
        }

        /// Guidance draws the followed route, the destination and the puck, and moves the camera as the mode says:
        /// following keeps the puck centred (heading-up puts it in the lower third), the overview fits the route, free leaves the map alone.
        private func updateGuidance(_ g: Guidance, map: MLNMapView, style: MLNStyle) {
            if !guiding {
                clearRoutes(style)
                guiding = true
                map.removeAnnotations(endpoints + pinAnnotations + (userDot.map { [$0] } ?? []))
                endpoints = []; pinAnnotations = []; pinKey = ""; userDot = nil; guidanceKey = ""; lastUser = nil; lastHeading = nil; lastRaw = nil; lastReached = false; cameraMode = nil
                followZoom = true
                if g.user == nil { aim(at: g.coordinates[0], map: map, courseUp: false, heading: nil) }
            }
            let key = "\(g.version)|\(g.calmer)"
            let mode = "\(g.camera.mode)|\(Int(g.inset.top))|\(Int(g.inset.left))|\(Int(g.inset.bottom))|\(Int(g.inset.right))|\(Int(map.bounds.height))|\(g.version)"
            if mode != guidanceMode {
                guidanceMode = mode
                lastUser = nil
                switch g.camera.mode {
                case .overview:
                    followZoom = true
                    setInset(map, .zero)
                    let lats = g.coordinates.map(\.lat), lons = g.coordinates.map(\.lon)
                    let sw = CLLocationCoordinate2D(latitude: lats.min()!, longitude: lons.min()!)
                    let ne = CLLocationCoordinate2D(latitude: lats.max()!, longitude: lons.max()!)
                    let pad = UIEdgeInsets(top: g.inset.top + 24, left: g.inset.left + 32, bottom: g.inset.bottom + 24, right: max(g.inset.right, 16) + 32)
                    let fitted = fitting(pad, in: map.bounds.size)
                    let northUp = map.camera; northUp.heading = 0
                    let camera = map.camera(northUp, fitting: MLNCoordinateBounds(sw: sw, ne: ne), edgePadding: fitted)
                    move(map, to: camera, duration: 0.5, padding: fitted)
                case .followCourseUp, .followNorthUp:
                    // Coming back from the overview or a free look zooms back in; flipping heading-up and north-up eases the
                    // turn over `Motion.camera`; a reroute keeps the current zoom.
                    if cameraMode != .followCourseUp && cameraMode != .followNorthUp { followZoom = true }
                    else if cameraMode != g.camera.mode { zoomUntil = Date().addingTimeInterval(Motion.camera(reduce)) }
                    setInset(map, followInset(g, in: map.bounds.size))
                case .free:
                    break
                }
                cameraMode = g.camera.mode
            }
            if key != guidanceKey {
                // A reroute replaces the line in place: the new shape goes in, and only the other pair is emptied.
                // Until the replacement arrives the previous route stays drawn.
                let prefix = g.calmer ? "calmer" : "fastest"
                splitAt = -1
                let other = g.calmer ? "fastest" : "calmer"
                if (style.source(withIdentifier: other) as? MLNShapeSource)?.shape != nil {
                    for id in [other, other + "-casing"] { (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = nil }
                }
                (style.layer(withIdentifier: "leader") as? MLNLineStyleLayer)?.lineColor = constant(g.calmer ? .calmer : .fastest)
                #if DEBUG
                // What the drawn line is styled as, read back from the layers: fastest is the palette's grey, calmer the green.
                let colour: (String) -> String = { id in ((style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineColor?.constantValue as? UIColor)?.hexString ?? "none" }
                MapDebug.shared.lineStyle = "\(prefix) \(colour(prefix)) leader \(colour("leader"))"
                #endif
                drawProgress(g, style: style)
                map.removeAnnotations(guidanceAnnotations)
                let end = MapDestination()
                end.coordinate = CLLocationCoordinate2D(latitude: g.destination.lat, longitude: g.destination.lon)
                guidanceAnnotations = [end]
                map.addAnnotations(guidanceAnnotations)
                guidanceKey = key
            }
            drawProgress(g, style: style)
            // The arrow keeps the last known course while stopped, as the map does; the dot never invents one.
            let heading = g.heading
            if let user = g.user, user != lastUser || heading != lastHeading || g.rawUser != lastRaw || g.reachedRoute != lastReached {
                let tick = Motion.camera(reduce, min(1, max(0.1, Date().timeIntervalSince(lastFollow))))
                lastFollow = Date()
                placePuck(user, heading: heading, map: map, duration: tick)
                if g.camera.isFollowing { aim(at: user, map: map, courseUp: g.camera.courseUp, heading: g.heading, tick: tick) }
                drawLeader(from: g.rawUser ?? user, g, style: style)
                lastUser = user; lastHeading = heading; lastRaw = g.rawUser; lastReached = g.reachedRoute
            }
        }

        /// Splits the followed line at the user's progress: the part behind goes to the muted `passed` layers, the part ahead stays on
        /// the route's own layers. Only the two sources' shapes change, in place and in the same turn, so nothing blanks and no
        /// layer is added or removed. It redraws every 4 m of progress, and on a new line (`splitAt` reset).
        private func drawProgress(_ g: Guidance, style: MLNStyle) {
            let travelled = min(max(0, g.travelled), RouteLine.length(g.coordinates))
            guard splitAt < 0 || abs(travelled - splitAt) >= 4 else { return }
            splitAt = travelled
            let (passed, ahead) = RouteLine.split(g.coordinates, atMeters: travelled)
            func shape(_ line: [Coordinate]) -> MLNPolyline? {
                guard line.count > 1 else { return nil }
                var coords = line.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                return MLNPolyline(coordinates: &coords, count: UInt(coords.count))
            }
            let prefix = g.calmer ? "calmer" : "fastest"
            let aheadShape = shape(ahead), passedShape = shape(passed)
            for id in [prefix, prefix + "-casing"] { (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = aheadShape }
            for id in ["passed", "passed-casing"] { (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = passedShape }
            #if DEBUG
            let colour = ((style.layer(withIdentifier: "passed") as? MLNLineStyleLayer)?.lineColor?.constantValue as? UIColor)?.hexString ?? "none"
            MapDebug.shared.passed = "\(Int(RouteLine.length(passed).rounded())) ahead \(Int(RouteLine.length(ahead).rounded())) \(colour)"
            #endif
        }

        /// A dashed leader from the device's own fix to the route's first coordinate while they are apart and the reroute gate
        /// has not seen the user on the route (a good fix within `RerouteGate.reachedMeters`): the start is a snapped node, so a trip can begin a block from where the line does.
        private func drawLeader(from user: Coordinate, _ g: Guidance, style: MLNStyle) {
            let source = style.source(withIdentifier: "leader") as? MLNShapeSource
            let gap = g.coordinates.first.map { user.distance(to: $0) } ?? 0
            let drawn = !g.reachedRoute && gap > Self.leaderMeters
            if drawn, let first = g.coordinates.first {
                var coords = [user, first].map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                source?.shape = MLNPolyline(coordinates: &coords, count: 2)
            } else if source?.shape != nil {
                source?.shape = nil
            }
            #if DEBUG
            MapDebug.shared.leaderMeters = drawn ? gap : 0
            #endif
        }

        /// Heading-up puts the puck a third of the way up the free map area, so most of the screen shows the road ahead.
        private func followInset(_ g: Guidance, in size: CGSize) -> UIEdgeInsets {
            var inset = g.inset
            if g.camera.mode == .followCourseUp { inset.top += max(0, size.height - g.inset.top - g.inset.bottom) / 3 }
            return inset
        }

        /// Glides the puck between position updates and turns its arrow, so following looks continuous.
        private func placePuck(_ user: Coordinate, heading: Double?, map: MLNMapView, duration: TimeInterval) {
            let point = CLLocationCoordinate2D(latitude: user.lat, longitude: user.lon)
            if let puck {
                if duration > 0 { UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear, .beginFromCurrentState]) { puck.coordinate = point } }
                else { puck.coordinate = point }
            } else {
                let new = MapPuck(); new.coordinate = point; puck = new; map.addAnnotation(new)
            }
            puckHeading = heading
            (puck.flatMap { map.view(for: $0) } as? PuckView)?.show(heading: heading, arrow: true, duration: duration)
            #if DEBUG
            MapDebug.shared.marker = heading.map { "arrow \(Int($0.rounded()))" } ?? "dot"
            #endif
        }

        /// Moves the camera onto the user. Zooming in (start, leaving the overview or a free look) is a longer eased move;
        /// in between, positions and heading changes glide linearly over the time since the last fix.
        private func aim(at user: Coordinate, map: MLNMapView, courseUp: Bool, heading: Double?, tick: TimeInterval = 0) {
            let point = CLLocationCoordinate2D(latitude: user.lat, longitude: user.lon)
            guard Date() >= flyUntil else { return }
            let camera = map.camera
            camera.centerCoordinate = point
            camera.heading = courseUp ? (heading ?? camera.heading) : 0
            let zooming = Date() < zoomUntil
            if followZoom || zooming {
                camera.altitude = MLNAltitudeForZoomLevel(16, 0, point.latitude, map.bounds.size)
                let first = followZoom
                if followZoom { zoomUntil = Date().addingTimeInterval(Motion.camera(reduce, 0.8)); followZoom = false }
                // The first call is the zoom-in (it may fly); later ones while it runs retarget with an ease-out, not a new ease-in.
                move(map, to: camera, duration: first ? 0.8 : max(0, zoomUntil.timeIntervalSinceNow), timing: first ? .easeInEaseOut : .easeOut, mayFly: first)
            } else {
                move(map, to: camera, duration: tick, timing: .linear)
            }
        }

        private func endGuidance(map: MLNMapView, style: MLNStyle) {
            guiding = false
            map.removeAnnotations(guidanceAnnotations + (puck.map { [$0] } ?? []))
            guidanceAnnotations = []; puck = nil; lastUser = nil; lastHeading = nil; puckHeading = nil; cameraMode = nil
            guidanceKey = ""; guidanceMode = ""; lastFollow = .distantPast; zoomUntil = .distantPast; flyUntil = .distantPast; splitAt = -1
            setInset(map, .zero)
            if map.camera.heading != 0 { let camera = map.camera; camera.heading = 0; move(map, to: camera, duration: 0.5, mayFly: false) }
            clearRoutes(style)
            (style.source(withIdentifier: "leader") as? MLNShapeSource)?.shape = nil
            #if DEBUG
            MapDebug.shared.leaderMeters = 0
            #endif
            routeKey = ""; focusKey = ""; pinKey = ""
        }

        /// A pan, pinch or zoom gesture hands the camera to the user.
        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            if guiding, latest?.guidance?.camera.mode == .free { return }
            let gestures: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureZoomIn, .gestureZoomOut, .gestureOneFingerZoom, .gestureRotate]
            if !reason.isDisjoint(with: gestures) { latest?.onCameraGesture() }
        }

        private func pinKey(_ s: SeattleMap) -> String { s.selected?.id ?? "" }

        @objc func longPressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let map = gesture.view as? MLNMapView else { return }
            let c = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            latest?.onLongPress(Coordinate(lat: c.latitude, lon: c.longitude))
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            mapView.deselectAnnotation(annotation, animated: false)
        }

        /// Map colours are constants in the style, so they are resolved for the current scheme and re-applied when it changes.
        private func applyColors(_ scheme: ColorScheme, map: MLNMapView, style: MLNStyle) {
            appliedScheme = scheme
            traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            (style.layer(withIdentifier: "background") as? MLNBackgroundStyleLayer)?.backgroundColor = constant(.mapLand)
            for (id, color) in Self.baseLayers {
                if let fill = style.layer(withIdentifier: id) as? MLNFillStyleLayer { fill.fillColor = constant(color) }
                if let line = style.layer(withIdentifier: id) as? MLNLineStyleLayer { line.lineColor = constant(color) }
            }
            for (id, color) in [("fastest-casing", UIColor.systemBackground), ("fastest", .fastest), ("calmer-casing", .systemBackground), ("calmer", .calmer)] {
                (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineColor = constant(color)
            }
            for (id, color) in [("passed-casing", UIColor.systemBackground), ("passed", .passedRoute)] {
                (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineColor = constant(color)
            }
            (style.layer(withIdentifier: "leader") as? MLNLineStyleLayer)?.lineColor = constant(latest?.guidance?.calmer == true ? .calmer : .fastest)
            // Annotation views are drawn once, so re-add them to pick up the new colours.
            let extras: [MLNPointAnnotation] = guidanceAnnotations + (puck.map { [$0] } ?? []) + (userDot.map { [$0] } ?? [])
            map.removeAnnotations(labels + endpoints + pinAnnotations + extras)
            map.addAnnotations(labels + endpoints + pinAnnotations + extras)
        }
        private func constant(_ color: UIColor) -> NSExpression { NSExpression(forConstantValue: color.resolvedColor(with: traits)) }

        /// Never asks for more padding than the map has room for, or MapLibre ignores the fit.
        private func fitting(_ padding: UIEdgeInsets, in size: CGSize) -> UIEdgeInsets {
            var p = padding
            let spareX = size.width - p.left - p.right - 80, spareY = size.height - p.top - p.bottom - 80
            if spareX < 0 { p.left = max(16, p.left + spareX / 2); p.right = max(16, p.right + spareX / 2) }
            if spareY < 0 { p.top = max(16, p.top + spareY / 2); p.bottom = max(16, p.bottom + spareY / 2) }
            return p
        }

        private func shape(_ route: Route?) -> MLNPolyline? {
            guard let route, route.coordinates.count > 1 else { return nil }
            var coordinates = route.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            return MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            let background = UIColor.systemBackground.resolvedColor(with: traits)
            let view: MLNAnnotationView
            switch annotation {
            case is MapOrigin:
                view = MLNAnnotationView(reuseIdentifier: nil)
                view.frame = CGRect(x: 0, y: 0, width: 18, height: 18)
                view.backgroundColor = background
                view.layer.borderColor = UIColor.label.resolvedColor(with: traits).cgColor
                view.layer.borderWidth = 4
                view.layer.cornerRadius = 9
            case let dot as MapPuck:
                let puckView = PuckView(traits: traits)
                if dot === puck { puckView.show(heading: puckHeading, arrow: true, duration: 0) }
                else if let heading = userDotHeading { puckView.show(heading: heading, arrow: false, duration: 0) }
                view = puckView
            case is MapDestination:
                view = MLNAnnotationView(reuseIdentifier: nil)
                view.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
                view.backgroundColor = UIColor.calmer.resolvedColor(with: traits)
                view.layer.borderColor = background.cgColor
                view.layer.borderWidth = 3
                view.layer.cornerRadius = 11
            case let pin as MapPin:
                view = MLNAnnotationView(reuseIdentifier: nil)
                view.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
                view.backgroundColor = UIColor.calmer.resolvedColor(with: traits)
                view.layer.borderColor = background.cgColor
                view.layer.borderWidth = 3
                view.layer.cornerRadius = 11
                view.isAccessibilityElement = true
                view.accessibilityLabel = pin.title
                fadeIn(view)
                return view
            case is MapLabel:
                view = MLNAnnotationView(reuseIdentifier: nil)
                let label = UILabel(); label.text = annotation.title ?? ""; label.textAlignment = .center; label.numberOfLines = 2
                label.font = .systemFont(ofSize: 9, weight: .semibold)
                label.textColor = UIColor.secondaryLabel.resolvedColor(with: traits)
                label.frame = CGRect(x: 0, y: 0, width: 95, height: 32)
                view.frame = label.bounds; view.addSubview(label)
            default:
                return nil
            }
            if annotation is MapOrigin || annotation is MapDestination { fadeIn(view) }
            view.isAccessibilityElement = false
            return view
        }

        /// The selected pin and route ends fade in instead of popping onto the map.
        private func fadeIn(_ view: UIView) {
            guard Motion.camera(reduce) > 0 else { return }
            view.alpha = 0
            UIView.animate(withDuration: 0.25, delay: 0.1, options: .curveEaseOut) { view.alpha = 1 }
        }
    }
}
private final class MapLabel: MLNPointAnnotation {}
private final class MapPin: MLNPointAnnotation {
    init(place: Place) {
        super.init()
        title = place.shortName
        coordinate = CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
private final class MapOrigin: MLNPointAnnotation {}
private final class MapPuck: MLNPointAnnotation {}

/// The user's marker, always `systemBlue` with a white ring and a faint dark halo, so it reads on light and dark land and on the
/// green or grey route line (the colour alone is not what separates them). The view turns with the map, so a layer's own rotation
/// is the course from north and heading-up leaves it pointing at the top of the screen.
///
/// - Plain dot: heading unknown. No direction is drawn.
/// - Dot with a beam and a rim tip: heading known outside guidance.
/// - Arrow: guidance, once a course is known. It replaces the dot, and keeps the last course while stopped.
private final class PuckView: MLNAnnotationView {
    private let turning = CALayer()
    private let beam = CAGradientLayer()
    private let tip = CAShapeLayer()
    private let dot = CALayer()
    private let arrow = CALayer()
    private var shown: Double?
    init(traits: UITraitCollection) {
        super.init(reuseIdentifier: nil)
        frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        rotatesToMatchCamera = true
        let blue = UIColor.systemBlue.resolvedColor(with: traits)
        let centre = CGPoint(x: 36, y: 36)
        turning.frame = bounds
        let cone = UIBezierPath()
        cone.move(to: centre)
        cone.addArc(withCenter: centre, radius: 36, startAngle: -.pi / 2 - .pi / 6, endAngle: -.pi / 2 + .pi / 6, clockwise: true)
        cone.close()
        let mask = CAShapeLayer(); mask.path = cone.cgPath
        beam.frame = bounds; beam.mask = mask; beam.type = .radial
        beam.startPoint = CGPoint(x: 0.5, y: 0.5); beam.endPoint = CGPoint(x: 1, y: 1)
        beam.colors = [blue.withAlphaComponent(0.6).cgColor, blue.withAlphaComponent(0).cgColor]
        turning.addSublayer(beam)
        // A small triangle on the dot's rim, pointing out: the heading cue that survives when the beam is faint.
        let nub = UIBezierPath()
        nub.move(to: CGPoint(x: 36, y: 11)); nub.addLine(to: CGPoint(x: 43, y: 25)); nub.addLine(to: CGPoint(x: 29, y: 25)); nub.close()
        tip.path = nub.cgPath; tip.fillColor = blue.cgColor
        tip.strokeColor = UIColor.white.cgColor; tip.lineWidth = 2.5; tip.lineJoin = .round
        turning.addSublayer(tip)
        layer.addSublayer(turning)
        dot.frame = CGRect(x: 25, y: 25, width: 22, height: 22)
        dot.backgroundColor = blue.cgColor
        dot.borderColor = UIColor.white.cgColor; dot.borderWidth = 3.5; dot.cornerRadius = 11
        dot.shadowColor = UIColor.black.cgColor; dot.shadowOpacity = 0.35; dot.shadowRadius = 3; dot.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(dot)
        // The navigation arrow: a chevron with a notch, 34 pt tall, centred on the position.
        arrow.frame = bounds
        let shape = UIBezierPath()
        shape.move(to: CGPoint(x: 36, y: 17)); shape.addLine(to: CGPoint(x: 50, y: 53)); shape.addLine(to: CGPoint(x: 36, y: 45))
        shape.addLine(to: CGPoint(x: 22, y: 53)); shape.close()
        let halo = CAShapeLayer()
        halo.path = shape.cgPath; halo.fillColor = UIColor.black.withAlphaComponent(0.35).cgColor
        halo.strokeColor = UIColor.black.withAlphaComponent(0.35).cgColor; halo.lineWidth = 7; halo.lineJoin = .round
        let body = CAShapeLayer()
        body.path = shape.cgPath; body.fillColor = blue.cgColor
        body.strokeColor = UIColor.white.cgColor; body.lineWidth = 3.5; body.lineJoin = .round
        arrow.addSublayer(halo); arrow.addSublayer(body)
        arrow.shadowColor = UIColor.black.cgColor; arrow.shadowOpacity = 0.3; arrow.shadowRadius = 3; arrow.shadowOffset = CGSize(width: 0, height: 1)
        arrow.opacity = 0
        layer.addSublayer(arrow)
        turning.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the right marker for `heading` (degrees from north), turning it over `duration`. Without a heading it is a plain dot.
    func show(heading: Double?, arrow useArrow: Bool, duration: TimeInterval) {
        defer { shown = heading }
        let known = heading != nil
        guard let heading else {
            animate(duration) { turning.opacity = 0; arrow.opacity = 0; dot.opacity = 1 }
            return
        }
        let rotation = CATransform3DMakeRotation(heading * .pi / 180, 0, 0, 1)
        if shown == nil {
            // Appearing after not knowing: turn first, unseen, then fade in.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            turning.transform = rotation; arrow.transform = rotation
            CATransaction.commit()
        }
        animate(duration) {
            turning.transform = rotation; arrow.transform = rotation
            turning.opacity = known && !useArrow ? 1 : 0
            arrow.opacity = known && useArrow ? 1 : 0
            dot.opacity = useArrow ? 0 : 1
        }
    }
    private func animate(_ duration: TimeInterval, _ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        changes()
        CATransaction.commit()
    }
}
private final class MapDestination: MLNPointAnnotation {}
