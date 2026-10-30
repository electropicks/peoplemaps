import Foundation
import PeoplemapsCore

// Router benchmark: load and init time, peak RSS, median route time per trip, mode and preference set.
//   swift build -c release --product peoplemaps-bench && .build/release/peoplemaps-bench [--scale N] [--runs N] [--json]
// --scale N routes on the bundled graph plus N-1 disjoint copies placed to its east, to show cost that grows with graph size.

var scale = 1, runs = 5, json = false
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--scale": scale = max(1, Int(args.popFirst() ?? "") ?? 1)
    case "--runs": runs = max(1, Int(args.popFirst() ?? "") ?? 5)
    case "--json": json = true
    default: FileHandle.standardError.write(Data("usage: peoplemaps-bench [--scale N] [--runs N] [--json]\n".utf8)); exit(64)
    }
}

/// Peak resident set in MB; ru_maxrss is bytes on macOS and kilobytes on Linux.
func peakRSSMB() -> Double {
    var u = rusage()
    #if canImport(Darwin)
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_maxrss) / 1_048_576
    #else
    getrusage(RUSAGE_SELF.rawValue, &u)
    return Double(u.ru_maxrss) / 1024
    #endif
}
func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
let clock = ContinuousClock()

/// The graph plus `copies - 1` translations of it, each a multiple of the bounds' width further east. Places stay with the original.
/// The original takes the last block of node and edge ids: the router snaps to its largest connected component, and on a tie that is the last block.
func tiled(_ g: StreetGraph, copies: Int) -> StreetGraph {
    let width = g.bounds[3] - g.bounds[1]
    var nodes: [GraphNode] = [], edges: [GraphEdge] = [], restrictions: [TurnRestriction] = []
    nodes.reserveCapacity(g.nodes.count * copies); edges.reserveCapacity(g.edges.count * copies)
    for k in 0..<copies {
        let dLon = Double(copies - 1 - k) * width, nodeBase = k * g.nodes.count, edgeBase = k * g.edges.count
        for n in g.nodes { nodes.append(GraphNode(osm: n.osm, lat: n.lat, lon: n.lon + dLon, z: n.z, signal: n.signal, pedestrianSignal: n.pedestrianSignal)) }
        for var e in g.edges {
            e.id += edgeBase; e.from += nodeBase; e.to += nodeBase
            e.coordinates = e.coordinates.map { Coordinate(lat: $0.lat, lon: $0.lon + dLon) }
            edges.append(e)
        }
        for r in g.restrictions { restrictions.append(TurnRestriction(via: r.via + nodeBase, fromWay: r.fromWay, toWay: r.toWay, kind: r.kind, mode: r.mode, osmID: r.osmID)) }
    }
    let original = (copies - 1) * g.nodes.count
    let places = g.places.map { p -> Place in var p = p; p.snap = p.snap.mapValues { $0 + original }; return p }
    let b = g.bounds
    return StreetGraph(bounds: [b[0], b[1], b[2], b[3] + Double(copies - 1) * width], nodes: nodes, edges: edges, restrictions: restrictions, places: places)
}

var graph: StreetGraph!
let loadTime = clock.measure { graph = try! StreetGraph.bundled() }
let baseNodes = graph.nodes.count, baseEdges = graph.edges.count
var tiledTime = Duration.zero
if scale > 1 { tiledTime = clock.measure { graph = tiled(graph, copies: scale) } }
var router: NativeRouter!
let initTime = clock.measure { router = NativeRouter(graph: graph) }
let rssAfterInit = peakRSSMB()

func place(_ n: String, _ lat: Double, _ lon: Double) -> Place { Place(id: n, name: n, lat: lat, lon: lon, category: "x") }
let fremont = place("Fremont", 47.6513, -122.3500), gasWorks = place("GasWorks", 47.6456, -122.3344)
let calAnderson = place("CalAnderson", 47.6170, -122.3190), volunteer = place("Volunteer", 47.6300, -122.3150)
let ballard = place("Ballard", 47.6685, -122.3840), slu = place("SLU", 47.6270, -122.3370)
let capHill = place("CapHill", 47.6230, -122.3180), madrona = place("Madrona", 47.6170, -122.3030)
var trips: [(name: String, a: Place, b: Place)] = [("Fremont-GasWorks", fremont, gasWorks), ("CalAnderson-Volunteer", calAnderson, volunteer)]
if scale == 1 { trips += [("Ballard-SLU", ballard, slu), ("Ballard-CapHill", ballard, capHill), ("Ballard-Madrona", ballard, madrona)] }

// The copies must not connect: no edge or turn restriction leaves its block of ids.
if scale > 1 {
    precondition(graph.edges.allSatisfy { $0.from / baseNodes == $0.to / baseNodes && $0.id / baseEdges == $0.from / baseNodes }, "copies are connected")
    precondition(graph.restrictions.allSatisfy { $0.via < graph.nodes.count })
}

func fnv(_ ids: [Int]) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for id in ids { for shift in stride(from: 0, to: 64, by: 8) { h = (h ^ UInt64((id >> shift) & 0xff)) &* 0x100000001b3 } }
    return String(h, radix: 16)
}

struct Row { var trip: String, mode: String, prefs: String, median: Double, min: Double, max: Double, meters: Int, candidates: Int, fingerprint: String }
var rows: [Row] = []
let avoid: [(String, RoutePreferences)] = [("default", RoutePreferences()), ("hills+trafficLights avoid", RoutePreferences([.hills: .avoid, .trafficLights: .avoid]))]
for trip in trips {
    for mode in TravelMode.allCases {
        for (label, prefs) in avoid {
            var times: [Double] = [], meters = 0, candidates = 0, fp = ""
            for _ in 0..<runs {
                var c: RouteComparison!
                times.append(ms(clock.measure {
                    do { c = try router.compute(.init(origin: trip.a, destination: trip.b, mode: mode, extraMinutes: 5, preferences: prefs)) }
                    catch { fatalError("\(trip.name) \(mode.rawValue): \(error)") }
                }))
                meters = Int(c.fastest.metrics.meters); candidates = c.candidateCount; fp = fnv(c.fastest.edgeIDs) + "/" + fnv(c.calmer?.edgeIDs ?? [])
            }
            times.sort()
            rows.append(Row(trip: trip.name, mode: mode.rawValue, prefs: label, median: times[times.count / 2], min: times[0], max: times[times.count - 1],
                            meters: meters, candidates: candidates, fingerprint: fp))
        }
    }
}
let rssFinal = peakRSSMB()

func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
if json {
    let out: [String: Any] = [
        "scale": scale, "runs": runs, "nodes": graph.nodes.count, "edges": graph.edges.count, "baseNodes": baseNodes, "baseEdges": baseEdges,
        "loadMs": r1(ms(loadTime)), "tileMs": r1(ms(tiledTime)), "initMs": r1(ms(initTime)),
        "peakRssMB": ["afterInit": r1(rssAfterInit), "final": r1(rssFinal)],
        "routes": rows.map { ["trip": $0.trip, "mode": $0.mode, "prefs": $0.prefs, "medianMs": r1($0.median), "minMs": r1($0.min), "maxMs": r1($0.max),
                              "fastestMeters": $0.meters, "candidates": $0.candidates, "fingerprint": $0.fingerprint] as [String: Any] },
    ]
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else {
    print("scale \(scale): \(graph.nodes.count) nodes, \(graph.edges.count) edges; load \(r1(ms(loadTime))) ms, init \(r1(ms(initTime))) ms, peak RSS \(r1(rssAfterInit)) MB after init, \(r1(rssFinal)) MB final")
    for r in rows { print("\(r.trip) \(r.mode) [\(r.prefs)]: median \(r1(r.median)) ms (min \(r1(r.min)), max \(r1(r.max))), \(r.meters) m, \(r.candidates) candidates, \(r.fingerprint)") }
}
