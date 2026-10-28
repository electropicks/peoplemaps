import SwiftUI
import MapLibre
import PeoplemapsCore

/// What the map shows while guiding: only the route being followed, its destination and the user's puck.
struct Guidance: Equatable {
    let version: Int
    let coordinates: [Coordinate]
    let calmer: Bool
    let destination: Coordinate
    let user: Coordinate?
}

struct SeattleMap: UIViewRepresentable {
    let comparison: RouteComparison?
    let selectedCalmer: Bool
    let recenter: Int
    /// Small gray pins for places the user can open.
    var pins: [Place] = []
    /// The selected place: the only green pin, centred in the visible map.
    var selected: Place?
    var onPin: (String) -> Void = { _ in }
    var guidance: Guidance?
    /// Space covered by the panel and map buttons, kept clear when fitting routes.
    let padding: UIEdgeInsets
    @Environment(\.colorScheme) private var colorScheme
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
        private var focusKey = ""
        private var guiding = false
        private var guidanceKey = ""
        private var lastUser: Coordinate?
        private var guidanceAnnotations: [MLNPointAnnotation] = []
        private var puck: MapPuck?

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
                for id in ["fastest-casing", "fastest"] { (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = shape(c?.fastest) }
                for id in ["calmer-casing", "calmer"] { (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = shape(c?.calmer) }
                for id in ["fastest", "fastest-casing"] {
                    (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineOpacity = NSExpression(forConstantValue: latest.selectedCalmer && c?.calmer != nil ? 0.55 : 1.0)
                }
                for id in ["calmer", "calmer-casing"] {
                    (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineOpacity = NSExpression(forConstantValue: latest.selectedCalmer ? 1.0 : 0.4)
                }
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
                pinAnnotations = latest.pins.filter { $0.id != latest.selected?.id }.map { MapPin(place: $0, selected: false) }
                if let place = latest.selected { pinAnnotations.append(MapPin(place: place, selected: true)) }
                map.addAnnotations(pinAnnotations)
                pinKey = pk
            }
            let focus = c != nil ? "route" : latest.selected?.id ?? "home"
            let focusChanged = focus != focusKey
            let paddingChanged = (abs(fittedPadding.bottom - latest.padding.bottom) > 1 || abs(fittedPadding.left - latest.padding.left) > 1)
            let recentered = recenterID >= 0 && recenterID != latest.recenter
            if focusChanged || paddingChanged || recentered || (changed && c != nil) {
                var points = (c?.fastest.coordinates ?? []) + (c?.calmer?.coordinates ?? [])
                if points.isEmpty, let place = latest.selected {
                    // A neighbourhood-sized window around the place, so it lands in the middle of the visible map.
                    points = [Coordinate(lat: place.lat - 0.004, lon: place.lon - 0.006), Coordinate(lat: place.lat + 0.004, lon: place.lon + 0.006)]
                }
                if points.isEmpty { points = latest.pins.map(\.coordinate) }
                if !points.isEmpty {
                    let sw = CLLocationCoordinate2D(latitude: points.map(\.lat).min()!, longitude: points.map(\.lon).min()!)
                    let ne = CLLocationCoordinate2D(latitude: points.map(\.lat).max()!, longitude: points.map(\.lon).max()!)
                    map.setVisibleCoordinateBounds(MLNCoordinateBounds(sw: sw, ne: ne), edgePadding: fitting(latest.padding, in: map.bounds.size), animated: false, completionHandler: nil)
                    fittedPadding = latest.padding
                }
            }
            focusKey = focus
            routeKey = key; recenterID = latest.recenter
        }

        private func clearRoutes(_ style: MLNStyle) {
            for id in ["fastest-casing", "fastest", "calmer-casing", "calmer"] {
                (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = nil
                (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineOpacity = NSExpression(forConstantValue: 1.0)
            }
        }

        /// Guidance draws the followed route, the destination and the puck, and keeps the map centred on the puck, north-up.
        private func updateGuidance(_ g: Guidance, map: MLNMapView, style: MLNStyle) {
            if !guiding {
                guiding = true
                map.removeAnnotations(endpoints + pinAnnotations)
                endpoints = []; pinAnnotations = []; pinKey = ""; guidanceKey = ""; lastUser = nil
                clearRoutes(style)
                map.setCenter(CLLocationCoordinate2D(latitude: (g.user ?? g.coordinates[0]).lat, longitude: (g.user ?? g.coordinates[0]).lon), zoomLevel: 16, animated: false)
            }
            let key = "\(g.version)|\(g.calmer)"
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
            if let user = g.user, user != lastUser {
                let point = CLLocationCoordinate2D(latitude: user.lat, longitude: user.lon)
                if let puck { puck.coordinate = point } else {
                    let new = MapPuck(); new.coordinate = point; puck = new; map.addAnnotation(new)
                }
                map.setCenter(point, animated: false)
                lastUser = user
            }
        }

        private func endGuidance(map: MLNMapView, style: MLNStyle) {
            guiding = false
            map.removeAnnotations(guidanceAnnotations + (puck.map { [$0] } ?? []))
            guidanceAnnotations = []; puck = nil; lastUser = nil; guidanceKey = ""
            clearRoutes(style)
            routeKey = ""; focusKey = ""; pinKey = ""
        }

        private func pinKey(_ s: SeattleMap) -> String { s.pins.map(\.id).joined(separator: ",") + "|" + (s.selected?.id ?? "") }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            mapView.deselectAnnotation(annotation, animated: false)
            if let pin = annotation as? MapPin { latest?.onPin(pin.placeID) }
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
            let extras: [MLNPointAnnotation] = guidanceAnnotations + (puck.map { [$0] } ?? [])
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
            case is MapPuck:
                view = MLNAnnotationView(reuseIdentifier: nil)
                view.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
                view.backgroundColor = UIColor.systemBlue.resolvedColor(with: traits)
                view.layer.borderColor = UIColor.white.cgColor
                view.layer.borderWidth = 3.5
                view.layer.cornerRadius = 11
                view.layer.shadowColor = UIColor.black.cgColor
                view.layer.shadowOpacity = 0.3; view.layer.shadowRadius = 3; view.layer.shadowOffset = CGSize(width: 0, height: 1)
            case is MapDestination:
                view = MLNAnnotationView(reuseIdentifier: nil)
                view.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
                view.backgroundColor = UIColor.calmer.resolvedColor(with: traits)
                view.layer.borderColor = background.cgColor
                view.layer.borderWidth = 3
                view.layer.cornerRadius = 11
            case let pin as MapPin:
                view = MLNAnnotationView(reuseIdentifier: nil)
                let size: CGFloat = pin.isSelected ? 22 : 14
                view.frame = CGRect(x: 0, y: 0, width: size, height: size)
                view.backgroundColor = pin.isSelected ? UIColor.calmer.resolvedColor(with: traits) : UIColor.systemGray.resolvedColor(with: traits)
                view.layer.borderColor = background.cgColor
                view.layer.borderWidth = pin.isSelected ? 3 : 2.5
                view.layer.cornerRadius = size / 2
                view.isAccessibilityElement = true
                view.accessibilityLabel = pin.title
                view.accessibilityTraits = .button
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
            view.isAccessibilityElement = false
            return view
        }
    }
}
private final class MapLabel: MLNPointAnnotation {}
private final class MapPin: MLNPointAnnotation {
    let placeID: String
    let isSelected: Bool
    init(place: Place, selected: Bool) {
        placeID = place.id; isSelected = selected
        super.init()
        title = place.shortName
        coordinate = CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
private final class MapOrigin: MLNPointAnnotation {}
private final class MapPuck: MLNPointAnnotation {}
private final class MapDestination: MLNPointAnnotation {}
