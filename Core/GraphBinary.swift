import Foundation

/// Reader for the binary graph written by `Scripts/import_osm.py` (schema v3; the layout is documented there).
/// Everything is little-endian and read with plain pointer loads; only the small restrictions/places tail is JSON.
enum GraphBinary {
    static let nilIndex: UInt32 = 0xFFFF_FFFF
    private static let headerSize = 64, segmentSize = 88, directionSize = 16

    static func decode(_ data: Data) throws -> StreetGraph {
        try data.withUnsafeBytes { try decode($0) }
    }

    private static func decode(_ raw: UnsafeRawBufferPointer) throws -> StreetGraph {
        func get<T>(_ type: T.Type, _ offset: Int) -> T { raw.loadUnaligned(fromByteOffset: offset, as: type) }
        func up8(_ n: Int) -> Int { (n + 7) & ~7 }
        guard raw.count >= headerSize, get(UInt32.self, 0) == 0x4247_4D50 /* "PMGB" */, get(UInt32.self, 4) == 3 else { throw RoutingError.missingData }
        let bounds = (0..<4).map { get(Double.self, 8 + 8 * $0) }
        let stringCount = Int(get(UInt32.self, 40)), nodeCount = Int(get(UInt32.self, 44)), segmentCount = Int(get(UInt32.self, 48))
        let pointCount = Int(get(UInt32.self, 52)), tailSize = Int(get(UInt32.self, 56))

        // Sections, in file order.
        let stringsAt = headerSize
        guard raw.count >= stringsAt + 4 * (stringCount + 1) else { throw RoutingError.missingData }
        let stringBytes = Int(get(UInt32.self, stringsAt + 4 * stringCount))
        let nodesAt = stringsAt + up8(4 * (stringCount + 1) + stringBytes)
        let nodeFlagsAt = nodesAt + 32 * nodeCount
        let pointsAt = nodeFlagsAt + up8(nodeCount)
        let segmentsAt = pointsAt + 8 * pointCount
        let tailAt = segmentsAt + (segmentSize + 2 * directionSize) * segmentCount
        guard raw.count >= tailAt + tailSize else { throw RoutingError.missingData }
        let textAt = stringsAt + 4 * (stringCount + 1)

        let strings: [String] = (0..<stringCount).map { i in
            let a = Int(get(UInt32.self, stringsAt + 4 * i)), b = Int(get(UInt32.self, stringsAt + 4 * i + 4))
            return String(decoding: UnsafeRawBufferPointer(rebasing: raw[(textAt + a)..<(textAt + b)]), as: UTF8.self)
        }
        func string(_ index: UInt32) -> String? { index == nilIndex ? nil : strings[Int(index)] }

        var nodes: [GraphNode] = []
        nodes.reserveCapacity(nodeCount)
        for i in 0..<nodeCount {
            let flags = get(UInt8.self, nodeFlagsAt + i)
            nodes.append(GraphNode(osm: get(Int64.self, nodesAt + 8 * i), lat: get(Double.self, nodesAt + 8 * nodeCount + 8 * i),
                                   lon: get(Double.self, nodesAt + 16 * nodeCount + 8 * i), z: get(Double.self, nodesAt + 24 * nodeCount + 8 * i),
                                   signal: flags & 1 != 0, pedestrianSignal: flags & 2 != 0))
        }

        let roadClasses: [RoadClass?] = [nil, .local, .arterial, .busy]
        let controls: [TrafficControl?] = [nil, .signal, .stop, .allstop, .yield]
        let modeOrder: [(bit: UInt8, mode: TravelMode)] = [(1, .drive), (2, .bike), (4, .walk)]
        var edges: [GraphEdge] = []
        edges.reserveCapacity(segmentCount * 2)
        for s in 0..<segmentCount {
            let at = segmentsAt + (segmentSize + 2 * directionSize) * s
            let start = Int(get(UInt32.self, at + 40)), count = Int(get(UInt32.self, at + 44))
            guard start + count <= pointCount else { throw RoutingError.missingData }
            let points = (0..<count).map { i -> Coordinate in
                let p = pointsAt + 8 * (start + i)
                return Coordinate(lat: Double(get(Int32.self, p + 4)) / 1e6, lon: Double(get(Int32.self, p)) / 1e6)
            }
            let reversed = Array(points.reversed())
            let a = Int(get(UInt32.self, at + 32)), b = Int(get(UInt32.self, at + 36))
            let way = get(Int64.self, at), meters = get(Double.self, at + 8)
            let up = get(Double.self, at + 16), down = get(Double.self, at + 24)
            let nameIndex = get(UInt32.self, at + 48), hw = get(UInt32.self, at + 52)
            guard nameIndex != nilIndex, hw != nilIndex, Int(nameIndex) < stringCount, Int(hw) < stringCount else { throw RoutingError.missingData }
            let steps = get(Int32.self, at + 72), lanes = get(Int32.self, at + 76)
            let crossingControl = get(UInt32.self, at + 80)
            let flags = get(UInt8.self, at + 84), crossingRoad = Int(get(UInt8.self, at + 85)), beside = Int(get(UInt8.self, at + 86))
            guard crossingRoad < roadClasses.count, beside < roadClasses.count else { throw RoutingError.missingData }

            func direction(_ d: Int) -> (modes: [TravelMode], at: Int)? {
                let o = at + segmentSize + d * directionSize
                let mask = get(UInt8.self, o + 12)
                return mask == 0 ? nil : (modeOrder.filter { mask & $0.bit != 0 }.map(\.mode), o)
            }
            let forward = direction(0), backward = direction(1)
            let twoWay = (forward?.modes.contains(.drive) ?? false) && (backward?.modes.contains(.drive) ?? false)
            for (dir, isForward) in [(forward, true), (backward, false)] {
                guard let dir else { continue }
                var e = GraphEdge(id: edges.count, from: isForward ? a : b, to: isForward ? b : a, wayID: way,
                                  coordinates: isForward ? points : reversed, meters: meters, modes: dir.modes,
                                  highway: strings[Int(hw)], name: strings[Int(nameIndex)], surface: string(get(UInt32.self, at + 60)),
                                  maxspeed: string(get(UInt32.self, at + 56)), lanes: lanes < 0 ? nil : Int(lanes))
                e.sidewalk = string(get(UInt32.self, at + 64))
                let parked = flags & 3
                e.parkedBothSides = parked == 0 ? nil : parked == 2
                e.movableBridge = flags & 4 != 0
                e.footway = string(get(UInt32.self, at + 68))
                e.steps = steps < 0 ? nil : Int(steps)
                if flags & 8 != 0 { e.crossing = Crossing(control: string(crossingControl), road: roadClasses[crossingRoad]) }
                e.besideRoad = roadClasses[beside]
                e.facility = string(get(UInt32.self, dir.at + 8)) ?? "none"
                let control = Int(get(UInt8.self, dir.at + 13))
                guard control < controls.count else { throw RoutingError.missingData }
                e.control = controls[control]
                let grade = get(Double.self, dir.at)
                e.approachGrade = grade.isNaN ? nil : grade
                let turn = get(UInt8.self, dir.at + 14)
                e.leftTurnLane = turn == 0 ? nil : turn == 2
                e.climb = isForward ? up : down; e.descent = isForward ? down : up; e.twoWayForDriving = twoWay
                edges.append(e)
            }
        }

        struct Tail: Decodable { let restrictions: [TurnRestriction]; let places: [Place] }
        let tail = try JSONDecoder().decode(Tail.self, from: Data(raw[tailAt..<(tailAt + tailSize)]))
        return StreetGraph(bounds: bounds, nodes: nodes, edges: edges, restrictions: tail.restrictions, places: tail.places)
    }
}
