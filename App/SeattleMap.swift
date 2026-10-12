import SwiftUI
import MapLibre
import PeoplemapsCore

struct SeattleMap: UIViewRepresentable {
    let comparison: RouteComparison?
    let selectedCalmer: Bool
    let recenter: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: Bundle.main.url(forResource: "offline-style", withExtension: "json"))
        map.delegate = context.coordinator
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true // Linked OSM attribution is always visible in SwiftUI map chrome.
        map.compassView.isHidden = true
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
        private var styleReady = false
        private var endpoints: [MLNPointAnnotation] = []

        func mapView(_ map: MLNMapView, didFinishLoading style: MLNStyle) {
            guard let url = StreetGraph.mapURL else { return }
            let source = MLNShapeSource(identifier: "seattle", url: url, options: [.simplificationTolerance: 0.3])
            style.addSource(source)
            for (id, kind, color) in [("water", "water", UIColor(red: 0.67, green: 0.81, blue: 0.82, alpha: 1)), ("parks", "park", UIColor(red: 0.79, green: 0.85, blue: 0.70, alpha: 1))] {
                let layer = MLNFillStyleLayer(identifier: id, source: source)
                layer.predicate = NSPredicate(format: "kind == %@", kind)
                layer.fillColor = NSExpression(forConstantValue: color)
                style.addLayer(layer)
            }
            for (id, kind, color, width) in [("roads", "road", UIColor.white, 2.0), ("arterials", "arterial", UIColor(red: 0.84, green: 0.78, blue: 0.64, alpha: 1), 2.7), ("paths", "path", UIColor(red: 0.63, green: 0.71, blue: 0.56, alpha: 1), 0.8)] {
                let layer = MLNLineStyleLayer(identifier: id, source: source)
                layer.predicate = NSPredicate(format: "kind == %@", kind)
                layer.lineColor = NSExpression(forConstantValue: color)
                layer.lineWidth = NSExpression(forConstantValue: width)
                layer.lineOpacity = NSExpression(forConstantValue: kind == "path" ? 0.6 : 1)
                style.addLayer(layer)
            }
            for (id, color, width) in [("fastest-halo", UIColor.white, 8.0), ("fastest", UIColor(red: 0.46, green: 0.50, blue: 0.53, alpha: 1), 4.5), ("calmer-halo", UIColor.white, 9.0), ("calmer", UIColor(red: 0.16, green: 0.37, blue: 0.29, alpha: 1), 5.5)] {
                let source = MLNShapeSource(identifier: id, shape: nil, options: nil)
                style.addSource(source)
                let layer = MLNLineStyleLayer(identifier: id, source: source)
                layer.lineColor = NSExpression(forConstantValue: color)
                layer.lineWidth = NSExpression(forConstantValue: width)
                layer.lineJoin = NSExpression(forConstantValue: "round")
                layer.lineCap = NSExpression(forConstantValue: "round")
                style.addLayer(layer)
            }
            let labels: [(String, Double, Double)] = [("BALLARD",47.668,-122.382),("FREMONT",47.652,-122.351),("WALLINGFORD",47.663,-122.335),("QUEEN ANNE",47.637,-122.360),("LAKE UNION",47.639,-122.335),("UNIVERSITY\nDISTRICT",47.665,-122.313)]
            for (title, lat, lon) in labels {
                let annotation = MapLabel(); annotation.title = title
                annotation.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                map.addAnnotation(annotation)
            }
            styleReady = true; routeKey = ""; update(map)
        }
        func update(_ map: MLNMapView) {
            guard styleReady, let latest, let style = map.style else { return }
            let c = latest.comparison
            let key = "\(c?.fastest.id ?? "none")|\(c?.calmer?.id ?? "none")|\(latest.selectedCalmer)"
            let changed = key != routeKey
            if changed {
                for id in ["fastest-halo", "fastest"] { (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = shape(c?.fastest) }
                for id in ["calmer-halo", "calmer"] { (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = shape(c?.calmer) }
                for id in ["fastest", "fastest-halo"] {
                    (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineOpacity = NSExpression(forConstantValue: latest.selectedCalmer && c?.calmer != nil ? 0.55 : 1.0)
                }
                for id in ["calmer", "calmer-halo"] {
                    (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineOpacity = NSExpression(forConstantValue: latest.selectedCalmer ? 1.0 : 0.4)
                }
                map.removeAnnotations(endpoints); endpoints = []
                if let c {
                    for (title, point) in [("A",c.snappedOrigin),("B",c.snappedDestination)] {
                        let annotation = MapEndpoint(); annotation.title = title
                        annotation.coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
                        endpoints.append(annotation)
                    }
                    map.addAnnotations(endpoints)
                }
            }
            if (changed && c != nil) || recenterID != latest.recenter {
                let points = (c?.fastest.coordinates ?? []) + (c?.calmer?.coordinates ?? [])
                if !points.isEmpty {
                    let sw = CLLocationCoordinate2D(latitude: points.map(\.lat).min()!, longitude: points.map(\.lon).min()!)
                    let ne = CLLocationCoordinate2D(latitude: points.map(\.lat).max()!, longitude: points.map(\.lon).max()!)
                    map.setVisibleCoordinateBounds(MLNCoordinateBounds(sw: sw, ne: ne), edgePadding: UIEdgeInsets(top: 65, left: 38, bottom: 72, right: 38), animated: false, completionHandler: nil)
                }
            }
            routeKey = key; recenterID = latest.recenter
        }
        private func shape(_ route: Route?) -> MLNPolyline? {
            guard let route, route.coordinates.count > 1 else { return nil }
            var coordinates = route.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            return MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
        }
        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard annotation is MapLabel || annotation is MapEndpoint else { return nil }
            let endpoint = annotation is MapEndpoint
            let view = MLNAnnotationView(reuseIdentifier: endpoint ? "endpoint" : "label")
            let label = UILabel(); label.text = annotation.title ?? ""; label.textAlignment = .center; label.numberOfLines = 2
            label.font = endpoint ? .systemFont(ofSize: 13, weight: .bold) : .systemFont(ofSize: 9, weight: .semibold)
            label.textColor = endpoint ? .white : UIColor(red: 0.31, green: 0.39, blue: 0.35, alpha: 0.85)
            label.backgroundColor = endpoint ? UIColor(red: 0.14, green: 0.31, blue: 0.25, alpha: 1) : .clear
            label.frame = CGRect(x: 0, y: 0, width: endpoint ? 28 : 95, height: endpoint ? 28 : 32)
            if endpoint { label.layer.cornerRadius = 14; label.clipsToBounds = true; label.layer.borderWidth = 2; label.layer.borderColor = UIColor.white.cgColor }
            view.frame = label.bounds; view.addSubview(label); view.isAccessibilityElement = false
            return view
        }
    }
}
private final class MapLabel: MLNPointAnnotation {}
private final class MapEndpoint: MLNPointAnnotation {}
