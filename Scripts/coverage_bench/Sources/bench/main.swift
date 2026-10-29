import Foundation
import PeoplemapsCore

// Graph decode + router init + median-of-5 route time per trip and mode. PEOPLEMAPS_GRAPH selects the graph file.
func peakRSSMB() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_maxrss) / 1_048_576 }
func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
let clock = ContinuousClock()

var graph: StreetGraph!
let decode = clock.measure { graph = try! StreetGraph.bundled() }
let rssAfterDecode = peakRSSMB()
var router: NativeRouter!
let initTime = clock.measure { router = NativeRouter(graph: graph) }
print("decode_ms \(Int(ms(decode))) router_init_ms \(Int(ms(initTime))) nodes \(graph.nodes.count) edges \(graph.edges.count) places \(graph.places.count)")
print("peak_rss_mb_after_decode \(Int(rssAfterDecode)) after_router_init \(Int(peakRSSMB()))")

func place(_ n: String, _ lat: Double, _ lon: Double) -> Place { Place(id: n, name: n, lat: lat, lon: lon, category: "x") }
let fremont = place("Fremont", 47.6513, -122.3500), gasWorks = place("GasWorks", 47.6456, -122.3344)
let calAnderson = place("CalAnderson", 47.6170, -122.3190), volunteer = place("Volunteer", 47.6300, -122.3150)
let ballard = place("Ballard", 47.6685, -122.3840), slu = place("SLU", 47.6270, -122.3370)
let capHill = place("CapHill", 47.6230, -122.3180), madrona = place("Madrona", 47.6170, -122.3030)
let columbia = place("ColumbiaCity", 47.5590, -122.2860)
var trips: [(String, Place, Place)] = [("short Fremont-GasWorks", fremont, gasWorks), ("short CalAnderson-Volunteer", calAnderson, volunteer),
                                       ("medium Ballard-SLU", ballard, slu), ("medium Ballard-CapHill", ballard, capHill),
                                       ("long Ballard-Madrona", ballard, madrona)]
if graph.contains(columbia.coordinate) { trips.append(("long Ballard-ColumbiaCity", ballard, columbia)) }
for (name, a, b) in trips {
    for mode in TravelMode.allCases {
        var times: [Double] = []; var info = ""
        for _ in 0..<5 {
            let r = clock.measure {
                do { let c = try router.compute(.init(origin: a, destination: b, mode: mode, extraMinutes: 5))
                     info = "fastest \(Int(c.fastest.metrics.meters)) m, \(c.candidateCount) candidates" }
                catch { info = "ERROR \(error.localizedDescription)" }
            }
            times.append(ms(r))
        }
        times.sort()
        print("route \(name) \(mode.rawValue) median_ms \(Int(times[2])) min \(Int(times[0])) max \(Int(times[4])) [\(info)]")
    }
}
print("peak_rss_mb_final \(Int(peakRSSMB()))")
