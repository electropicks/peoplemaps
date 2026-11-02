import Foundation

/// A place the map draws as a coloured marker from `firstZoom` up. Read at runtime from the bundled search index.
public struct PlaceMarker: Sendable, Equatable {
    public let id: String
    public let name: String
    public let raw: String
    public let lat: Double
    public let lon: Double
    public let weight: Int
    /// The zoom this marker first shows at; it stays at every zoom above. Set by `PlaceMarkers.thin`.
    public var firstZoom = 0

    public init(id: String, name: String, raw: String, lat: Double, lon: Double, weight: Int) {
        self.id = id; self.name = name; self.raw = raw; self.lat = lat; self.lon = lon; self.weight = weight
    }

    public var group: PlaceCategory { PlaceCategory(raw: raw) }
    /// The search index's weight, moved so a neighbourhood's first markers are places people go to, not its offices.
    public var rank: Int {
        if isBusStop { return weight - 60 }
        return switch group {
        case .services: weight - 20
        case .health: weight - 12
        case .food, .coffee, .nightlife: weight + 6
        default: weight
        }
    }
    /// Overture files bus stops under `station` with the weight of a Link station, and they have no category of their own to go by.
    public var isBusStop: Bool {
        guard group == .transit else { return false }
        let lower = name.lowercased()
        if raw == "station", lower.contains(" & ") { return true }
        return ["bus stop", "bustop", "metro stop", " - bay "].contains { lower.contains($0) }
    }
}

/// Which places the map shows at which zoom (`Docs/DESIGN.md` 4.1, Map markers). Thinning runs once, over the whole index, so
/// panning does no work: a marker's zoom never depends on where the camera is, and it never disappears when zooming in.
public enum PlaceMarkers {
    /// Each zoom's marker count is bounded by a minimum gap, in points, between marker centres. Wider than a marker, so none touch.
    public static let tiers: [(zoom: Int, spacing: Double)] = [(14, 96), (15, 72), (16, 56), (17, 44)]
    public static var firstZoom: Int { tiers[0].zoom }
    /// Where the first tier is fully drawn, a little before its own zoom: Home's neighbourhood view lands just short of 14.
    /// The spacing there is still about 68 points.
    public static let firstShown = 13.5
    /// The zoom a tier's markers finish fading in at. The first tier's zoom sets its spacing, but it shows from `firstShown`.
    public static func shown(_ zoom: Int) -> Double { zoom == firstZoom ? firstShown : Double(zoom) }

    /// Still found by search, but not worth a marker: nobody heads for a named office block or a parcel locker.
    private static let unmarked: Set<String> = [
        "address", "building", "campus_building", "apartment", "office", "yes", "unknown", "geographic_entities", "parking",
        "bicycle_parking", "atm", "information", "post_box", "parcel_locker", "delivery_locker", "give_box", "public_bookcase",
        "picnic_table", "recycling", "storage", "storage_rental", "self_storage", "luggage_storage", "student_accommodation", "bridge",
    ]
    public static func isMarked(raw: String) -> Bool { !unmarked.contains(raw.lowercased()) }

    /// Web-Mercator position with the world as a unit square. MapLibre's world is 512 × 2^zoom points wide.
    private static func position(lat: Double, lon: Double) -> (x: Double, y: Double) {
        let s = sin(lat * .pi / 180)
        return ((lon + 180) / 360, 0.5 - log((1 + s) / (1 - s)) / (4 * .pi))
    }

    /// The best-ranked place wins its neighbourhood at each zoom, ties broken by ID, so the answer doesn't depend on input order.
    /// Markers kept at a zoom hold their spot at every later zoom. Places still crowded out at the last zoom are dropped.
    /// Bus stops wait for the last tier and rank below everything else, so they only fill gaps.
    public static func thin(_ places: [PlaceMarker], tiers: [(zoom: Int, spacing: Double)] = PlaceMarkers.tiers) -> [PlaceMarker] {
        // Ranks are worked out once: each one is a category lookup, and sorting asks for them about a million times.
        let ranked = places.filter { isMarked(raw: $0.raw) }.map { (rank: $0.rank, lastTier: $0.isBusStop, place: $0) }
            .sorted { ($0.rank, $1.place.id) > ($1.rank, $0.place.id) }
        let ordered = ranked.map(\.place), lastTier = ranked.map(\.lastTier)
        let points = ordered.map { position(lat: $0.lat, lon: $0.lon) }
        var first = [Int32](repeating: -1, count: ordered.count)
        for tier in tiers {
            let world = 512 * pow(2, Double(tier.zoom)), spacing = tier.spacing, gap = spacing * spacing
            var grid: [UInt64: [Int32]] = [:]
            grid.reserveCapacity(ordered.count / 8)
            func key(_ cx: Int64, _ cy: Int64) -> UInt64 { UInt64(truncatingIfNeeded: cx) << 32 | UInt64(truncatingIfNeeded: cy) & 0xFFFF_FFFF }
            func cell(_ i: Int) -> (Int64, Int64) { (Int64(points[i].x * world / spacing), Int64(points[i].y * world / spacing)) }
            for i in ordered.indices where first[i] >= 0 {
                let (cx, cy) = cell(i)
                grid[key(cx, cy), default: []].append(Int32(i))
            }
            // Kept markers are all in the grid first: a new one has to clear them as well as its better-ranked neighbours.
            for i in ordered.indices where first[i] < 0 && (!lastTier[i] || tier.zoom == tiers.last?.zoom) {
                let (cx, cy) = cell(i), x = points[i].x * world, y = points[i].y * world
                var clear = true
                search: for nx in (cx - 1)...(cx + 1) {
                    for ny in (cy - 1)...(cy + 1) {
                        for other in grid[key(nx, ny)] ?? [] {
                            let dx = points[Int(other)].x * world - x, dy = points[Int(other)].y * world - y
                            if dx * dx + dy * dy < gap { clear = false; break search }
                        }
                    }
                }
                if clear { first[i] = Int32(tier.zoom); grid[key(cx, cy), default: []].append(Int32(i)) }
            }
        }
        var kept: [PlaceMarker] = []
        for i in ordered.indices where first[i] >= 0 {
            var marker = ordered[i]; marker.firstZoom = Int(first[i]); kept.append(marker)
        }
        return kept
    }
}
