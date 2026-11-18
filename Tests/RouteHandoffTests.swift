import XCTest
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import PeoplemapsCore

/// Edges on a local grid in metres, x east and y north, each its own way.
private enum Lines {
    static func coordinate(_ x: Double, _ y: Double) -> Coordinate {
        Coordinate(lat: 47.6 + y / 111_195, lon: -122.3 + x / (111_195 * cos(47.6 * .pi / 180)))
    }
    static func edge(_ way: Int64, _ from: (Double, Double), _ to: (Double, Double), name: String) -> GraphEdge {
        GraphEdge(id: Int(way), from: Int(way), to: Int(way) + 1, wayID: way, coordinates: [coordinate(from.0, from.1), coordinate(to.0, to.1)],
                  meters: hypot(to.0 - from.0, to.1 - from.1), modes: TravelMode.allCases, highway: "residential", name: name)
    }
    static func route(_ edges: [GraphEdge]) -> Route {
        var m = RouteMetrics(); m.meters = edges.reduce(0) { $0 + $1.meters }; m.seconds = m.meters / 10
        return Route(edgeIDs: edges.map(\.id), edgeMeters: edges.map(\.meters), coordinates: edges.flatMap(\.coordinates), metrics: m,
                     streetNames: edges.map(\.name), edges: edges)
    }
    static func place(_ name: String, _ x: Double, _ y: Double) -> Place {
        let c = coordinate(x, y)
        return Place(id: name, name: name, lat: c.lat, lon: c.lon, category: "park")
    }
}

final class RouteHandoffTests: XCTestCase {
    /// Fastest: straight north 1 km on Main. Calmer: a block of Main, east on Oak, north 800 m on Elm (two edges), back west on Pine.
    private let fastest = Lines.route([Lines.edge(1, (0, 0), (0, 100), name: "Main"), Lines.edge(2, (0, 100), (0, 1000), name: "Main")])
    private let calmer = Lines.route([Lines.edge(1, (0, 0), (0, 100), name: "Main"), Lines.edge(10, (0, 100), (200, 100), name: "Oak"),
                                      Lines.edge(11, (200, 100), (200, 500), name: "Elm"), Lines.edge(12, (200, 500), (200, 900), name: "Elm"),
                                      Lines.edge(13, (200, 900), (0, 900), name: "Pine"), Lines.edge(14, (0, 900), (0, 940), name: "")])

    private func comparison(mode: TravelMode, from origin: Place) -> RouteComparison {
        RouteComparison(request: .init(origin: origin, destination: Lines.place("Park", 0, 1000), mode: mode, extraMinutes: 10), fastest: fastest,
                        calmer: calmer, candidateCount: 2, originSnapMeters: 0, destinationSnapMeters: 0, snappedOrigin: fastest.coordinates[0],
                        snappedDestination: fastest.coordinates.last!)
    }

    private func assertNear(_ a: Coordinate, _ x: Double, _ y: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(a.distance(to: Lines.coordinate(x, y)), 1, file: file, line: line)
    }

    func testStopsMidwayAlongTheStreetsTheCalmerRouteTakesInstead() {
        let stops = RouteHandoff.stops(on: calmer, leaving: fastest, limit: 9)
        XCTAssertEqual(stops.count, 3, "Oak, Elm and Pine leave no gap over 500 m; the 40 m unnamed end is too short for a stop of its own")
        assertNear(stops[0], 100, 100)
        assertNear(stops[1], 200, 500)
        assertNear(stops[2], 100, 900)
    }

    func testLongestGapsAreSplitFirst() {
        let stops = RouteHandoff.stops(on: calmer, leaving: fastest, limit: 2)
        XCTAssertEqual(stops.count, 2)
        assertNear(stops[0], 100, 100)
        assertNear(stops[1], 200, 500)
        XCTAssertTrue(RouteHandoff.stops(on: fastest, leaving: fastest, limit: 9).isEmpty, "the same route needs no stops")
    }

    /// A long stretch both routes share gets a stop of its own, so the other app cannot swap it for its own fastest way.
    func testLongSharedStretchGetsAStop() {
        let fast = Lines.route([Lines.edge(1, (0, 0), (0, 2000), name: "Main")])
        let calm = Lines.route([Lines.edge(1, (0, 0), (0, 2000), name: "Main"), Lines.edge(2, (0, 2000), (300, 2000), name: "Oak")])
        let stops = RouteHandoff.stops(on: calm, leaving: fast, limit: 4)
        XCTAssertEqual(stops.count, 4)
        assertNear(stops[0], 0, 537.5)
        assertNear(stops[1], 0, 1075)
        assertNear(stops.last!, 150, 2000)
    }

    func testFastestOrOnlyRouteGoesWithoutStops() {
        let start = Lines.place("Home", 0, 0)
        XCTAssertEqual(RouteHandoff(comparison: comparison(mode: .bike, from: start), calmerChosen: false).stops, [])
        XCTAssertEqual(RouteHandoff(comparison: comparison(mode: .bike, from: start), calmerChosen: true).stops.count, 3)
    }

    func testGoogleMapsLinkCarriesStopsForEveryMode() throws {
        let handoff = RouteHandoff(comparison: comparison(mode: .bike, from: Lines.place("Home", 0, 0)), calmerChosen: true)
        let url = handoff.url(for: .googleMaps).absoluteString
        XCTAssertTrue(url.hasPrefix("https://www.google.com/maps/dir/?api=1&origin=47.600000,-122.300000&destination="), url)
        XCTAssertTrue(url.contains("&travelmode=bicycling&waypoints="), url)
        XCTAssertEqual(url.components(separatedBy: "%7C").count, 3, url)
        XCTAssertTrue(handoff.keepsStops(in: .googleMaps))
    }

    func testAppleMapsKeepsStopsOnlyWhenDriving() {
        let home = Lines.place("Home", 0, 0)
        let drive = RouteHandoff(comparison: comparison(mode: .drive, from: home), calmerChosen: true).url(for: .appleMaps).absoluteString
        XCTAssertTrue(drive.hasPrefix("https://maps.apple.com/directions?source=47.600000,-122.300000&destination="), drive)
        XCTAssertEqual(drive.components(separatedBy: "&waypoint=").count, 4, drive)
        XCTAssertTrue(drive.hasSuffix("&mode=driving"), drive)
        for mode in [TravelMode.walk, .bike] {
            let handoff = RouteHandoff(comparison: comparison(mode: mode, from: home), calmerChosen: true)
            XCTAssertFalse(handoff.keepsStops(in: .appleMaps))
            XCTAssertFalse(handoff.url(for: .appleMaps).absoluteString.contains("waypoint"))
        }
    }

    func testCurrentLocationLeavesTheStartToTheOtherApp() {
        let here = Place.currentLocation(at: Lines.coordinate(0, 0))
        let handoff = RouteHandoff(comparison: comparison(mode: .walk, from: here), calmerChosen: true)
        XCTAssertNil(handoff.origin)
        XCTAssertFalse(handoff.url(for: .googleMaps).absoluteString.contains("origin="))
        XCTAssertFalse(handoff.url(for: .appleMaps).absoluteString.contains("source="))
    }

    func testGPXTrackHasEveryPointAndAnEscapedName() {
        let gpx = calmer.gpx(name: "Calmer route to Pike & Pine <Cafe>", mode: .bike)
        XCTAssertEqual(gpx.components(separatedBy: "<trkpt ").count - 1, calmer.coordinates.count)
        XCTAssertTrue(gpx.contains("<name>Calmer route to Pike &amp; Pine &lt;Cafe&gt;</name>"))
        XCTAssertTrue(gpx.contains("<type>cycling</type>"))
        XCTAssertTrue(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\""))
        XCTAssertTrue(XMLParser(data: Data(gpx.utf8)).parse(), "well-formed")
    }

    /// The bundled graph's calmer drive from Fremont to Capitol Hill crosses the Fremont Bridge and takes Dexter where the fastest takes
    /// another way; it is pinned with at most 4 stops, each on the calmer line.
    func testBundledCalmerDriveIsPinnedOnItsOwnLine() throws {
        let router = NativeRouter(graph: try StreetGraph.bundled())
        let fremont = Place(id: "a", name: "Fremont", lat: 47.6513, lon: -122.35, category: "x"), capHill = Place(id: "b", name: "Cap Hill", lat: 47.623, lon: -122.318, category: "x")
        let c = try router.compute(.init(origin: fremont, destination: capHill, mode: .drive, extraMinutes: 10))
        let calmer = try XCTUnwrap(c.calmer)
        let stops = RouteHandoff(comparison: c, calmerChosen: true).stops
        XCTAssertTrue((1...RouteHandoff.maxStops(for: .drive)).contains(stops.count), "\(stops.count) stops")
        for stop in stops { XCTAssertLessThan(stop.distance(toPolyline: calmer.coordinates), 2) }
    }
}
