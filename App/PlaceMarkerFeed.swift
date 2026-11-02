import UIKit
import MapLibre
import PeoplemapsCore

/// The map's place markers, handed to MapLibre one tile at a time on its own background queue, so panning does no work on the main
/// thread and memory holds only this array and the tiles in view. A GeoJSON source of the same points cost 144 MB (`Docs/DESIGN.md` 4.1).
final class PlaceMarkerFeed: NSObject, MLNComputedShapeSourceDataSource, Sendable {
    struct Art: Hashable, Sendable {
        let group: PlaceCategory
        let symbol: String
        var name: String { "marker-\(group.rawValue)-\(symbol)" }
    }
    /// West to east, to find a tile's markers by binary search.
    private let markers: [PlaceMarker]
    private let names: [String]
    let art: [Art]
    /// Time spent reading the index and thinning, off the main thread.
    let milliseconds: Double
    var count: Int { markers.count }

    private init(markers: [PlaceMarker], milliseconds: Double) {
        self.markers = markers.sorted { $0.lon < $1.lon }
        let art = self.markers.map { Art(group: $0.group, symbol: $0.group.symbol(for: $0.raw)) }
        names = art.map(\.name)
        self.art = Array(Set(art))
        self.milliseconds = milliseconds
    }

    static func load(_ search: SearchIndex) async -> PlaceMarkerFeed {
        await Task.detached(priority: .utility) {
            let began = DispatchTime.now().uptimeNanoseconds
            let markers = PlaceMarkers.thin(search.markerCandidates())
            let feed = PlaceMarkerFeed(markers: markers, milliseconds: Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6)
            AppEvents.shared.log(.data, "place markers ready", ["ms": feed.milliseconds, "markers": Double(markers.count)])
            return feed
        }.value
    }

    /// A tile's markers. On-screen zoom can pass the tile's by one before the next tiles load, so one tier ahead comes along.
    /// Each tile returns only points inside it: a symbol isn't clipped at its tile's edge, so nothing needs repeating in a buffer.
    func features(in bounds: MLNCoordinateBounds, zoomLevel: UInt) -> [any MLNShape & MLNFeature] {
        var low = 0, high = markers.count
        while low < high {
            let middle = (low + high) / 2
            if markers[middle].lon < bounds.sw.longitude { low = middle + 1 } else { high = middle }
        }
        var found: [any MLNShape & MLNFeature] = []
        var index = low
        while index < markers.count, markers[index].lon < bounds.ne.longitude {
            let marker = markers[index]
            if marker.firstZoom <= Int(zoomLevel) + 1, marker.lat >= bounds.sw.latitude, marker.lat < bounds.ne.latitude {
                let feature = MLNPointFeature()
                feature.coordinate = CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lon)
                feature.attributes = ["pid": marker.id, "name": marker.name, "kind": Place.categoryLabel(marker.raw), "img": names[index], "z": marker.firstZoom]
                found.append(feature)
            }
            index += 1
        }
        return found
    }
}

/// A marker on screen once the map is idle: the accessible stand-in for a MapLibre symbol, which VoiceOver can't see.
struct VisiblePlace: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
    let point: CGPoint
}

enum MarkerArt {
    /// A category fill and glyph from the app's tokens, on a thin ring of the map's background so it stands off roads and water.
    /// Increase Contrast thickens the ring. Colour is never the only cue: the glyph says the category too.
    static func image(_ art: PlaceMarkerFeed.Art, traits: UITraitCollection, contrast: Bool) -> UIImage {
        let diameter: CGFloat = 26, ring: CGFloat = contrast ? 2.5 : 1.5
        let fill = UIColor.categoryFill(art.group).resolvedColor(with: traits)
        let glyph = UIColor.categoryGlyph.resolvedColor(with: traits)
        let edge = UIColor.systemBackground.resolvedColor(with: traits)
        let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let symbol = UIImage(systemName: art.symbol, withConfiguration: config)?.withTintColor(glyph, renderingMode: .alwaysOriginal)
        let format = UIGraphicsImageRendererFormat(for: traits)
        format.scale = max(traits.displayScale, 3)
        return UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter), format: format).image { context in
            let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            edge.setFill(); context.cgContext.fillEllipse(in: bounds)
            fill.setFill(); context.cgContext.fillEllipse(in: bounds.insetBy(dx: ring, dy: ring))
            if let symbol {
                symbol.draw(at: CGPoint(x: (diameter - symbol.size.width) / 2, y: (diameter - symbol.size.height) / 2))
            }
        }
    }
}
