import Foundation

/// One thing the app did, kept in memory for problem reports (Docs/REPORTS.md section 11). It holds no coordinates,
/// no street or place names, no search text and no notes: a message is a string literal, `detail` is a type or state
/// name, and `fields` are rounded numbers under a fixed set of names.
public struct AppEvent: Codable, Equatable, Sendable {
    public enum Category: String, Codable, Sendable { case route, navigation, map, search, data, error }

    public var at: Date
    public var category: Category
    public var message: String
    /// An error type, a travel mode or a state name; nil when there is none.
    public var detail: String?
    public var fields: [String: Double]

    public init(at: Date, category: Category, message: String, detail: String? = nil, fields: [String: Double] = [:]) {
        self.at = at; self.category = category; self.message = message; self.detail = detail; self.fields = fields
    }

    private enum Key: String, CodingKey { case at, category, message, detail, fields }

    /// Times keep their milliseconds, which the report's plain ISO 8601 dates would drop.
    private static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    private static func parse(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let text = try c.decode(String.self, forKey: .at)
        guard let date = Self.parse(text) else { throw DecodingError.dataCorruptedError(forKey: .at, in: c, debugDescription: "Not a date: \(text)") }
        at = date
        category = try c.decode(Category.self, forKey: .category)
        message = try c.decode(String.self, forKey: .message)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        fields = try c.decodeIfPresent([String: Double].self, forKey: .fields) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(Self.format(at), forKey: .at)
        try c.encode(category, forKey: .category)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(detail, forKey: .detail)
        if !fields.isEmpty { try c.encode(fields, forKey: .fields) }
    }
}

/// A short, thread-safe buffer of recent app events: the last `capacity` events no older than `window`, kept in memory
/// only and never written to disk. A report copies `snapshot()` when it is created or a moment is marked. A crash or
/// a quit loses the buffer.
public final class AppEvents: @unchecked Sendable {
    public static let shared = AppEvents()
    public static let capacity = 200
    public static let window: TimeInterval = 600
    public static let burst: TimeInterval = 2

    /// The only field names an event may carry. Anything else is dropped, so a coordinate cannot ride along as "lat".
    public static let fieldNames: Set<String> = ["ms", "count", "candidates", "results", "zoom", "animated", "reroutes", "steps", "level"]

    private let lock = NSLock()
    private let limit: Int
    private let maxAge: TimeInterval
    private let clock: @Sendable () -> Date
    private var ring: [AppEvent?]
    private var head = 0, count = 0

    public init(capacity: Int = AppEvents.capacity, window: TimeInterval = AppEvents.window, clock: @escaping @Sendable () -> Date = { Date() }) {
        limit = max(1, capacity); maxAge = window; self.clock = clock
        ring = Array(repeating: nil, count: max(1, capacity))
    }

    /// Adds one event. `message` must be a literal, so text a person typed or a name from the map cannot reach it.
    /// `error` and `mode` are recorded by type and raw value only. With `coalesce`, an event that repeats the previous
    /// one's category and message within `burst` seconds replaces it and adds one to its `count`, so a camera that moves
    /// every second, or a redraw asking the same question again, takes one line, not a hundred.
    public func log(_ category: AppEvent.Category, _ message: StaticString, error: Error? = nil, mode: TravelMode? = nil, state: StaticString? = nil,
                    coalesce: Bool = false, _ fields: KeyValuePairs<String, Double> = [:]) {
        let detail = error.map { Self.typeName($0) } ?? mode?.rawValue ?? state.map { "\($0)" }
        var clean: [String: Double] = [:]
        for (key, value) in fields where Self.fieldNames.contains(key) && value.isFinite { clean[key] = (value * 10).rounded() / 10 }
        append(AppEvent(at: clock(), category: category, message: "\(message)", detail: detail, fields: clean), coalesce: coalesce)
    }

    /// The type of an error, never its text, which can name a street or a file.
    static func typeName(_ error: Error) -> String {
        let name = String(describing: type(of: error))
        let safe = name.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == ".") }
        return String(String.UnicodeScalarView(safe).prefix(60))
    }

    func append(_ event: AppEvent, coalesce: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if coalesce, count > 0, let last = ring[(head + count - 1) % limit], last.category == event.category, last.message == event.message,
           event.at.timeIntervalSince(last.at) < Self.burst {
            var merged = event
            merged.fields["count"] = (last.fields["count"] ?? 1) + 1
            ring[(head + count - 1) % limit] = merged; return
        }
        if count == limit { ring[head] = nil; head = (head + 1) % limit; count -= 1 }
        ring[(head + count) % limit] = event; count += 1
    }

    /// Oldest first; events older than the window are left out.
    public func snapshot() -> [AppEvent] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = clock().addingTimeInterval(-maxAge)
        return (0..<count).compactMap { ring[(head + $0) % limit] }.filter { $0.at >= cutoff }
    }

    /// Empties the buffer (tests).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        ring = Array(repeating: nil, count: limit); head = 0; count = 0
    }

    /// Runs `body` and logs how long it took, in milliseconds.
    public func timed<T>(_ category: AppEvent.Category, _ message: StaticString, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try body()
        log(category, message, ["ms": Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6])
        return result
    }
}
