import Foundation
import PeoplemapsCore

let loadStart = Date()
let graph = try StreetGraph.bundled()
let graphDone = Date()
let router = NativeRouter(graph: graph)
FileHandle.standardError.write("load + router init: \(Date().timeIntervalSince(loadStart)) s (StreetGraph.bundled \(graphDone.timeIntervalSince(loadStart)) s)\n".data(using: .utf8)!)

/// `--calm-sample N`: seeded random place pairs in each mode, one JSON row per trip, for calibrating `CalmScore`.
if let flag = CommandLine.arguments.firstIndex(of: "--calm-sample") {
    let count = CommandLine.arguments.count > flag + 1 ? Int(CommandLine.arguments[flag + 1]) ?? 150 : 150
    var state: UInt64 = 0x5EA771E
    func next(_ bound: Int) -> Int { // SplitMix64, so the sample is the same on every machine.
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
    let places = graph.places.sorted { $0.id < $1.id }
    var trips: [[String: Any]] = []
    for mode in TravelMode.allCases {
        var done = 0
        while done < count {
            let a = places[next(places.count)], b = places[next(places.count)]
            guard a.id != b.id, let c = try? router.compute(.init(origin: a, destination: b, mode: mode, extraMinutes: 10)) else { continue }
            done += 1
            trips.append(["mode": mode.rawValue, "fastestSeconds": c.fastest.metrics.seconds, "fastestStress": c.fastest.metrics.stress,
                          "calmerSeconds": c.calmer?.metrics.seconds as Any? ?? NSNull(), "calmerStress": c.calmer?.metrics.stress as Any? ?? NSNull(),
                          "fastestMeters": c.fastest.metrics.meters, "fastestCalm": c.fastestCalm.value, "calmerCalm": c.calmerCalm?.value as Any? ?? NSNull(),
                          "fastestLevel": c.fastestCalm.level.title, "calmerLevel": c.calmerCalm?.level.title as Any? ?? NSNull(), "summary": c.calmSummary])
        }
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: trips, options: [.sortedKeys]), as: UTF8.self))
    exit(0)
}
let pairs = [("way/37056567","relation/1047789"), ("way/37058377","way/160545994"), ("node/693337509","relation/1047789"), ("way/37058377","way/37057155"), ("way/37056567","node/12786894083"), ("node/8156900401","node/6332022081")]
var rows: [[String: Any]] = []
/// Stress per factor, largest first: [factor, amount, cost].
func factors(_ route: Route) -> [[Any]] {
    route.metrics.breakdown.tallies.sorted { $0.value.cost > $1.value.cost }
        .map { [$0.key.rawValue, ($0.value.amount * 10).rounded() / 10, $0.value.cost.rounded()] }
}
for (start,end) in pairs {
    guard let a=graph.places.first(where:{$0.id==start}),let b=graph.places.first(where:{$0.id==end}) else { continue }
    for mode in TravelMode.allCases {
        for budget in [0,2,5,10] {
            let began=Date()
            do {
                let c=try router.compute(.init(origin:a,destination:b,mode:mode,extraMinutes:budget))
                rows.append(["origin":a.shortName,"destination":b.shortName,"mode":mode.rawValue,"budgetMinutes":budget,
                    "fastestSeconds":c.fastest.metrics.seconds,"calmerSeconds":c.calmer?.metrics.seconds as Any? ?? NSNull(),
                    "fastestStress":c.fastest.metrics.stress,"calmerStress":c.calmer?.metrics.stress as Any? ?? NSNull(),"caveats":c.caveats,
                    "fastestFactors":factors(c.fastest),"calmerFactors":c.calmer.map(factors) as Any? ?? NSNull(),
                    "extraSeconds":c.extraSeconds,"candidates":c.candidateCount,"reasons":c.reasons,
                    "fastestMeters":c.fastest.metrics.meters,"calmerMeters":c.calmer?.metrics.meters as Any? ?? NSNull(),
                    "originSnapMeters":c.originSnapMeters,"destinationSnapMeters":c.destinationSnapMeters,
                    "computeSeconds":Date().timeIntervalSince(began)])
            } catch { rows.append(["origin":a.shortName,"destination":b.shortName,"mode":mode.rawValue,"budgetMinutes":budget,"error":error.localizedDescription]) }
        }
    }
}
let data=try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys])
print(String(decoding:data,as:UTF8.self))
