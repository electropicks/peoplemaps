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
    /// Smoothed course in degrees from north, kept while stopped; nil until known.
    var heading: Double?
    /// The puck shows its heading wedge only while moving.
    var moving = false
    var camera = GuidanceCamera()
    /// Space the guidance chrome covers; the puck is centred in the rest.
    var inset = UIEdgeInsets.zero
}

struct SeattleMap: UIViewRepresentable {
    let comparison: RouteComparison?
    let selectedCalmer: Bool
    let recenter: Int
    /// The selected place: the only green pin, centred in the visible map.
    var selected: Place?
    /// Where the device is, when known and inside coverage: a blue dot, and what Home frames at neighbourhood zoom.
    var user: Coordinate?
    /// South-west and north-east corners of the area we cover, framed by Home when the user's location is unknown.
    var coverage: [Coordinate] = []
    /// A long-press on the map, at that spot.
    var onLongPress: (Coordinate) -> Void = { _ in }
    var guidance: Guidance?
    /// The user panned or pinched while guiding, so following should stop.
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
        context.coordinator.update(map)
    }

    // MapLibre delivers its view delegate callbacks on the UI thread; its ObjC protocol predates Swift concurrency.
    @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        var latest: SeattleMap?
        private var routeKey = ""
        private var recenterID = -1
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
        private var lastHeading: Double?
        private var guidanceAnnotations: [MLNPointAnnotation] = []
        private var puck: MapPuck?
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

        private static let baseLayers: [(id: String, color: UIColor)] = [
            ("water", .mapWater), ("parks", .mapPark), ("roads", .mapStreet), ("arterials", .mapArterial), ("paths", .mapPath),
        ]

        func mapView(_ map: MLNMapView, didFinishLoading style: MLNStyle) {
            guard let url = StreetGraph.mapURL else { return }
            let source = MLNShapeSource(identifier: "seattle", url: url, options: [.simplificationTolerance: 0.3])
            style.addSource(source)
            for (id, kind) in [("water", "water"), ("parks", "park")] {
                let layer = MLNFillStyleLayer(identifier: id, source: source)
                layer.predicate = NSPredicate(format: "kind == %@", kind)
                style.addLayer(layer)
            }
            for (id, kind, width) in [("roads", "road", 2.0), ("arterials", "arterial", 2.7), ("paths", "path", 0.8)] {
                let layer = MLNLineStyleLayer(identifier: id, source: source)
                layer.predicate = NSPredicate(format: "kind == %@", kind)
                layer.lineWidth = NSExpression(forConstantValue: width)
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
                if let userDot { map.addAnnotation(userDot) }
            }
            // Home refits once when the user's location first becomes known, never on later fixes.
            let focus = c != nil ? "route" : latest.selected?.id ?? (latest.user != nil ? "home-user" : "home")
            let focusChanged = focus != focusKey
            let paddingChanged = (abs(fittedPadding.bottom - latest.padding.bottom) > 1 || abs(fittedPadding.left - latest.padding.left) > 1)
            let recentered = recenterID >= 0 && recenterID != latest.recenter
            if focusChanged || paddingChanged || recentered || (changed && c != nil) {
                var points = (c?.fastest.coordinates ?? []) + (c?.calmer?.coordinates ?? [])
                if points.isEmpty, let place = latest.selected {
                    // A neighbourhood-sized window around the place, so it lands in the middle of the visible map.
                    points = [Coordinate(lat: place.lat - 0.004, lon: place.lon - 0.006), Coordinate(lat: place.lat + 0.004, lon: place.lon + 0.006)]
                }
                if points.isEmpty, let user = latest.user {
                    points = [Coordinate(lat: user.lat - 0.004, lon: user.lon - 0.006), Coordinate(lat: user.lat + 0.004, lon: user.lon + 0.006)]
                }
                if points.isEmpty { points = latest.coverage }
                if !points.isEmpty {
                    let sw = CLLocationCoordinate2D(latitude: points.map(\.lat).min()!, longitude: points.map(\.lon).min()!)
                    let ne = CLLocationCoordinate2D(latitude: points.map(\.lat).max()!, longitude: points.map(\.lon).max()!)
                    let pad = fitting(latest.padding, in: map.bounds.size)
                    let camera = map.cameraThatFitsCoordinateBounds(MLNCoordinateBounds(sw: sw, ne: ne), edgePadding: pad)
                    move(map, to: camera, duration: hasFitted ? Motion.camera(latest.reduceMotion) : 0, padding: pad)
                    fittedPadding = latest.padding; hasFitted = true
                }
            }
            focusKey = focus
            routeKey = key; recenterID = latest.recenter
        }

        private func setRouteOpacity(_ style: MLNStyle, _ value: (String) -> Double) {
            guard latest?.guidance == nil else { return }
            for id in ["fastest", "calmer"] {
                for layer in [id, id + "-casing"] { (style.layer(withIdentifier: layer) as? MLNLineStyleLayer)?.lineOpacity = NSExpression(forConstantValue: value(id)) }
            }
        }

        /// A fitted camera is centred on its bounds, so it needs the same padding it was fitted with; following uses the content inset.
        private func move(_ map: MLNMapView, to camera: MLNMapCamera, duration: TimeInterval, timing: CAMediaTimingFunctionName = .easeInEaseOut, padding: UIEdgeInsets? = nil) {
            map.setCamera(camera, withDuration: duration, animationTimingFunction: CAMediaTimingFunction(name: timing),
                          edgePadding: padding ?? .zero, completionHandler: nil)
        }

        private func clearRoutes(_ style: MLNStyle) {
            for id in ["fastest-casing", "fastest", "calmer-casing", "calmer"] {
                (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = nil
                (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineOpacity = NSExpression(forConstantValue: 1.0)
            }
        }

        /// Guidance draws the followed route, the destination and the puck, and moves the camera as the mode says:
        /// following keeps the puck centred (heading-up puts it in the lower third), the overview fits the route, free leaves the map alone.
        private func updateGuidance(_ g: Guidance, map: MLNMapView, style: MLNStyle) {
            if !guiding {
                guiding = true
                map.removeAnnotations(endpoints + pinAnnotations + (userDot.map { [$0] } ?? []))
                endpoints = []; pinAnnotations = []; pinKey = ""; userDot = nil; guidanceKey = ""; lastUser = nil; lastHeading = nil; cameraMode = nil
                clearRoutes(style)
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
                    map.contentInset = .zero
                    let lats = g.coordinates.map(\.lat), lons = g.coordinates.map(\.lon)
                    let sw = CLLocationCoordinate2D(latitude: lats.min()!, longitude: lons.min()!)
                    let ne = CLLocationCoordinate2D(latitude: lats.max()!, longitude: lons.max()!)
                    let pad = UIEdgeInsets(top: g.inset.top + 24, left: g.inset.left + 32, bottom: g.inset.bottom + 24, right: max(g.inset.right, 16) + 32)
                    let fitted = fitting(pad, in: map.bounds.size)
                    let northUp = map.camera; northUp.heading = 0
                    let camera = map.camera(northUp, fitting: MLNCoordinateBounds(sw: sw, ne: ne), edgePadding: fitted)
                    move(map, to: camera, duration: Motion.camera(latest?.reduceMotion ?? false), padding: fitted)
                case .followCourseUp, .followNorthUp:
                    // Coming back from the overview or a free look zooms back in; flipping heading-up and north-up eases the
                    // turn over `Motion.camera`; a reroute keeps the current zoom.
                    if cameraMode != .followCourseUp && cameraMode != .followNorthUp { followZoom = true }
                    else if cameraMode != g.camera.mode { zoomUntil = Date().addingTimeInterval(Motion.camera(latest?.reduceMotion ?? false)) }
                    map.contentInset = followInset(g, in: map.bounds.size)
                case .free:
                    break
                }
                cameraMode = g.camera.mode
            }
            if key != guidanceKey {
                clearRoutes(style)
                let prefix = g.calmer ? "calmer" : "fastest"
                var coords = g.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let line = coords.count > 1 ? MLNPolyline(coordinates: &coords, count: UInt(coords.count)) : nil
                for id in [prefix, prefix + "-casing"] { (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = line }
                map.removeAnnotations(guidanceAnnotations)
                let end = MapDestination()
                end.coordinate = CLLocationCoordinate2D(latitude: g.destination.lat, longitude: g.destination.lon)
                guidanceAnnotations = [end]
                map.addAnnotations(guidanceAnnotations)
                guidanceKey = key
            }
            let heading = g.moving ? g.heading : nil
            if let user = g.user, user != lastUser || heading != lastHeading {
                let reduce = latest?.reduceMotion ?? false
                let tick = Motion.camera(reduce, min(1, max(0.1, Date().timeIntervalSince(lastFollow))))
                lastFollow = Date()
                placePuck(user, heading: heading, map: map, duration: tick)
                if g.camera.isFollowing { aim(at: user, map: map, courseUp: g.camera.courseUp, heading: g.heading, tick: tick) }
                lastUser = user; lastHeading = heading
            }
        }

        /// Heading-up puts the puck a third of the way up the free map area, so most of the screen shows the road ahead.
        private func followInset(_ g: Guidance, in size: CGSize) -> UIEdgeInsets {
            var inset = g.inset
            if g.camera.mode == .followCourseUp { inset.top += max(0, size.height - g.inset.top - g.inset.bottom) / 3 }
            return inset
        }

        /// Glides the puck between position updates and turns its heading wedge, so following looks continuous.
        private func placePuck(_ user: Coordinate, heading: Double?, map: MLNMapView, duration: TimeInterval) {
            let point = CLLocationCoordinate2D(latitude: user.lat, longitude: user.lon)
            if let puck {
                if duration > 0 { UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear, .beginFromCurrentState]) { puck.coordinate = point } }
                else { puck.coordinate = point }
            } else {
                let new = MapPuck(); new.coordinate = point; puck = new; map.addAnnotation(new)
            }
            puckHeading = heading
            (puck.flatMap { map.view(for: $0) } as? PuckView)?.show(heading: heading, duration: duration)
        }

        /// Moves the camera onto the user. Zooming in (start, leaving the overview or a free look) is a longer eased move;
        /// in between, positions and heading changes glide linearly over the time since the last fix.
        private func aim(at user: Coordinate, map: MLNMapView, courseUp: Bool, heading: Double?, tick: TimeInterval = 0) {
            let point = CLLocationCoordinate2D(latitude: user.lat, longitude: user.lon)
            let reduce = latest?.reduceMotion ?? false
            let camera = map.camera
            camera.centerCoordinate = point
            camera.heading = courseUp ? (heading ?? camera.heading) : 0
            let zooming = Date() < zoomUntil
            if followZoom || zooming {
                camera.altitude = MLNAltitudeForZoomLevel(16, 0, point.latitude, map.bounds.size)
                if followZoom { zoomUntil = Date().addingTimeInterval(Motion.camera(reduce, 0.8)); followZoom = false }
                move(map, to: camera, duration: max(0, zoomUntil.timeIntervalSinceNow))
            } else {
                move(map, to: camera, duration: tick, timing: .linear)
            }
        }

        private func endGuidance(map: MLNMapView, style: MLNStyle) {
            guiding = false
            map.removeAnnotations(guidanceAnnotations + (puck.map { [$0] } ?? []))
            guidanceAnnotations = []; puck = nil; lastUser = nil; lastHeading = nil; puckHeading = nil; cameraMode = nil
            guidanceKey = ""; guidanceMode = ""; lastFollow = .distantPast; zoomUntil = .distantPast
            map.contentInset = .zero
            if map.camera.heading != 0 { let camera = map.camera; camera.heading = 0; move(map, to: camera, duration: Motion.camera(latest?.reduceMotion ?? false)) }
            clearRoutes(style)
            routeKey = ""; focusKey = ""; pinKey = ""
        }

        /// A pan, pinch or zoom gesture while following or in the overview hands the camera to the user.
        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            guard guiding, let g = latest?.guidance, g.camera.mode != .free else { return }
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
                if dot === puck { puckView.show(heading: puckHeading, duration: 0) }
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
            guard Motion.camera(latest?.reduceMotion ?? false) > 0 else { return }
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

/// The user's blue dot with a heading wedge behind it. The view turns with the map, so the wedge's own rotation is the
/// course from north and heading-up leaves it pointing at the top of the screen.
private final class PuckView: MLNAnnotationView {
    private let wedge = CAGradientLayer()
    private var shown: Double?
    init(traits: UITraitCollection) {
        super.init(reuseIdentifier: nil)
        frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        rotatesToMatchCamera = true
        let blue = UIColor.systemBlue.resolvedColor(with: traits)
        let centre = CGPoint(x: 36, y: 36)
        let path = UIBezierPath()
        path.move(to: centre)
        path.addArc(withCenter: centre, radius: 36, startAngle: -.pi / 2 - .pi / 5.5, endAngle: -.pi / 2 + .pi / 5.5, clockwise: true)
        path.close()
        let mask = CAShapeLayer(); mask.path = path.cgPath
        wedge.frame = bounds; wedge.mask = mask
        wedge.type = .radial
        wedge.startPoint = CGPoint(x: 0.5, y: 0.5); wedge.endPoint = CGPoint(x: 1, y: 1)
        wedge.colors = [blue.withAlphaComponent(0.55).cgColor, blue.withAlphaComponent(0.0).cgColor]
        wedge.opacity = 0
        layer.addSublayer(wedge)
        let dot = CALayer()
        dot.frame = CGRect(x: 25, y: 25, width: 22, height: 22)
        dot.backgroundColor = blue.cgColor
        dot.borderColor = UIColor.white.cgColor; dot.borderWidth = 3.5; dot.cornerRadius = 11
        dot.shadowColor = UIColor.black.cgColor; dot.shadowOpacity = 0.3; dot.shadowRadius = 3; dot.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(dot)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Turns the wedge to `heading` (degrees from north) over `duration`, or fades it out when the heading is unknown.
    func show(heading: Double?, duration: TimeInterval) {
        defer { shown = heading }
        guard let heading else { animate(duration) { wedge.opacity = 0 }; return }
        let rotation = CATransform3DMakeRotation(heading * .pi / 180, 0, 0, 1)
        if shown == nil {
            // Appearing after a stop: turn first, unseen, then fade in.
            CATransaction.begin(); CATransaction.setDisableActions(true); wedge.transform = rotation; CATransaction.commit()
        }
        animate(duration) { wedge.transform = rotation; wedge.opacity = 1 }
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
