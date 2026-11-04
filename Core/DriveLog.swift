import Foundation

/// The opt-in, on-device detailed log (Docs/REPORTS.md section 11): one JSON-lines file per guided trip, and one per day for
/// how the app was used. It has no network code, writes nothing unless the caller says it is on, and each line reaches the
/// file as it happens, so a crash keeps what was captured. Real files hold exact places: they stay on the phone until shared.
public struct DriveLog: Sendable {
    /// A trip that ends sooner than this is deleted when it ends.
    public static let minimumTripSeconds: TimeInterval = 180
    /// Total size of the folder, trips and daily files together; the oldest trips are dropped past it.
    public static let capBytes = 500 * 1024 * 1024
    public static let schema = 1

    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    // MARK: Lines

    /// A small JSON value, so an event can carry named numbers, words and lists without a type per event.
    public indirect enum Value: Codable, Equatable, Sendable {
        case string(String), number(Double), bool(Bool), list([Value]), object([String: Value])

        /// Any encodable record as a value, for events that carry one (a reroute's new route).
        public init?<T: Encodable>(encoding record: T) {
            guard let data = try? DriveLog.encoder.encode(record), let value = try? JSONDecoder().decode(Value.self, from: data) else { return nil }
            self = value
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([Value].self) { self = .list(v) }
            else { self = .object(try c.decode([String: Value].self)) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case let .string(v): try c.encode(v)
            case let .number(v): try c.encode(v)
            case let .bool(v): try c.encode(v)
            case let .list(v): try c.encode(v)
            case let .object(v): try c.encode(v)
            }
        }
    }

    /// One location fix as navigation received it. Altitude is only there when the source gives one (Ferrostar's fix has none).
    public struct Fix: Codable, Equatable, Sendable {
        public var kind = "fix"
        public var t: Double
        public var lat: Double, lon: Double
        public var accuracy: Double
        public var speed: Double?, speedAccuracy: Double?
        public var course: Double?, courseAccuracy: Double?
        public var altitude: Double?
        public init(t: Date, lat: Double, lon: Double, accuracy: Double, speed: Double? = nil, speedAccuracy: Double? = nil,
                    course: Double? = nil, courseAccuracy: Double? = nil, altitude: Double? = nil) {
            self.t = Self.ms(t); self.lat = Self.round(lat, 6); self.lon = Self.round(lon, 6); self.accuracy = Self.round(accuracy, 1)
            self.speed = speed.map { Self.round($0, 2) }; self.speedAccuracy = speedAccuracy.map { Self.round($0, 2) }
            self.course = course.map { Self.round($0, 0) }; self.courseAccuracy = courseAccuracy.map { Self.round($0, 0) }
            self.altitude = altitude.map { Self.round($0, 1) }
        }
        static func ms(_ date: Date) -> Double { round(date.timeIntervalSince1970, 3) }
        static func round(_ x: Double, _ places: Int) -> Double { let f = pow(10.0, Double(places)); return (x * f).rounded() / f }
    }

    /// A moment in a trip or in app use: seconds since 1970 to the millisecond, a fixed name, and named values.
    public struct Event: Codable, Equatable, Sendable {
        public var kind = "event"
        public var t: Double
        public var name: String
        public var data: [String: Value]?
        public init(at: Date, name: String, data: [String: Value] = [:]) { t = Fix.ms(at); self.name = name; self.data = data.isEmpty ? nil : data }
    }

    /// A route as the router found it, kept in full so a trip can be compared with what was estimated.
    public struct RouteRecord: Codable, Equatable, Sendable {
        public struct Step: Codable, Equatable, Sendable {
            public var index: Int
            /// `depart`, `left`, `slight_left`, `sharp_left`, `right`, `slight_right`, `sharp_right`, `u_turn`, `continue`, `cross`, `arrive`.
            public var kind: String
            public var instruction: String
            public var street: String
            public var meters: Double, seconds: Double
            /// Where the maneuver happens: the first point of the step that follows it.
            public var lat: Double?, lon: Double?
            public var note: String?
        }
        public var label: String
        public var meters: Double, seconds: Double
        public var stress: Double?
        public var calmScore: Int?, calmLevel: String?
        /// Parallel arrays, one entry per edge. `edgeSeconds` is the time on the edge alone: `junctionSeconds` holds the rest of `seconds`.
        public var edgeIDs: [Int]
        public var wayIDs: [Int64]
        public var edgeNames: [String]
        public var edgeMeters: [Double]
        public var edgeSeconds: [Double]
        /// Index into `coordinates` of each edge's first point.
        public var edgeStart: [Int]
        public var junctionSeconds: Double?
        /// `[lat, lon]` pairs.
        public var coordinates: [[Double]]
        public var maneuvers: [Step]
        public var breakdown: [String: [Double]]?
    }

    public struct RequestRecord: Codable, Equatable, Sendable {
        public var originName: String, originLat: Double, originLon: Double
        public var destinationName: String, destinationID: String, destinationLat: Double, destinationLon: Double
        public var snappedOriginLat: Double?, snappedOriginLon: Double?, snappedDestinationLat: Double?, snappedDestinationLon: Double?
        public var extraMinutes: Int
        /// Only the Calmer means options that are not Normal.
        public var preferences: [String: String]
        public init(originName: String, originLat: Double, originLon: Double, destinationName: String, destinationID: String,
                    destinationLat: Double, destinationLon: Double, extraMinutes: Int, preferences: [String: String]) {
            self.originName = originName; self.originLat = originLat; self.originLon = originLon
            self.destinationName = destinationName; self.destinationID = destinationID
            self.destinationLat = destinationLat; self.destinationLon = destinationLon
            self.extraMinutes = extraMinutes; self.preferences = preferences
        }
    }

    public struct Header: Codable, Equatable, Sendable {
        public var kind = "header"
        public var schema = DriveLog.schema
        public var start: Double
        public var mode: TravelMode
        public var appVersion: String, appBuild: String
        public var dataVersion: String
        public var request: RequestRecord
        public var startedWith: String
        public var calmerOffered: Bool
        public var routes: [RouteRecord]
        public init(start: Date, mode: TravelMode, appVersion: String, appBuild: String, dataVersion: String, request: RequestRecord,
                    startedWith: String, calmerOffered: Bool, routes: [RouteRecord]) {
            self.start = Fix.ms(start); self.mode = mode; self.appVersion = appVersion; self.appBuild = appBuild; self.dataVersion = dataVersion
            self.request = request; self.startedWith = startedWith; self.calmerOffered = calmerOffered; self.routes = routes
        }
        public var startDate: Date { Date(timeIntervalSince1970: start) }
    }

    // MARK: Names

    private static func stamp(_ date: Date, _ format: String, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = format
        return f.string(from: date)
    }
    /// `trip-20231114T221320Z-drive.jsonl`: UTC, so names sort oldest first.
    public static func tripFileName(start: Date, mode: TravelMode) -> String {
        "trip-\(stamp(start, "yyyyMMdd'T'HHmmss'Z'", TimeZone(identifier: "UTC")!))-\(mode.rawValue).jsonl"
    }
    /// `use-2023-11-14.jsonl`: the day in the phone's time zone.
    public static func useFileName(day: Date, timeZone: TimeZone = .current) -> String { "use-\(stamp(day, "yyyy-MM-dd", timeZone)).jsonl" }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private func prepare() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            #if canImport(Darwin)
            var marked = folder, values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? marked.setResourceValues(values)
            #endif
        }
    }

    // MARK: Trips

    /// Starts a trip file with its header line. Nil, and nothing created, when `enabled` is false.
    public func startTrip(_ header: Header, enabled: Bool) throws -> TripWriter? {
        guard enabled else { return nil }
        try prepare()
        let url = folder.appendingPathComponent(Self.tripFileName(start: header.startDate, mode: header.mode))
        let writer = try TripWriter(url: url, start: header.startDate, header: header)
        enforceCap(keeping: url)
        return writer
    }

    /// Appends one line to today's app-use file. Does nothing, and creates no file, when `enabled` is false.
    public func appendUse(_ name: String, _ data: [String: Value] = [:], at: Date = Date(), enabled: Bool, timeZone: TimeZone = .current) {
        guard enabled, var line = try? Self.encoder.encode(Event(at: at, name: name, data: data)) else { return }
        line.append(0x0A)
        try? prepare()
        let url = folder.appendingPathComponent(Self.useFileName(day: at, timeZone: timeZone))
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Writes one trip, a line at a time.
    public final class TripWriter {
        public let url: URL
        public let start: Date
        public private(set) var fixCount = 0
        private var handle: FileHandle?
        private var finished = false

        init(url: URL, start: Date, header: Header) throws {
            self.url = url; self.start = start
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            write(header)
        }
        deinit { try? handle?.close() }

        private func write<T: Encodable>(_ value: T) {
            guard !finished, var line = try? DriveLog.encoder.encode(value) else { return }
            line.append(0x0A)
            try? handle?.write(contentsOf: line)
        }
        public func fix(_ fix: Fix) { fixCount += 1; write(fix) }
        public func event(_ name: String, at: Date = Date(), _ data: [String: Value] = [:]) { write(Event(at: at, name: name, data: data)) }

        /// Writes the end line and closes the file. A trip shorter than `minimumSeconds` is deleted. Returns whether the file was kept.
        @discardableResult
        public func finish(reason: String, at: Date = Date(), minimumSeconds: TimeInterval = DriveLog.minimumTripSeconds) -> Bool {
            guard !finished else { return FileManager.default.fileExists(atPath: url.path) }
            let seconds = at.timeIntervalSince(start)
            event("end", at: at, ["reason": .string(reason), "seconds": .number(Fix.round(seconds, 1)), "fixes": .number(Double(fixCount))])
            finished = true
            try? handle?.close(); handle = nil
            if seconds < minimumSeconds { try? FileManager.default.removeItem(at: url); return false }
            return true
        }
    }

    // MARK: Folder

    public struct Summary: Equatable, Sendable {
        public var trips: Int, bytes: Int
        public init(trips: Int, bytes: Int) { self.trips = trips; self.bytes = bytes }
    }

    private func files() -> [(url: URL, bytes: Int)] {
        let keys: [URLResourceKey] = [.fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "jsonl" }.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).fileSize) ?? 0) }
    }
    /// Every file in the folder, oldest trips first, then the daily files.
    public func allFiles() -> [URL] { files().map(\.url).sorted { $0.lastPathComponent < $1.lastPathComponent } }
    public func summary() -> Summary {
        let all = files()
        return Summary(trips: all.filter { $0.url.lastPathComponent.hasPrefix("trip-") }.count, bytes: all.reduce(0) { $0 + $1.bytes })
    }

    /// Deletes the oldest trips until the folder fits `maxBytes`. The trip being written (`keeping`) is never deleted. Returns how many went.
    @discardableResult
    public func enforceCap(maxBytes: Int = DriveLog.capBytes, keeping: URL? = nil) -> Int {
        let all = files()
        var total = all.reduce(0) { $0 + $1.bytes }
        var dropped = 0
        for file in all.filter({ $0.url.lastPathComponent.hasPrefix("trip-") }).sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent }) {
            if total <= maxBytes { break }
            if file.url.lastPathComponent == keeping?.lastPathComponent { continue }
            if (try? FileManager.default.removeItem(at: file.url)) != nil { total -= file.bytes; dropped += 1 }
        }
        return dropped
    }

    public func clear() { try? FileManager.default.removeItem(at: folder) }
}
