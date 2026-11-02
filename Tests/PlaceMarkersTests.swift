import XCTest
@testable import PeoplemapsCore

final class PlaceMarkersTests: XCTestCase {
    private func place(_ id: String, _ lat: Double, _ lon: Double, raw: String = "restaurant", weight: Int = 50) -> PlaceMarker {
        PlaceMarker(id: id, name: id, raw: raw, lat: lat, lon: lon, weight: weight)
    }
    /// Places on a fine grid over a small part of Fremont, far denser than any tier allows.
    private var crowd: [PlaceMarker] {
        (0..<60).flatMap { row in (0..<60).map { col in
            place("p\(row)-\(col)", 47.650 + Double(row) * 0.0001, -122.350 + Double(col) * 0.00015, weight: 30 + (row * 7 + col * 13) % 60)
        } }
    }
    /// Distance in points between two places at `zoom`, in the projection the map draws.
    private func gap(_ a: PlaceMarker, _ b: PlaceMarker, zoom: Int) -> Double {
        func point(_ m: PlaceMarker) -> (Double, Double) {
            let s = sin(m.lat * .pi / 180)
            return ((m.lon + 180) / 360, 0.5 - log((1 + s) / (1 - s)) / (4 * .pi))
        }
        let world = 512 * pow(2, Double(zoom)), (ax, ay) = point(a), (bx, by) = point(b)
        return hypot((ax - bx) * world, (ay - by) * world)
    }

    func testNoTwoMarkersCloserThanTheTierSpacing() {
        let kept = PlaceMarkers.thin(crowd)
        for tier in PlaceMarkers.tiers {
            let shown = kept.filter { $0.firstZoom <= tier.zoom }
            for (i, a) in shown.enumerated() {
                for b in shown[(i + 1)...] { XCTAssertGreaterThanOrEqual(gap(a, b, zoom: tier.zoom), tier.spacing, "\(a.id) \(b.id) at z\(tier.zoom)") }
            }
        }
    }

    func testMoreMarkersAsYouZoomIn() {
        let kept = PlaceMarkers.thin(crowd)
        let counts = PlaceMarkers.tiers.map { tier in kept.filter { $0.firstZoom <= tier.zoom }.count }
        XCTAssertGreaterThan(counts[0], 0)
        for (a, b) in zip(counts, counts.dropFirst()) { XCTAssertLessThan(a, b) }
    }

    /// The answer can't depend on where it is computed from: same set, same result, whatever the order.
    func testOrderDoesNotMatter() {
        let a = PlaceMarkers.thin(crowd), b = PlaceMarkers.thin(crowd.reversed()), c = PlaceMarkers.thin(crowd.shuffled())
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
    }

    func testBestRankedWinsAndTiesGoByID() {
        let high = place("high", 47.65, -122.35, weight: 90), low = place("low", 47.65, -122.35, weight: 40)
        XCTAssertEqual(PlaceMarkers.thin([low, high]).map(\.id), ["high"])
        XCTAssertEqual(PlaceMarkers.thin([place("b", 47.65, -122.35), place("a", 47.65, -122.35)]).map(\.id), ["a"])
    }

    /// Two places a street apart: only one at the widest zoom, both once there's room, and the winner stays put.
    func testMarkersNeverDisappearWhenZoomingIn() {
        let kept = PlaceMarkers.thin([place("high", 47.65, -122.35, weight: 90), place("low", 47.65, -122.3483, weight: 40)])
        XCTAssertEqual(kept.first { $0.id == "high" }?.firstZoom, PlaceMarkers.firstZoom)
        let low = kept.first { $0.id == "low" }
        XCTAssertNotNil(low)
        XCTAssertGreaterThan(low?.firstZoom ?? 0, PlaceMarkers.firstZoom)
    }

    func testAnOfficeGivesWayToARestaurantOfEqualWeight() {
        let kept = PlaceMarkers.thin([place("clinic", 47.65, -122.35, raw: "dentist"), place("bank", 47.65, -122.35, raw: "bank"), place("food", 47.65, -122.35)])
        XCTAssertEqual(kept.map(\.id), ["food"])
    }

    func testThingsNobodyHeadsForGetNoMarker() {
        for raw in ["building", "Apartment", "office", "parking", "atm", "parcel_locker"] {
            XCTAssertTrue(PlaceMarkers.thin([place("x", 47.65, -122.35, raw: raw)]).isEmpty, raw)
        }
        XCTAssertEqual(PlaceMarkers.thin([place("x", 47.65, -122.35, raw: "park")]).count, 1)
    }

    func testTheFirstTierShowsBeforeItsZoomAndTheRestAtTheirs() {
        XCTAssertEqual(PlaceMarkers.shown(PlaceMarkers.firstZoom), PlaceMarkers.firstShown)
        XCTAssertLessThan(PlaceMarkers.firstShown, Double(PlaceMarkers.firstZoom))
        XCTAssertEqual(PlaceMarkers.shown(16), 16)
    }

    /// The real thing, when `Scripts/fetch_data seattle-all` has run: how many markers each zoom has, and on its busiest screen.
    func testAllSeattleStaysReadable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Data/region/seattle-all/expected/seattle-search.sqlite.gz")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "seattle-all not fetched")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = try SearchIndex(gzipped: try Data(contentsOf: file), graphNodeCount: nil, directory: folder)
        let clock = ContinuousClock()
        var candidates: [PlaceMarker] = [], kept: [PlaceMarker] = []
        let read = clock.measure { candidates = index.markerCandidates() }
        let thinned = clock.measure { kept = PlaceMarkers.thin(candidates) }
        print("markers: \(candidates.count) places, read \(read), thinned \(thinned), kept \(kept.count)")
        for tier in PlaceMarkers.tiers {
            let shown = kept.filter { $0.firstZoom <= tier.zoom }, world = 512 * pow(2, Double(tier.zoom))
            var screens: [String: Int] = [:]
            for marker in shown {
                let s = sin(marker.lat * .pi / 180)
                let x = (marker.lon + 180) / 360 * world, y = (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * world
                screens["\(Int(x / 402))/\(Int(y / 874))", default: 0] += 1
            }
            let busiest = screens.values.max() ?? 0
            print("markers: z\(tier.zoom) shows \(shown.count), busiest phone screen \(busiest)")
            // Even a phone screen full of downtown stays a map, not a wall of badges.
            XCTAssertLessThanOrEqual(busiest, 402 * 874 / Int(tier.spacing * tier.spacing), "z\(tier.zoom)")
        }
        XCTAssertLessThan(kept.count, 25_000)
    }

    func testEmptyInput() { XCTAssertTrue(PlaceMarkers.thin([]).isEmpty) }

    /// Runs over the bundled index, which holds the fixture or, when fetched for the app, the same schema at a larger size.
    func testFeedsFromTheSearchIndex() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = try SearchIndex.bundled(directory: folder)
        let candidates = index.markerCandidates()
        XCTAssertGreaterThan(candidates.count, 100)
        let kept = PlaceMarkers.thin(candidates)
        XCTAssertGreaterThan(kept.count, 50)
        XCTAssertTrue(kept.allSatisfy { PlaceMarkers.tiers.map(\.zoom).contains($0.firstZoom) })
        // Each marker's ID opens its place card.
        let first = try XCTUnwrap(kept.first)
        XCTAssertEqual(index.place(id: first.id)?.name, first.name)
    }
}
