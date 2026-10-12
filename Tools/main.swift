import Foundation
import PeoplemapsCore

let graph = try StreetGraph.bundled()
let router = NativeRouter(graph: graph)
let pairs = [("way/37056567","relation/1047789"), ("way/37058377","way/160545994"), ("node/693337509","relation/1047789")]
var rows: [[String: Any]] = []
for (start,end) in pairs {
    guard let a=graph.places.first(where:{$0.id==start}),let b=graph.places.first(where:{$0.id==end}) else { continue }
    for mode in TravelMode.allCases {
        for budget in [0,2,5,10] {
            let began=Date()
            do {
                let c=try router.compute(.init(origin:a,destination:b,mode:mode,extraMinutes:budget))
                rows.append(["origin":a.shortName,"destination":b.shortName,"mode":mode.rawValue,"budgetMinutes":budget,
                    "fastestSeconds":c.fastest.metrics.seconds,"calmerSeconds":c.calmer?.metrics.seconds as Any? ?? NSNull(),
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
