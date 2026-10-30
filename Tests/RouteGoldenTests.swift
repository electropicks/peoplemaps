import XCTest
@testable import PeoplemapsCore

/// Routes on the bundled Seattle graph, fingerprinted so router optimisations can prove they change nothing.
/// Regenerate Tests/Fixtures/route-golden.json from a router you trust with PEOPLEMAPS_WRITE_GOLDEN=1 swift test --filter RouteGoldenTests
final class RouteGoldenTests: XCTestCase {
    struct Print: Codable, Equatable {
        var edges: String, count: Int, meters: Double, seconds: Double, stress: Double
    }
    struct Entry: Codable, Equatable {
        var key: String
        var error: String?
        var fastest: Print?, calmer: Print?
        var candidates: Int?
        var reasons: [String]?
    }

    private static let graph = try! StreetGraph.bundled()
    private static let router = NativeRouter(graph: graph)

    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9; z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// Deterministic place pairs: `count` of roughly `meters` apart (within a factor of 1.5), drawn from places sorted by id.
    private static func pairs(_ count: Int, near meters: Double, seed: UInt64) -> [(Place, Place)] {
        let places = graph.places.sorted { $0.id < $1.id }
        var rng = Rng(state: seed), out: [(Place, Place)] = []
        while out.count < count {
            let a = places[rng.below(places.count)]
            let far = places.filter { (meters / 1.5)...(meters * 1.5) ~= a.coordinate.distance(to: $0.coordinate) }
            guard !far.isEmpty else { continue }
            out.append((a, far[rng.below(far.count)]))
        }
        return out
    }

    private static func requests() -> [(key: String, request: RouteRequest)] {
        let short = pairs(14, near: 1_500, seed: 1), long = pairs(2, near: 7_000, seed: 2)
        var out: [(String, RouteRequest)] = []
        func add(_ a: Place, _ b: Place, _ mode: TravelMode, _ budget: Int, _ prefs: RoutePreferences? = nil, _ label: String = "default") {
            out.append(("\(a.id)>\(b.id) \(mode.rawValue) \(budget) \(label)", RouteRequest(origin: a, destination: b, mode: mode, extraMinutes: budget, preferences: prefs)))
        }
        for (a, b) in short + long { for mode in TravelMode.allCases { for budget in [0, 5] { add(a, b, mode, budget) } } }
        let sets: [(String, RoutePreferences)] = [
            ("hills+lights avoid", .init([.hills: .avoid, .trafficLights: .avoid])),
            ("stops+turns dontMind", .init([.stopSigns: .dontMind, .turns: .dontMind, .busyCrossings: .dontMind])),
            ("streets+lefts avoid", .init([.busyStreets: .avoid, .unprotectedLefts: .avoid])),
        ]
        for (i, (a, b)) in (short.prefix(4) + long.prefix(1)).enumerated() {
            for (m, mode) in TravelMode.allCases.enumerated() { let (label, prefs) = sets[(i + m) % sets.count]; add(a, b, mode, 5, prefs, label) }
        }
        return out
    }

    private static func fnv(_ ids: [Int]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for id in ids { for shift in stride(from: 0, to: 64, by: 8) { h = (h ^ UInt64((id >> shift) & 0xff)) &* 0x100000001b3 } }
        return String(h, radix: 16)
    }
    private static func micro(_ x: Double) -> Double { (x * 1e6).rounded() / 1e6 }
    private static func print(_ r: Route) -> Print {
        Print(edges: fnv(r.edgeIDs), count: r.edgeIDs.count, meters: micro(r.metrics.meters), seconds: micro(r.metrics.seconds), stress: micro(r.metrics.stress))
    }

    private static func run() -> [Entry] {
        let requests = requests()
        nonisolated(unsafe) var entries = [Entry?](repeating: nil, count: requests.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: requests.count) { i in
            var entry = Entry(key: requests[i].key)
            do {
                let c = try router.compute(requests[i].request)
                entry.fastest = print(c.fastest); entry.calmer = c.calmer.map(print); entry.candidates = c.candidateCount; entry.reasons = c.reasons
            } catch { entry.error = "\(error)" }
            lock.lock(); entries[i] = entry; lock.unlock()
        }
        return entries.map { $0! }
    }

    private var fixtureURL: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/route-golden.json") }

    func testRoutesMatchTheRecordedFingerprints() throws {
        let entries = Self.run()
        if ProcessInfo.processInfo.environment["PEOPLEMAPS_WRITE_GOLDEN"] == "1" {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: fixtureURL)
            return
        }
        let golden = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: Bundle.module.url(forResource: "route-golden", withExtension: "json") ?? fixtureURL))
        XCTAssertEqual(golden.map(\.key), entries.map(\.key), "The request list changed; regenerate the fixture")
        XCTAssertGreaterThan(golden.filter { $0.error == nil }.count, golden.count * 9 / 10, "Most trips should route")
        XCTAssertTrue(golden.contains { $0.calmer != nil }, "Some trips should have a calmer route")
        for (want, got) in zip(golden, entries) where want.key == got.key {
            XCTAssertEqual(got.error, want.error, want.key)
            XCTAssertEqual(got.candidates, want.candidates, want.key)
            XCTAssertEqual(got.reasons, want.reasons, want.key)
            for (name, w, g) in [("fastest", want.fastest, got.fastest), ("calmer", want.calmer, got.calmer)] {
                XCTAssertEqual(g == nil, w == nil, "\(want.key) \(name)")
                guard let w, let g else { continue }
                XCTAssertEqual(g.edges, w.edges, "\(want.key) \(name) edge ids")
                XCTAssertEqual(g.count, w.count, "\(want.key) \(name)")
                XCTAssertEqual(g.meters, w.meters, accuracy: 2e-6, "\(want.key) \(name)")
                XCTAssertEqual(g.seconds, w.seconds, accuracy: 2e-6, "\(want.key) \(name)")
                XCTAssertEqual(g.stress, w.stress, accuracy: 2e-6, "\(want.key) \(name)")
            }
        }
    }
}
