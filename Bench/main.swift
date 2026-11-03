import Foundation
import PeoplemapsCore

// Router benchmark: load and init time, peak RSS, median route time per trip, mode and preference set.
//   swift build -c release --product peoplemaps-bench && .build/release/peoplemaps-bench [--scale N] [--runs N] [--json]
// --scale N routes on the bundled graph plus N-1 disjoint copies placed to its east, to show cost that grows with graph size.

// --county swaps in long King County trips. --extra N sets the extra-minutes budget. --audit prints each route's roads and top stress factors.
// --sample FILE routes the "lat lon lat lon" pairs in FILE in each mode: times, and noConnection and calmer rates.
var scale = 1, runs = 5, json = false, only = "", cap: Int?, boundMeters: Double?, county = false, extra = 5, audit = false, sampleFile: String?, printRows = false, onlyMode: TravelMode?
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--scale": scale = max(1, Int(args.popFirst() ?? "") ?? 1)
    case "--runs": runs = max(1, Int(args.popFirst() ?? "") ?? 5)
    case "--trip": only = args.popFirst() ?? ""
    case "--json": json = true
    case "--cap": cap = Int(args.popFirst() ?? "")
    case "--bound": boundMeters = Double(args.popFirst() ?? "")
    case "--county": county = true
    case "--extra": extra = Int(args.popFirst() ?? "") ?? 5
    case "--audit": audit = true
    case "--sample": sampleFile = args.popFirst()
    case "--rows": printRows = true
    case "--mode": onlyMode = TravelMode(rawValue: args.popFirst() ?? "")
    default: FileHandle.standardError.write(Data("usage: peoplemaps-bench [--scale N] [--runs N] [--trip NAME] [--cap N] [--bound METERS] [--json]\n".utf8)); exit(64)
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
/// Peak physical footprint in MB, the number jetsam reads on a phone; RSS includes clean mapped pages it doesn't count. 0 off Darwin.
func peakFootprintMB() -> Double {
    #if canImport(Darwin)
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) } }
    return ok == 0 ? Double(info.ri_lifetime_max_phys_footprint) / 1_048_576 : 0
    #else
    return 0
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
// --cap N and --bound METERS override the search limits (the cap, and the walk and bike distance beyond which fewer calmer searches run).
let limits = SearchLimits(concurrentSearches: cap ?? SearchLimits.standard.concurrentSearches,
                          longMeters: boundMeters.map { [.walk: $0, .bike: $0] } ?? SearchLimits.standard.longMeters)
let initTime = clock.measure { router = NativeRouter(graph: graph, limits: limits) }
let rssAfterInit = peakRSSMB()

func place(_ n: String, _ lat: Double, _ lon: Double) -> Place { Place(id: n, name: n, lat: lat, lon: lon, category: "x") }
let fremont = place("Fremont", 47.6513, -122.3500), gasWorks = place("GasWorks", 47.6456, -122.3344)
let calAnderson = place("CalAnderson", 47.6170, -122.3190), volunteer = place("Volunteer", 47.6300, -122.3150)
let ballard = place("Ballard", 47.6685, -122.3840), slu = place("SLU", 47.6270, -122.3370)
let capHill = place("CapHill", 47.6230, -122.3180), madrona = place("Madrona", 47.6170, -122.3030)
var trips: [(name: String, a: Place, b: Place)] = [("Fremont-GasWorks", fremont, gasWorks), ("CalAnderson-Volunteer", calAnderson, volunteer)]
if scale == 1 { trips += [("Ballard-SLU", ballard, slu), ("Ballard-CapHill", ballard, capHill), ("Ballard-Madrona", ballard, madrona)] }
if county {
    let federalWay = place("FederalWay", 47.3223, -122.3126), bothell = place("Bothell", 47.7601, -122.2054)
    let issaquah = place("Issaquah", 47.5301, -122.0326), renton = place("Renton", 47.4829, -122.2171), bellevue = place("Bellevue", 47.6101, -122.2015)
    let kirkland = place("Kirkland", 47.6769, -122.2060), auburn = place("Auburn", 47.3073, -122.2285), northBend = place("NorthBend", 47.4957, -121.7868), kent = place("Kent", 47.3809, -122.2348)
    trips = [("Fremont-GasWorks", fremont, gasWorks), ("Ballard-Bellevue", ballard, bellevue), ("Issaquah-Renton", issaquah, renton), ("FederalWay-Bothell", federalWay, bothell)]
    if audit { trips += [("Kirkland-Renton", kirkland, renton), ("Auburn-Issaquah", auburn, issaquah), ("Ballard-NorthBend", ballard, northBend), ("Ballard-Kent", ballard, kent)] }
}

/// Kilometres by road class, then the largest stress factors.
func describe(_ r: Route, _ graph: StreetGraph) -> String {
    var km: [String: Double] = [:]
    for id in r.edgeIDs { let e = graph.edges[id]; km[e.highway.replacingOccurrences(of: "_link", with: ""), default: 0] += e.meters / 1000 }
    let roads = km.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \(r1($0.value))" }.joined(separator: ", ")
    let top = r.metrics.breakdown.tallies.sorted { $0.value.cost > $1.value.cost }.prefix(6).map { "\($0.key.rawValue) x\(r1($0.value.amount))=\(Int($0.value.cost))" }.joined(separator: ", ")
    return "\(r1(r.metrics.meters / 1000)) km, \(r1(r.metrics.seconds / 60)) min, stress \(Int(r.metrics.stress)) | \(roads) | \(top)"
}

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
/// Freeway-to-freeway switches charged on a route: freeway entries less the ones from a street.
func switches(_ r: Route) -> Int {
    let fromStreet = zip(r.edges, r.edges.dropFirst()).filter { !$0.0.isFreeway && $0.1.isFreeway }.count
    return Int(r.metrics.breakdown[.freewayEntry].amount.rounded()) - fromStreet
}
if let sampleFile {
    let lines = try! String(contentsOfFile: sampleFile, encoding: .utf8).split(separator: "\n").map { $0.split(separator: " ").compactMap { Double($0) } }.filter { $0.count == 4 }
    for mode in TravelMode.allCases where onlyMode == nil || onlyMode == mode {
        var times: [Double] = [], none = 0, calmer = 0, other = 0, levels: [String: Int] = [:], gains: [Double] = []
        for (i, l) in lines.enumerated() {
            let a = place("a\(i)", l[0], l[1]), b = place("b\(i)", l[2], l[3])
            let began = clock.now
            do {
                let c = try router.compute(.init(origin: a, destination: b, mode: mode, extraMinutes: extra))
                times.append(ms(clock.now - began))
                if let m = c.calmer { calmer += 1; gains.append(m.metrics.seconds - c.fastest.metrics.seconds) }
                levels[c.fastestCalm.level.title, default: 0] += 1
                if printRows {
                    let free = c.fastest.edgeIDs.reduce(0.0) { $0 + (graph.edges[$1].isFreeway ? graph.edges[$1].meters : 0) }
                    print("row", mode.rawValue, i, Int(c.fastest.metrics.meters), Int(c.fastest.metrics.seconds), Int(c.fastest.metrics.stress), Int(free), c.calmer.map { Int($0.metrics.seconds) } ?? -1, c.calmer.map { Int($0.metrics.stress) } ?? -1, c.fastestCalm.value, r1(ms(clock.now - began)), switches(c.fastest), c.calmer.map(switches) ?? -1)
                }
            } catch RoutingError.noConnection { none += 1 } catch { other += 1 }
        }
        times.sort(); gains.sort()
        func at(_ q: Double, _ v: [Double]) -> Double { v.isEmpty ? 0 : v[min(v.count - 1, Int(q * Double(v.count)))] }
        print("sample \(mode.rawValue): \(lines.count) pairs, noConnection \(none), other errors \(other), routed \(times.count), calmer offered \(calmer), ms p50 \(r1(at(0.5, times))) p95 \(r1(at(0.95, times))) max \(r1(times.last ?? 0)), calmer extra min p50 \(r1(at(0.5, gains) / 60)), fastest levels \(levels.sorted { $0.key < $1.key }), peak RSS \(r1(peakRSSMB())) footprint \(r1(peakFootprintMB()))")
        fflush(nil)
    }
    exit(0)
}
if audit {
    for trip in trips where only.isEmpty || trip.name.contains(only) {
        for mode in TravelMode.allCases {
            do {
                let c = try router.compute(.init(origin: trip.a, destination: trip.b, mode: mode, extraMinutes: extra))
                print("\(trip.name) \(mode.rawValue) fastest: \(describe(c.fastest, graph))")
                if let calmer = c.calmer { print("\(trip.name) \(mode.rawValue) calmer:  \(describe(calmer, graph))") } else { print("\(trip.name) \(mode.rawValue) calmer:  none (\(c.noCalmer), \(c.candidateCount) candidates)") }
                print("\(trip.name) \(mode.rawValue) calm: fastest \(c.fastestCalm.value) \(c.fastestCalm.level.title), calmer \(c.calmerCalm.map { "\($0.value) \($0.level.title)" } ?? "-")")
            } catch { print("\(trip.name) \(mode.rawValue): \(error)") }
        }
    }
    exit(0)
}
let avoid: [(String, RoutePreferences)] = [("default", RoutePreferences()), ("hills+trafficLights avoid", RoutePreferences([.hills: .avoid, .trafficLights: .avoid]))]
for trip in trips where only.isEmpty || trip.name.contains(only) {
    for mode in TravelMode.allCases {
        for (label, prefs) in avoid {
            var times: [Double] = [], meters = 0, candidates = 0, fp = ""
            for _ in 0..<runs {
                var c: RouteComparison!
                times.append(ms(clock.measure {
                    do { c = try router.compute(.init(origin: trip.a, destination: trip.b, mode: mode, extraMinutes: extra, preferences: prefs)) }
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
        "peakRssMB": ["afterInit": r1(rssAfterInit), "final": r1(rssFinal)], "peakFootprintMB": r1(peakFootprintMB()),
        "routes": rows.map { ["trip": $0.trip, "mode": $0.mode, "prefs": $0.prefs, "medianMs": r1($0.median), "minMs": r1($0.min), "maxMs": r1($0.max),
                              "fastestMeters": $0.meters, "candidates": $0.candidates, "fingerprint": $0.fingerprint] as [String: Any] },
    ]
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else {
    print("scale \(scale): \(graph.nodes.count) nodes, \(graph.edges.count) edges; load \(r1(ms(loadTime))) ms, init \(r1(ms(initTime))) ms, peak RSS \(r1(rssAfterInit)) MB after init, \(r1(rssFinal)) MB final, peak footprint \(r1(peakFootprintMB())) MB")
    for r in rows { print("\(r.trip) \(r.mode) [\(r.prefs)]: median \(r1(r.median)) ms (min \(r1(r.min)), max \(r1(r.max))), \(r.meters) m, \(r.candidates) candidates, \(r.fingerprint)") }
}
