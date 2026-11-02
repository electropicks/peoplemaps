import Foundation

/// Measuring and cutting a route line, for drawing the part already driven apart from the part ahead.
public enum RouteLine {
    /// Metres along the line, summing straight legs between its coordinates.
    public static func length(_ line: [Coordinate]) -> Double {
        guard line.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<line.count { total += line[i - 1].distance(to: line[i]) }
        return total
    }

    /// Cuts the line `meters` from its start. Both halves share the cut point, so drawn together they leave no gap.
    /// Before the start `passed` is empty and `ahead` the whole line; at or past the end `ahead` is empty and `passed` the whole line.
    /// A degenerate line (fewer than two coordinates) is all ahead.
    public static func split(_ line: [Coordinate], atMeters meters: Double) -> (passed: [Coordinate], ahead: [Coordinate]) {
        guard line.count > 1, meters.isFinite else { return ([], line) }
        if meters <= 0 { return ([], line) }
        var travelled = 0.0
        for i in 1..<line.count {
            let leg = line[i - 1].distance(to: line[i])
            if travelled + leg >= meters {
                // A cut within a centimetre of a coordinate lands on it, so no repeated point is drawn.
                if leg - (meters - travelled) < 0.01 { return (Array(line[...i]), Array(line[i...]).count > 1 ? Array(line[i...]) : []) }
                let t = leg > 0 ? (meters - travelled) / leg : 0
                let cut = Coordinate(lat: line[i - 1].lat + (line[i].lat - line[i - 1].lat) * t,
                                     lon: line[i - 1].lon + (line[i].lon - line[i - 1].lon) * t)
                return (Array(line[..<i]) + [cut], [cut] + Array(line[i...]))
            }
            travelled += leg
        }
        return (line, [])
    }
}
