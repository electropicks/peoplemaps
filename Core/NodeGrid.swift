import Foundation

/// Nodes bucketed into a uniform grid, so a nearby-node query reads a few cells rather than every node.
struct NodeGrid: Sendable {
    private let minLat: Double, minLon: Double, cellLat = 0.004, cellLon = 0.006
    private let rows: Int, cols: Int
    private let start: [Int32]
    private let nodes: [Int32]
    private let widestLat: Double

    init(_ points: [Coordinate]) {
        let lats = points.map(\.lat), lons = points.map(\.lon)
        let minLat = lats.min() ?? 0, minLon = lons.min() ?? 0
        let rows = Int(((lats.max() ?? 0) - minLat) / 0.004) + 1, cols = Int(((lons.max() ?? 0) - minLon) / 0.006) + 1
        var start = [Int32](repeating: 0, count: rows * cols + 1)
        let cell = points.map { Int(($0.lat - minLat) / 0.004) * cols + Int(($0.lon - minLon) / 0.006) }
        for c in cell { start[c + 1] += 1 }
        for i in 0..<rows * cols { start[i + 1] += start[i] }
        var fill = start, list = [Int32](repeating: 0, count: points.count)
        for (i, c) in cell.enumerated() { list[Int(fill[c])] = Int32(i); fill[c] += 1 }
        self.minLat = minLat; self.minLon = minLon; self.rows = rows; self.cols = cols; self.start = start; nodes = list
        widestLat = max(abs(lats.min() ?? 0), abs(lats.max() ?? 0))
    }

    /// Calls `visit` for every node that may lie within `meters` of `point` (a superset; the caller measures).
    func forEachNode(within meters: Double, of point: Coordinate, _ visit: (Int) -> Void) {
        // Slightly generous so rounding in the distance formula can never put a node just outside the window.
        let dLat = meters / 6_371_000 * 180 / .pi * 1.01
        let dLon = dLat / cos(max(widestLat, abs(point.lat)) * .pi / 180)
        let r0 = Int(((point.lat - dLat - minLat) / cellLat).rounded(.down)), r1 = Int(((point.lat + dLat - minLat) / cellLat).rounded(.down))
        let c0 = Int(((point.lon - dLon - minLon) / cellLon).rounded(.down)), c1 = Int(((point.lon + dLon - minLon) / cellLon).rounded(.down))
        guard r1 >= 0, c1 >= 0, r0 < rows, c0 < cols else { return }
        for r in max(r0, 0)...min(r1, rows - 1) {
            for c in max(c0, 0)...min(c1, cols - 1) {
                for k in Int(start[r * cols + c])..<Int(start[r * cols + c + 1]) { visit(Int(nodes[k])) }
            }
        }
    }
}
