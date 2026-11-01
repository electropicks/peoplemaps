import Foundation

// Problem reports, Docs/REPORTS.md. A snapshot is what the phone records on Flag (2.1); a report is the snapshot plus
// what the user adds at home, as it is sent (2.4). The public/exact split mirrors Backend/src/validate.ts.

public enum ReportCategory: String, Codable, CaseIterable, Sendable {
    case wrongInstruction = "wrong_instruction", calmerBadChoice = "calmer_bad_choice", mapData = "map_data"
    case voiceTiming = "voice_timing", other
}

/// The JSON the app sends, `POST /v1/reports` (2.4). Encode it with `ReportEncoder`, which keeps the 2.4 key order and
/// writes the bytes JavaScript's `JSON.stringify` would.
public struct Report: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let noteLimit = 280

    public enum Chosen: String, Codable, Sendable { case calmer, fastest }

    /// A snapped street intersection: a graph node's coordinates to five decimals and its OSM ID.
    public struct Intersection: Codable, Equatable, Sendable {
        public var lat: Double
        public var lon: Double
        public var osmNode: Int64
        public init(lat: Double, lon: Double, osmNode: Int64) {
            self.lat = Report.fiveDecimals(lat); self.lon = Report.fiveDecimals(lon); self.osmNode = osmNode
        }
    }

    /// An endpoint as sent (2.2): the snapped intersection, or the exact point with its snapped form riding along.
    public enum Endpoint: Codable, Equatable, Sendable {
        case intersection(Intersection)
        case exact(lat: Double, lon: Double, placeID: String?, snapped: Intersection)

        public var snappedForm: Endpoint {
            if case let .exact(_, _, _, snapped) = self { return .intersection(snapped) }
            return self
        }
        var isExact: Bool { if case .exact = self { true } else { false } }

        enum CodingKeys: String, CodingKey { case kind, lat, lon, osmNode, placeID, snapped }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let lat = try c.decode(Double.self, forKey: .lat), lon = try c.decode(Double.self, forKey: .lon)
            switch try c.decode(String.self, forKey: .kind) {
            case "intersection": self = .intersection(try Intersection(from: decoder))
            case "exact": self = .exact(lat: lat, lon: lon, placeID: try c.decodeIfPresent(String.self, forKey: .placeID), snapped: try c.decode(Intersection.self, forKey: .snapped))
            default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown endpoint kind.")
            }
        }
        public func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }
    }

    public struct Request: Codable, Equatable, Sendable {
        public var mode: TravelMode
        public var extraMinutes: Int
        public var origin: Endpoint?
        public var destination: Endpoint?
        public var rerouted: Bool
        public init(mode: TravelMode, extraMinutes: Int, origin: Endpoint?, destination: Endpoint?, rerouted: Bool) {
            self.mode = mode; self.extraMinutes = extraMinutes
            self.origin = origin; self.destination = destination; self.rerouted = rerouted
        }
    }

    public struct Route: Codable, Equatable, Sendable {
        public var dataVersion: String
        public var edgeIDs: [Int]
        public var wayIDs: [Int64]
        public var hash: String
        public var meters: Double
        public var seconds: Double
        public var stress: Double
        public var alternativeHash: String?
        public init(dataVersion: String, edgeIDs: [Int], wayIDs: [Int64], hash: String, meters: Double, seconds: Double, stress: Double, alternativeHash: String?) {
            self.dataVersion = dataVersion; self.edgeIDs = edgeIDs; self.wayIDs = wayIDs; self.hash = hash
            self.meters = meters; self.seconds = seconds; self.stress = stress; self.alternativeHash = alternativeHash
        }
    }

    public struct Position: Codable, Equatable, Sendable {
        public var stepIndex: Int
        public var shownStepIndex: Int
        public var distanceToManeuver: Double
        public var remainingMeters: Double
        public var remainingSeconds: Double
        /// `ReportCell.of(lat:lon:)` of the route point at flag time.
        public var cell: String
        public init(stepIndex: Int, shownStepIndex: Int, distanceToManeuver: Double, remainingMeters: Double, remainingSeconds: Double, cell: String) {
            self.stepIndex = stepIndex; self.shownStepIndex = shownStepIndex; self.distanceToManeuver = distanceToManeuver
            self.remainingMeters = remainingMeters; self.remainingSeconds = remainingSeconds; self.cell = cell
        }
    }

    /// The GPS fix at flag time; sent only with exact locations on.
    public struct Location: Codable, Equatable, Sendable {
        public var lat: Double
        public var lon: Double
        public var accuracy: Double
        public var course: Double?
        public init(lat: Double, lon: Double, accuracy: Double, course: Double?) {
            self.lat = Report.fiveDecimals(lat); self.lon = Report.fiveDecimals(lon); self.accuracy = accuracy; self.course = course
        }
    }

    public struct Spoken: Codable, Equatable, Sendable {
        public var text: String
        public var secondsBefore: Double
        public init(text: String, secondsBefore: Double) { self.text = text; self.secondsBefore = secondsBefore }
    }

    public struct Nav: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case guiding, rerouting, paused, arrived }
        public enum VoiceQuality: String, Codable, Sendable { case standard = "default", enhanced, premium }
        public enum Units: String, Codable, Sendable { case mi, km }
        public var state: State
        public var rerouteCount: Int
        public var muted: Bool
        public var voiceQuality: VoiceQuality
        public var units: Units
        public init(state: State, rerouteCount: Int, muted: Bool, voiceQuality: VoiceQuality, units: Units) {
            self.state = state; self.rerouteCount = rerouteCount; self.muted = muted; self.voiceQuality = voiceQuality; self.units = units
        }
    }

    public struct App: Codable, Equatable, Sendable {
        public var version: String
        public var build: String
        public init(version: String, build: String) { self.version = version; self.build = build }
    }

    public struct Device: Codable, Equatable, Sendable {
        public var model: String
        public var os: String
        public init(model: String, os: String) { self.model = model; self.os = os }
    }

    /// The exact part the Worker stores apart (`exact_json`), present only with exact locations on.
    public struct ExactPart: Equatable, Sendable {
        public var origin: Endpoint?
        public var destination: Endpoint?
        public var location: Location?
    }

    public var schema = Report.schemaVersion
    public var id: String
    /// The hour, UTC: `2026-10-31T19:00:00Z`.
    public var flaggedAt: String
    public var category: ReportCategory
    public var note: String?
    public var exactLocations: Bool
    public var request: Request
    public var chosen: Chosen
    public var route: Route
    public var position: Position
    public var location: Location?
    public var spoken: [Spoken]
    public var nav: Nav
    public var app: App
    public var device: Device

    public func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }

    /// The public body (snapped endpoints, `location` null) and the exact part, as `splitExact` in validate.ts does.
    public func splitExact() -> (public: Report, exact: ExactPart?) {
        var pub = self
        pub.request.origin = request.origin?.snappedForm
        pub.request.destination = request.destination?.snappedForm
        pub.location = nil
        let exactOnly = { (e: Endpoint?) in e?.isExact == true ? e : nil }
        let exact = exactLocations ? ExactPart(origin: exactOnly(request.origin), destination: exactOnly(request.destination), location: location) : nil
        return (pub, exact)
    }

    /// About a metre; more is noise (2.2).
    public static func fiveDecimals(_ v: Double) -> Double { (v * 100_000).rounded() / 100_000 }

    /// Rounded down to the hour, UTC (2.1).
    public static func hour(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600))
    }
}

/// The 550 m grid of 5.2, as `Backend/src/cells.ts` computes it: rows 0 to 49, columns 0 to 26.
public enum ReportCell {
    public static func of(lat: Double, lon: Double) -> String {
        let row = min(49, max(0, Int(((lat - 47.49) / 0.005).rounded(.down))))
        let col = min(26, max(0, Int(((lon + 122.44) / 0.0075).rounded(.down))))
        return "r\(row)c\(col)"
    }
}

/// An endpoint as the phone keeps it (2.2): the exact point and, when a junction was within 400 m, its snapped form.
public struct ReportEndpoint: Codable, Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public var placeID: String?
    /// Nil when no intersection was near; the endpoint is then sent as null.
    public var snapped: Report.Intersection?

    public init(lat: Double, lon: Double, placeID: String? = nil, snapped: Report.Intersection?) {
        self.lat = Report.fiveDecimals(lat); self.lon = Report.fiveDecimals(lon); self.placeID = placeID; self.snapped = snapped
    }

    public init(place: Place, snapped: Report.Intersection?) {
        self.init(lat: place.lat, lon: place.lon, placeID: Self.publicPlaceID(place), snapped: snapped)
    }

    /// Only a public named place keeps its ID; addresses, pins and the user's position never do. The ID must also be an
    /// OSM reference the Worker accepts (`node|way|relation/<n>`), which rules out `current-location` and `pin/…`.
    public static func publicPlaceID(_ place: Place) -> String? {
        guard place.kind == .place, !["address", "dropped pin", "current location"].contains(place.category) else { return nil }
        let parts = place.id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, ["node", "way", "relation"].contains(parts[0]), (1...19).contains(parts[1].count),
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return place.id
    }

    /// The form that is sent: null without a snap, the snapped intersection by default, the exact point when asked.
    /// The place ID names the exact place, so it only goes with the exact point (2.2).
    public func sent(exact: Bool) -> Report.Endpoint? {
        guard let snapped else { return nil }
        return exact ? .exact(lat: lat, lon: lon, placeID: placeID, snapped: snapped) : .intersection(snapped)
    }
}

/// A flagged moment as stored on the phone (2.1, 3): the exact fields, what the user adds at home, and the receipt.
public struct ReportSnapshot: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case flagged, sending, sent, withdrawn }

    public struct Request: Codable, Equatable, Sendable {
        public var mode: TravelMode
        public var extraMinutes: Int
        public var origin: ReportEndpoint?
        public var destination: ReportEndpoint?
        public var rerouted: Bool
        public init(mode: TravelMode, extraMinutes: Int, origin: ReportEndpoint?, destination: ReportEndpoint?, rerouted: Bool) {
            self.mode = mode; self.extraMinutes = extraMinutes
            self.origin = origin; self.destination = destination; self.rerouted = rerouted
        }
    }

    public enum BuildError: Error, Equatable, Sendable { case noCategory, noteTooLong }

    /// The idempotency key; a new one only when the user edits a report after a send attempt and sends again (4.2).
    public var id: String
    /// Exact on the phone; sent as the hour.
    public var flaggedAt: Date
    public var request: Request
    public var chosen: Report.Chosen
    public var route: Report.Route
    public var position: Report.Position
    public var location: Report.Location?
    public var spoken: [Report.Spoken]
    public var nav: Report.Nav
    public var app: Report.App
    public var device: Report.Device

    public var status: Status = .flagged
    public var category: ReportCategory?
    public var note: String?
    public var exactLocations = false
    public var originRemoved = false
    public var destinationRemoved = false
    /// A send was tried with the fields above; editing them afterwards gives the report a new ID.
    public var attempted = false
    /// `ReportsError.summary` of the last failed send, for the list.
    public var lastError: String?
    public var sentAt: Date?
    public var serverID: String?
    /// When the server deletes it (4.2); the receipt's `expiresAt`.
    public var expiresAt: String?
    /// The public install ID it was sent under, never the token. Nil on a copy stored before this field existed, which is
    /// never counted as being under the current ID (4.4).
    public var sentInstallID: String?

    public init(id: String = UUID().uuidString, flaggedAt: Date, request: Request, chosen: Report.Chosen, route: Report.Route,
                position: Report.Position, location: Report.Location?, spoken: [Report.Spoken], nav: Report.Nav,
                app: Report.App, device: Report.Device) {
        self.id = id; self.flaggedAt = flaggedAt; self.request = request; self.chosen = chosen; self.route = route
        self.position = position; self.location = location; self.spoken = spoken; self.nav = nav; self.app = app; self.device = device
    }

    /// The report exactly as it would be sent; the review screen and Export show these bytes (3).
    public func report() throws -> Report {
        guard let category else { throw BuildError.noCategory }
        let note = (note?.isEmpty ?? true) ? nil : note
        if let note, note.unicodeScalars.count > Report.noteLimit { throw BuildError.noteTooLong }
        return Report(
            id: id, flaggedAt: Report.hour(flaggedAt), category: category, note: note, exactLocations: exactLocations,
            request: .init(mode: request.mode, extraMinutes: request.extraMinutes,
                           origin: originRemoved ? nil : request.origin?.sent(exact: exactLocations),
                           destination: destinationRemoved ? nil : request.destination?.sent(exact: exactLocations),
                           rerouted: request.rerouted),
            chosen: chosen, route: route, position: position, location: exactLocations ? location : nil,
            spoken: spoken, nav: nav, app: app, device: device)
    }

    /// The last three things the voice said, newest last, with the destination's name replaced (2.1). `said` is in the
    /// order spoken; the name is matched as given and as `SpokenText.normalize` reads it.
    public static func spoken(_ said: [(text: String, at: Date)], flaggedAt: Date, destinationName: String?) -> [Report.Spoken] {
        let names = destinationName.map { [$0, SpokenText.normalize($0)].filter { !$0.isEmpty }.sorted { $0.count > $1.count } } ?? []
        return said.suffix(3).map { entry in
            let text = names.reduce(entry.text) { $0.replacingOccurrences(of: $1, with: "your destination") }
            return Report.Spoken(text: text, secondsBefore: max(0, flaggedAt.timeIntervalSince(entry.at)).rounded())
        }
    }

    var composition: [String?] {
        [category?.rawValue, note, String(exactLocations), String(originRemoved), String(destinationRemoved)]
    }
}

/// The 4.2 and 4.3 answer for one report.
public struct ReportReceipt: Codable, Equatable, Sendable {
    public var id: String
    public var receivedAt: String
    public var expiresAt: String
    /// Only in `GET /v1/reports` answers.
    public var category: ReportCategory?
    public init(id: String, receivedAt: String, expiresAt: String, category: ReportCategory? = nil) {
        self.id = id; self.receivedAt = receivedAt; self.expiresAt = expiresAt; self.category = category
    }
}

/// Flagged moments on the phone (3): a `Codable` array, oldest first, written atomically like `SavedPlaces`.
public struct ReportStore: Codable, Equatable, Sendable {
    public static let limit = 50
    /// A second flag this soon after the last one updates it instead of adding one (8.3).
    public static let updateWindow: TimeInterval = 5

    public enum AddResult: Equatable, Sendable {
        case added, updated
        /// The list says "An older unsent moment was removed to make room".
        case addedRemovingUnsent
    }

    public private(set) var snapshots: [ReportSnapshot]

    public init(snapshots: [ReportSnapshot] = []) { self.snapshots = snapshots }
    public init(from decoder: Decoder) throws { snapshots = try [ReportSnapshot](from: decoder) }
    public func encode(to encoder: Encoder) throws { try snapshots.encode(to: encoder) }

    public subscript(id: String) -> ReportSnapshot? { snapshots.first { $0.id == id } }

    /// Moments not yet sent, for the count at home.
    public var unsentCount: Int { snapshots.filter { $0.status == .flagged || $0.status == .sending }.count }
    /// Sent reports, the count "Delete my reports" shows (3).
    /// Sent copies under `installID`, the count "Delete my reports" shows and withdraws (4.4).
    public func sentCount(installID: String) -> Int { snapshots.filter { $0.status == .sent && $0.sentInstallID == installID }.count }
    /// Sent copies the current ID can't delete: sent under an earlier ID, or before the ID was recorded.
    public func sentUnderEarlierID(than installID: String) -> Int { snapshots.filter { $0.status == .sent && $0.sentInstallID != installID }.count }

    public mutating func add(_ snapshot: ReportSnapshot) -> AddResult {
        if let last = snapshots.indices.last, snapshots[last].status == .flagged, snapshots[last].category == nil,
           snapshot.flaggedAt.timeIntervalSince(snapshots[last].flaggedAt) < Self.updateWindow {
            var updated = snapshot
            updated.id = snapshots[last].id
            snapshots[last] = updated
            return .updated
        }
        var result = AddResult.added
        if snapshots.count >= Self.limit {
            if let i = snapshots.firstIndex(where: { $0.status == .sent || $0.status == .withdrawn }) {
                snapshots.remove(at: i)
            } else if let i = snapshots.firstIndex(where: { $0.status == .flagged }) {
                snapshots.remove(at: i)
                result = .addedRemovingUnsent
            }
        }
        snapshots.append(snapshot)
        return result
    }

    public mutating func remove(id: String) { snapshots.removeAll { $0.id == id } }
    public mutating func removeAll() { snapshots.removeAll() }

    /// Review and Send: sets the fields and `sending`, and returns the body to send. Fails without touching the row.
    public mutating func beginSend(id: String, category: ReportCategory, note: String?, exactLocations: Bool,
                                   originRemoved: Bool = false, destinationRemoved: Bool = false) throws -> Report {
        guard let i = snapshots.firstIndex(where: { $0.id == id }), snapshots[i].status == .flagged else { throw ReportStoreError.notSendable }
        var s = snapshots[i]
        let before = s.composition
        s.category = category; s.note = note; s.exactLocations = exactLocations
        s.originRemoved = originRemoved; s.destinationRemoved = destinationRemoved
        if s.attempted && s.composition != before { s.id = UUID().uuidString }
        let report = try s.report()
        s.status = .sending; s.attempted = true; s.lastError = nil
        snapshots[i] = s
        return report
    }

    /// Back to `flagged` with the fields kept and the error for the list (3).
    public mutating func sendFailed(id: String, error: String) {
        update(id) { $0.status = .flagged; $0.lastError = error }
    }

    public mutating func sent(id: String, receipt: ReportReceipt, installID: String, at date: Date) {
        update(id) {
            $0.status = .sent; $0.sentAt = date; $0.serverID = receipt.id; $0.lastError = nil; $0.expiresAt = receipt.expiresAt
            $0.sentInstallID = installID
        }
    }

    /// "Check status": updates every local sent row the answer names (3).
    public mutating func apply(_ receipts: [ReportReceipt]) {
        for r in receipts {
            for i in snapshots.indices where snapshots[i].status == .sent && (snapshots[i].serverID ?? snapshots[i].id) == r.id {
                snapshots[i].expiresAt = r.expiresAt
            }
        }
    }

    /// After a server-side delete; the rows stay until the user removes them (3).
    public mutating func withdraw(id: String) { update(id) { if $0.status == .sent { $0.status = .withdrawn } } }
    /// After a `204` for `installID`: only copies sent under it. Copies under an earlier ID are still on the server and
    /// stay `sent`. Returns how many were withdrawn.
    @discardableResult
    public mutating func withdrawAllSent(installID: String) -> Int {
        var n = 0
        for i in snapshots.indices where snapshots[i].status == .sent && snapshots[i].sentInstallID == installID {
            snapshots[i].status = .withdrawn; n += 1
        }
        return n
    }

    private mutating func update(_ id: String, _ change: (inout ReportSnapshot) -> Void) {
        if let i = snapshots.firstIndex(where: { $0.id == id }) { change(&snapshots[i]) }
    }

    /// Reads the file; a missing or unreadable one starts empty. A send cut off by the app quitting reads as failed.
    public static func load(from url: URL) -> ReportStore {
        guard let data = try? Data(contentsOf: url), var store = try? JSONDecoder().decode(ReportStore.self, from: data) else { return ReportStore() }
        for i in store.snapshots.indices where store.snapshots[i].status == .sending {
            store.snapshots[i].status = .flagged
            store.snapshots[i].lastError = "interrupted"
        }
        return store
    }

    /// Writes atomically and keeps the folder out of backups, since it holds exact coordinates (3).
    public func save(to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #if canImport(Darwin)
        var marked = folder, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try marked.setResourceValues(values)
        #endif
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

public enum ReportStoreError: Error, Equatable, Sendable { case notSendable }

// MARK: - JSON

/// A JSON value with ordered keys. `ReportEncoder` writes it byte for byte as JavaScript's `JSON.stringify` does, so the
/// body the app sends and the Worker's `public_json` and `exact_json` can be compared exactly (Docs/REPORTS.md 10, 18).
public indirect enum ReportJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case number(Double)
    case string(String)
    case array([ReportJSON])
    case object([(String, ReportJSON)])

    public static func == (a: ReportJSON, b: ReportJSON) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case let (.bool(x), .bool(y)): x == y
        case let (.int(x), .int(y)): x == y
        case let (.number(x), .number(y)): x == y
        case let (.string(x), .string(y)): x == y
        case let (.array(x), .array(y)): x == y
        case let (.object(x), .object(y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Objects read from JSON get their keys sorted, since the decoder does not keep their order.
    public init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: Key.self) {
            self = .object(try c.allKeys.sorted { $0.stringValue < $1.stringValue }.map { ($0.stringValue, try c.decode(ReportJSON.self, forKey: $0)) })
            return
        }
        if var c = try? decoder.unkeyedContainer() {
            var items: [ReportJSON] = []
            while !c.isAtEnd { items.append(try c.decode(ReportJSON.self)) }
            self = .array(items)
            return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        case let .bool(v): var c = encoder.singleValueContainer(); try c.encode(v)
        case let .int(v): var c = encoder.singleValueContainer(); try c.encode(v)
        case let .number(v): var c = encoder.singleValueContainer(); try c.encode(v)
        case let .string(v): var c = encoder.singleValueContainer(); try c.encode(v)
        case let .array(items): var c = encoder.unkeyedContainer(); for item in items { try c.encode(item) }
        case let .object(members):
            var c = encoder.container(keyedBy: Key.self)
            for (k, v) in members { try c.encode(v, forKey: Key(stringValue: k)) }
        }
    }
}

/// The report encoder: the 2.4 key order, no whitespace, numbers and strings as `JSON.stringify` writes them.
public enum ReportEncoder {
    public static func data(_ report: Report) -> Data { Data(string(report.json).utf8) }
    public static func string(_ value: ReportJSON) -> String { var out = ""; write(value, to: &out, indent: nil, depth: 0); return out }
    /// `JSON.stringify(value, null, 2)`, for the review screen.
    public static func pretty(_ value: ReportJSON) -> String { var out = ""; write(value, to: &out, indent: "  ", depth: 0); return out }

    private static func write(_ value: ReportJSON, to out: inout String, indent: String?, depth: Int) {
        func newline(_ d: Int) { if let indent { out += "\n" + String(repeating: indent, count: d) } }
        switch value {
        case .null: out += "null"
        case let .bool(v): out += v ? "true" : "false"
        case let .int(v): out += String(v)
        case let .number(v): out += number(v)
        case let .string(v): quote(v, to: &out)
        case let .array(items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                newline(depth + 1); write(item, to: &out, indent: indent, depth: depth + 1)
            }
            newline(depth); out += "]"
        case let .object(members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{"
            for (i, (k, v)) in members.enumerated() {
                if i > 0 { out += "," }
                newline(depth + 1); quote(k, to: &out); out += indent == nil ? ":" : ": "
                write(v, to: &out, indent: indent, depth: depth + 1)
            }
            newline(depth); out += "}"
        }
    }

    private static func quote(_ s: String, to out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += "\\u" + String(repeating: "0", count: 4 - String(u.value, radix: 16).count) + String(u.value, radix: 16)
            default: out.unicodeScalars.append(u)
            }
        }
        out += "\""
    }

    /// ECMAScript `Number::toString` over Swift's shortest round-trip digits.
    static func number(_ v: Double) -> String {
        precondition(v.isFinite, "JSON has no NaN or infinity")
        if v == 0 { return "0" }
        let text = v.magnitude.description
        let parts = text.split(separator: "e")
        let exp = parts.count > 1 ? Int(parts[1])! : 0
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        var digits = Array(mantissa[0] + (mantissa.count > 1 ? mantissa[1] : ""))
        var n = mantissa[0].count + exp
        while digits.first == "0" { digits.removeFirst(); n -= 1 }
        while digits.last == "0" { digits.removeLast() }
        let k = digits.count, d = String(digits)
        let body: String
        if k <= n && n <= 21 { body = d + String(repeating: "0", count: n - k) }
        else if 0 < n && n <= 21 { body = String(digits[..<n]) + "." + String(digits[n...]) }
        else if -6 < n && n <= 0 { body = "0." + String(repeating: "0", count: -n) + d }
        else {
            let e = n - 1, sign = e < 0 ? "-" : "+"
            body = (k == 1 ? d : String(digits[0]) + "." + String(digits[1...])) + "e" + sign + String(abs(e))
        }
        return (v < 0 ? "-" : "") + body
    }
}

private extension ReportJSON {
    static func optional(_ s: String?) -> ReportJSON { s.map(ReportJSON.string) ?? .null }
}

extension Report {
    public var json: ReportJSON {
        .object([
            ("schema", .int(Int64(schema))), ("id", .string(id)), ("flaggedAt", .string(flaggedAt)),
            ("category", .string(category.rawValue)), ("note", .optional(note)), ("exactLocations", .bool(exactLocations)),
            ("request", request.json), ("chosen", .string(chosen.rawValue)), ("route", route.json), ("position", position.json),
            ("location", location?.json ?? .null), ("spoken", .array(spoken.map(\.json))), ("nav", nav.json),
            ("app", .object([("version", .string(app.version)), ("build", .string(app.build))])),
            ("device", .object([("model", .string(device.model)), ("os", .string(device.os))])),
        ])
    }
}

extension Report.Intersection {
    var members: [(String, ReportJSON)] { [("lat", .number(lat)), ("lon", .number(lon)), ("osmNode", .int(osmNode))] }
}

extension Report.Endpoint {
    public var json: ReportJSON {
        switch self {
        case let .intersection(node): return .object([("kind", .string("intersection"))] + node.members)
        case let .exact(lat, lon, placeID, snapped):
            let place: [(String, ReportJSON)] = placeID.map { [("placeID", .string($0))] } ?? []
            return .object([("kind", .string("exact")), ("lat", .number(lat)), ("lon", .number(lon))] + place + [("snapped", .object(snapped.members))])
        }
    }
}

extension Report.Request {
    var json: ReportJSON {
        .object([("mode", .string(mode.rawValue)), ("extraMinutes", .int(Int64(extraMinutes))), ("preferences", .null),
                 ("origin", origin?.json ?? .null), ("destination", destination?.json ?? .null), ("rerouted", .bool(rerouted))])
    }
}

extension Report.Route {
    var json: ReportJSON {
        .object([("dataVersion", .string(dataVersion)), ("edgeIDs", .array(edgeIDs.map { .int(Int64($0)) })),
                 ("wayIDs", .array(wayIDs.map(ReportJSON.int))), ("hash", .string(hash)), ("meters", .number(meters)),
                 ("seconds", .number(seconds)), ("stress", .number(stress)), ("alternativeHash", .optional(alternativeHash))])
    }
}

extension Report.Position {
    var json: ReportJSON {
        .object([("stepIndex", .int(Int64(stepIndex))), ("shownStepIndex", .int(Int64(shownStepIndex))),
                 ("distanceToManeuver", .number(distanceToManeuver)), ("remainingMeters", .number(remainingMeters)),
                 ("remainingSeconds", .number(remainingSeconds)), ("cell", .string(cell))])
    }
}

extension Report.Location {
    var json: ReportJSON {
        .object([("lat", .number(lat)), ("lon", .number(lon)), ("accuracy", .number(accuracy)), ("course", course.map(ReportJSON.number) ?? .null)])
    }
}

extension Report.Spoken {
    var json: ReportJSON { .object([("text", .string(text)), ("secondsBefore", .number(secondsBefore))]) }
}

extension Report.Nav {
    var json: ReportJSON {
        .object([("state", .string(state.rawValue)), ("rerouteCount", .int(Int64(rerouteCount))), ("muted", .bool(muted)),
                 ("voiceQuality", .string(voiceQuality.rawValue)), ("units", .string(units.rawValue))])
    }
}

extension Report.ExactPart {
    public var json: ReportJSON {
        .object([("origin", origin?.json ?? .null), ("destination", destination?.json ?? .null), ("location", location?.json ?? .null)])
    }
}
