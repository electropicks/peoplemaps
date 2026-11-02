import Foundation

/// The opt-in, on-device usage log (Docs/REPORTS.md section 11): one JSON line per trip in a file on the phone. It has
/// no network code, and nothing is written unless the caller says logging is on.
public struct UsageLog: Sendable {
    /// Trips kept; older lines are dropped on append.
    public static let limit = 500

    public enum Ended: String, Codable, Sendable { case arrived, endedEarly = "ended_early" }

    public struct Point: Codable, Equatable, Sendable {
        public var lat: Double
        public var lon: Double
        public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
    }

    public struct Estimate: Codable, Equatable, Sendable {
        public var minutes: Int
        public var meters: Double
        public init(minutes: Int, meters: Double) { self.minutes = minutes; self.meters = meters }
    }

    public struct Trip: Codable, Equatable, Sendable {
        public var at: Date
        public var mode: TravelMode
        public var extraMinutes: Int
        public var started: Report.Chosen
        public var fastest: Estimate
        public var calmer: Estimate?
        public var calmerOffered: Bool
        public var reroutes: Int
        /// Where the user left the route, rounded to about 100 m unless exact locations were on.
        public var departures: [Point]
        public var ended: Ended
        public init(at: Date, mode: TravelMode, extraMinutes: Int, started: Report.Chosen, fastest: Estimate, calmer: Estimate?,
                    calmerOffered: Bool, reroutes: Int, departures: [Point], ended: Ended) {
            self.at = at; self.mode = mode; self.extraMinutes = extraMinutes; self.started = started; self.fastest = fastest
            self.calmer = calmer; self.calmerOffered = calmerOffered; self.reroutes = reroutes; self.departures = departures; self.ended = ended
        }
    }

    public let url: URL
    public init(url: URL) { self.url = url }

    /// About 100 m: 0.0009 degrees of latitude, and 0.0013 of longitude at Seattle's latitude.
    public static func rounded(lat: Double, lon: Double) -> Point {
        Point(lat: Report.fiveDecimals((lat / 0.0009).rounded() * 0.0009), lon: Report.fiveDecimals((lon / 0.0013).rounded() * 0.0013))
    }
    public static func point(lat: Double, lon: Double, exact: Bool) -> Point {
        exact ? Point(lat: Report.fiveDecimals(lat), lon: Report.fiveDecimals(lon)) : rounded(lat: lat, lon: lon)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Adds one line and trims to the last `limit`. Does nothing, and creates no file, when `enabled` is false.
    public func append(_ trip: Trip, enabled: Bool) throws {
        guard enabled else { return }
        var lines = Self.lines(of: data())
        lines.append(try Self.encoder.encode(trip))
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }.write(to: url, options: .atomic)
    }

    /// The file as shared: the JSON lines, oldest first.
    public func data() -> Data { (try? Data(contentsOf: url)) ?? Data() }

    public func trips() -> [Trip] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Self.lines(of: data()).compactMap { try? decoder.decode(Trip.self, from: $0) }
    }
    public var count: Int { Self.lines(of: data()).count }

    public func clear() { try? FileManager.default.removeItem(at: url) }

    private static func lines(of data: Data) -> [Data] { data.split(separator: 0x0A).filter { !$0.isEmpty }.map { Data($0) } }
}
