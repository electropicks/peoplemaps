import Foundation

/// A problem report for the alpha: one free-form note and what the app knew at the time, shared as a `.json` file
/// (Docs/REPORTS.md section 11). It reuses the 2.4 pieces that fit (`Report.Spoken`, `App`, `Device`, `Chosen`,
/// `ReportCell`, five-decimal points) but has no category, no ID minting and no server. The phone keeps the exact
/// fields; `fileData()` leaves them out unless `includeExact` is on.
public struct ProblemReport: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = 2
    public static let limit = 50
    /// The OpenStreetMap snapshot the bundled graph was built from (Data/provenance.json).
    public static let dataVersion = "osm-2026-10-11"

    public struct Point: Codable, Equatable, Sendable {
        public var lat: Double
        public var lon: Double
        public init(lat: Double, lon: Double) { self.lat = Report.fiveDecimals(lat); self.lon = Report.fiveDecimals(lon) }
    }

    /// An endpoint as in 2.2: the street corner it snapped to, and the exact point only with exact locations on.
    public struct Place: Codable, Equatable, Sendable {
        public var snapped: Point
        public var exact: Point?
        public init(snapped: Point, exact: Point?) { self.snapped = snapped; self.exact = exact }
    }

    public struct RouteInfo: Codable, Equatable, Sendable {
        public var kind: Report.Chosen
        public var minutes: Int
        public var seconds: Double
        public var meters: Double
        public var streets: [String]
        public var edgeIDs: [Int]
        public init(kind: Report.Chosen, minutes: Int, seconds: Double, meters: Double, streets: [String], edgeIDs: [Int]) {
            self.kind = kind; self.minutes = minutes; self.seconds = seconds; self.meters = meters; self.streets = streets; self.edgeIDs = edgeIDs
        }
    }

    /// A marked moment in guidance: where in the plan, and the last thing said. `location` is the GPS fix, exact only.
    public struct Moment: Codable, Equatable, Sendable {
        public var at: Date
        public var stepIndex: Int
        public var stepCount: Int
        public var instruction: String
        public var remainingMeters: Double
        public var remainingSeconds: Double
        /// `ReportCell.of` the position: a 550 m cell, always shared.
        public var cell: String?
        public var location: Point?
        public init(at: Date, stepIndex: Int, stepCount: Int, instruction: String, remainingMeters: Double, remainingSeconds: Double, cell: String?, location: Point?) {
            self.at = at; self.stepIndex = stepIndex; self.stepCount = stepCount; self.instruction = instruction
            self.remainingMeters = remainingMeters; self.remainingSeconds = remainingSeconds; self.cell = cell; self.location = location
        }
    }

    public var id: String
    public var createdAt: Date
    /// Empty until the user adds words; a marked moment is stored without any.
    public var note: String
    public var includeExact: Bool
    public var screen: String
    public var mode: TravelMode
    public var extraMinutes: Int
    public var origin: Place?
    public var destination: Place?
    public var routes: [RouteInfo]
    /// The route being guided, when the report comes from guidance.
    public var chosen: Report.Chosen?
    public var moment: Moment?
    public var spoken: [Report.Spoken]
    public var rerouteCount: Int?
    public var app: Report.App
    public var dataVersion: String
    public var device: Report.Device

    public init(id: String = UUID().uuidString, createdAt: Date = Date(), note: String = "", includeExact: Bool = false, screen: String,
                mode: TravelMode, extraMinutes: Int, origin: Place? = nil, destination: Place? = nil, routes: [RouteInfo] = [],
                chosen: Report.Chosen? = nil, moment: Moment? = nil, spoken: [Report.Spoken] = [], rerouteCount: Int? = nil,
                app: Report.App, dataVersion: String = ProblemReport.dataVersion, device: Report.Device) {
        self.id = id; self.createdAt = createdAt; self.note = note; self.includeExact = includeExact; self.screen = screen
        self.mode = mode; self.extraMinutes = extraMinutes; self.origin = origin; self.destination = destination; self.routes = routes
        self.chosen = chosen; self.moment = moment; self.spoken = spoken; self.rerouteCount = rerouteCount
        self.app = app; self.dataVersion = dataVersion; self.device = device
    }

    /// Whether the user has written anything.
    public var hasNote: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What would be shared: without exact locations, every exact point is dropped.
    public func shared() -> ProblemReport {
        guard !includeExact else { return self }
        var out = self
        out.origin?.exact = nil; out.destination?.exact = nil; out.moment?.location = nil
        return out
    }

    /// The bytes of the `.json` file, which the "What's included" view shows as text.
    public func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Envelope(schema: Self.schemaVersion, exactLocations: includeExact, report: shared()))
    }

    private struct Envelope: Encodable {
        var schema: Int
        var exactLocations: Bool
        var report: ProblemReport
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(schema, forKey: Key("schema")); try c.encode(exactLocations, forKey: Key("exactLocations"))
            try report.encode(to: encoder)
        }
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    /// `peoplemaps-2026-11-01-wrong-left-on-45th.json`: the local date and the first words of the note, or what it marks.
    public func fileName(calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: createdAt)
        let date = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return "peoplemaps-\(date)-\(Self.slug(hasNote ? note : (moment != nil ? "marked moment" : screen))).json"
    }

    /// Up to six lower-case ASCII words, joined by hyphens; "report" when nothing is left.
    public static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let words = folded.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.prefix(6).map { $0.lowercased() }
        return words.isEmpty ? "report" : String(words.joined(separator: "-").prefix(48))
    }
}

/// Reports on the phone, newest first, until swiped away. A `Codable` file written atomically like `SavedPlaces`.
public struct ProblemReports: Codable, Equatable, Sendable {
    public private(set) var reports: [ProblemReport] = []
    public init() {}

    /// Adds the report, or replaces the one with its ID. Past the limit the oldest goes.
    public mutating func save(_ report: ProblemReport) {
        if let i = reports.firstIndex(where: { $0.id == report.id }) { reports[i] = report; return }
        reports.insert(report, at: 0)
        if reports.count > ProblemReport.limit { reports.removeLast(reports.count - ProblemReport.limit) }
    }
    public mutating func remove(id: String) { reports.removeAll { $0.id == id } }
    public subscript(id: String) -> ProblemReport? { reports.first { $0.id == id } }

    public static func load(from url: URL) -> ProblemReports {
        guard let data = try? Data(contentsOf: url) else { return ProblemReports() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ProblemReports.self, from: data)) ?? ProblemReports()
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
