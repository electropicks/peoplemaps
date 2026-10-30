import XCTest
@testable import PeoplemapsCore

/// The binary graph must decode to exactly what the importer's JSON describes. The importer runs once into a temp dir,
/// emitting both formats from the same in-memory graph. macOS only: it needs Process and python3.
final class BinaryGraphTests: XCTestCase {
    func testBinaryGraphMatchesImporterJSON() throws {
        #if os(macOS)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("peoplemaps-graph-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("Scripts/import_osm.py").path,
                             "--out", temp.path, "--json-graph", temp.appendingPathComponent("graph.json").path]
        process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "importer could not run")

        let json = try Data(contentsOf: temp.appendingPathComponent("graph.json"))
        let expected = try JSONDecoder().decode(GraphFile.self, from: json).graph()
        let actual = try GraphBinary.decode(Data(contentsOf: temp.appendingPathComponent("seattle-graph.bin")))
        assertSame(actual, expected)

        // The graph shipped in the app is the importer's output too.
        assertSame(try StreetGraph.bundled(), expected)
        #else
        throw XCTSkip("needs python3")
        #endif
    }

    func testRejectsCorruptData() throws {
        XCTAssertThrowsError(try GraphBinary.decode(Data("not a graph".utf8)))
        XCTAssertThrowsError(try GraphBinary.decode(Data(repeating: 0, count: 64)))
        let url = try XCTUnwrap(Bundle.module.url(forResource: "seattle-graph", withExtension: "bin"))
        XCTAssertThrowsError(try GraphBinary.decode(Data(try Data(contentsOf: url).prefix(5_000))))
    }

    private func assertSame(_ a: StreetGraph, _ b: StreetGraph) {
        XCTAssertEqual(a.bounds, b.bounds)
        XCTAssertEqual(a.nodes.count, b.nodes.count); XCTAssertEqual(a.edges.count, b.edges.count)
        XCTAssertGreaterThan(a.nodes.count, 1000); XCTAssertGreaterThan(a.edges.count, 1000)
        for (x, y) in zip(a.nodes, b.nodes) {
            guard x.osm == y.osm, x.lat == y.lat, x.lon == y.lon, x.z == y.z, x.signal == y.signal, x.pedestrianSignal == y.pedestrianSignal
            else { return XCTFail("node \(x.osm) differs") }
        }
        for (x, y) in zip(a.edges, b.edges) {
            guard x.id == y.id, x.from == y.from, x.to == y.to, x.wayID == y.wayID, x.coordinates == y.coordinates, x.meters == y.meters,
                  x.modes == y.modes, x.highway == y.highway, x.name == y.name, x.surface == y.surface, x.maxspeed == y.maxspeed,
                  x.lanes == y.lanes, x.sidewalk == y.sidewalk, x.parkedBothSides == y.parkedBothSides, x.movableBridge == y.movableBridge,
                  x.footway == y.footway, x.steps == y.steps, x.crossing == y.crossing, x.besideRoad == y.besideRoad,
                  x.facility == y.facility, x.climb == y.climb, x.descent == y.descent, x.approachGrade == y.approachGrade,
                  x.control == y.control, x.leftTurnLane == y.leftTurnLane, x.twoWayForDriving == y.twoWayForDriving
            else { return XCTFail("edge \(x.id) (way \(x.wayID)) differs") }
        }
        XCTAssertEqual(a.restrictions.count, b.restrictions.count)
        for (x, y) in zip(a.restrictions, b.restrictions) {
            XCTAssertTrue(x.via == y.via && x.fromWay == y.fromWay && x.toWay == y.toWay && x.kind == y.kind && x.mode == y.mode && x.osmID == y.osmID)
        }
        XCTAssertEqual(a.places, b.places)
    }
}

/// The importer's JSON graph (schema v2) and the decoder the app used before the binary format: the reference the binary reader must match.
private struct GraphFile: Decodable {
    struct Direction: Decodable {
        let modes: [TravelMode]
        let facility: String?
        let control: TrafficControl?
        let approachGrade: Double?
        let leftTurnLane: Bool?
    }
    struct Segment: Decodable {
        let way: Int64, a: Int, b: Int, g: [Double], m: Double, hw: String, n: Int, up: Double, down: Double
        let lanes: Int?, maxspeed: String?, surface: String?, sidewalk: String?, parkedBothSides: Bool?
        let movableBridge: Bool?, footway: String?, steps: Int?, crossing: Crossing?, besideRoad: RoadClass?
        let f: Direction?, r: Direction?
    }
    let schemaVersion: Int
    let bounds: [Double]
    let names: [String]
    let nodes: [GraphNode]
    let segments: [Segment]
    let restrictions: [TurnRestriction]
    let places: [Place]

    func graph() -> StreetGraph {
        var edges: [GraphEdge] = []
        edges.reserveCapacity(segments.count * 2)
        for s in segments {
            let points = stride(from: 0, to: s.g.count - 1, by: 2).map { Coordinate(lat: s.g[$0 + 1], lon: s.g[$0]) }
            let twoWay = (s.f?.modes.contains(.drive) ?? false) && (s.r?.modes.contains(.drive) ?? false)
            for (direction, forward) in [(s.f, true), (s.r, false)] {
                guard let direction, !direction.modes.isEmpty else { continue }
                var e = GraphEdge(id: edges.count, from: forward ? s.a : s.b, to: forward ? s.b : s.a, wayID: s.way,
                                  coordinates: forward ? points : points.reversed(), meters: s.m, modes: direction.modes,
                                  highway: s.hw, name: names[s.n], surface: s.surface, maxspeed: s.maxspeed, lanes: s.lanes)
                e.sidewalk = s.sidewalk; e.parkedBothSides = s.parkedBothSides; e.movableBridge = s.movableBridge ?? false
                e.footway = s.footway; e.steps = s.steps; e.crossing = s.crossing; e.besideRoad = s.besideRoad
                e.facility = direction.facility ?? "none"; e.control = direction.control
                e.approachGrade = direction.approachGrade; e.leftTurnLane = direction.leftTurnLane
                e.climb = forward ? s.up : s.down; e.descent = forward ? s.down : s.up; e.twoWayForDriving = twoWay
                edges.append(e)
            }
        }
        return StreetGraph(bounds: bounds, nodes: nodes, edges: edges, restrictions: restrictions, places: places)
    }
}
