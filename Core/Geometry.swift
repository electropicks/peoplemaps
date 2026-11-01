import Foundation

public extension Coordinate {
    /// Metres from this point to the nearest point of the segment `a`–`b`, on a flat approximation good for a city.
    func distance(toSegment a: Coordinate, _ b: Coordinate) -> Double {
        let scale = cos(lat * .pi / 180)
        let ax = (a.lon - lon) * scale, ay = a.lat - lat
        let bx = (b.lon - lon) * scale, by = b.lat - lat
        let dx = bx - ax, dy = by - ay
        let length = dx * dx + dy * dy
        let t = length > 0 ? min(1, max(0, -(ax * dx + ay * dy) / length)) : 0
        return hypot(ax + dx * t, ay + dy * t) * .pi / 180 * 6_371_000
    }

    /// Metres from this point to the nearest point of a polyline; infinity when the line is empty.
    func distance(toPolyline line: [Coordinate]) -> Double {
        guard let first = line.first else { return .infinity }
        guard line.count > 1 else { return distance(to: first) }
        var best = Double.infinity
        for i in 1..<line.count { best = min(best, distance(toSegment: line[i - 1], line[i])) }
        return best
    }
}
