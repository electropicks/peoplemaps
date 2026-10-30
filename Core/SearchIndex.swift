import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Offline search over the bundled index of OpenStreetMap places and street addresses, built by
/// Scripts/build_search.py. Ranked by text match, then category weight (landmarks and parks over shops,
/// addresses last), then distance from a supplied point. Falls back to typo correction when nothing matches.
public final class SearchIndex: @unchecked Sendable {
    /// Entries in the index: named places plus addresses.
    public let count: Int
    /// "OpenStreetMap, Oct 2026": the source and date of the extract.
    public let source: String
    private let db: OpaquePointer
    private let lock = NSLock()
    /// The importer's per-mode graph nodes; ignored when the index was built against another graph.
    private let snapsMatchGraph: Bool
    private var vocabulary: [(term: String, docs: Int)]?
    private var last: (key: String, results: [Place])?

    /// The bundled index, inflated once into `directory` (Caches by default) and reused on later launches.
    public static func bundled(graph: StreetGraph? = nil, directory: URL? = nil) throws -> SearchIndex {
        guard let url = Bundle.module.url(forResource: "seattle-search.sqlite", withExtension: "gz") else { throw RoutingError.missingData }
        let folder = try directory ?? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try SearchIndex(gzipped: try Data(contentsOf: url), graphNodeCount: graph?.nodes.count, directory: folder)
    }

    public init(gzipped: Data, graphNodeCount: Int?, directory: URL) throws {
        // The gzip trailer's CRC-32 and size name the inflated file, so a new build never reuses a stale one.
        guard gzipped.count >= 18 else { throw RoutingError.missingData }
        let key = gzipped.suffix(8).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent("seattle-search-\(key).sqlite")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let sqlite = gzipped.gunzipped() else { throw RoutingError.missingData }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try sqlite.write(to: file, options: .atomic)
            for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix("seattle-search-") && old.lastPathComponent != file.lastPathComponent {
                try? FileManager.default.removeItem(at: old)
            }
        }
        var handle: OpaquePointer?
        let uri = "file:\(file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path)?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle); throw RoutingError.missingData
        }
        db = handle
        var meta: [String: String] = [:]
        Self.rows(db, "SELECT key, value FROM meta", []) { meta[Self.text($0, 0) ?? ""] = Self.text($0, 1) }
        var total = 0
        Self.rows(db, "SELECT count(*) FROM entries", []) { total = Int(sqlite3_column_int64($0, 0)) }
        guard meta["schemaVersion"] == "1", total > 0 else { sqlite3_close(db); throw RoutingError.missingData }
        count = total
        snapsMatchGraph = graphNodeCount.map { String($0) == meta["graphNodes"] } ?? false
        source = [meta["source"], Self.monthYear(meta["sourceDate"])].compactMap { $0 }.joined(separator: ", ")
    }

    deinit { sqlite3_close(db) }

    /// Lowercased, accents and apostrophes removed, "&" spelled "and", other punctuation to spaces.
    /// Must match `fold` in Scripts/build_search.py, which normalises the indexed text the same way.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .replacingOccurrences(of: "['’`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&", with: " and ")
        return folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).joined(separator: " ")
    }

    /// Up to `limit` matches for text typed so far. Every word is a prefix ("fre ave" finds "Fremont Avenue").
    /// A leading house number ("3400 fremont ave n", "3400 fremont #2") ranks that exact address first, or the
    /// nearest numbers on that street when the exact one isn't mapped.
    public func search(_ query: String, near: Coordinate? = nil, limit: Int = 60) -> [Place] {
        lock.lock(); defer { lock.unlock() }
        // Views ask again on every redraw while the text is unchanged, so the last answer is kept.
        let key = "\(query)|\(near?.lat ?? 0)|\(near?.lon ?? 0)|\(limit)"
        if let last, last.key == key { return last.results }
        let results = lookUp(query, near: near, limit: limit)
        last = (key, results)
        return results
    }

    private func lookUp(_ query: String, near: Coordinate?, limit: Int) -> [Place] {
        let (text, unit) = Self.splitUnit(query)
        var tokens = Self.normalize(text).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        var results = run(tokens, unit: unit, near: near, limit: limit)
        if results.isEmpty, let corrected = correct(tokens), corrected != tokens {
            tokens = corrected
            results = run(tokens, unit: unit, near: near, limit: limit)
        }
        return results
    }

    /// The indexed entry for an OSM ID ("relation/1047789"), which carries the newest address; nil when not indexed.
    public func place(id: String) -> Place? {
        lock.lock(); defer { lock.unlock() }
        var found: Place?
        Self.rows(db, "SELECT \(Self.columns) FROM entries WHERE osm = ?1 AND kind = 'place' LIMIT 1", [.text(id)]) { found = place($0) }
        return found
    }

    /// The place with its address from the index when it has none (graph places come from the routing extract,
    /// which has no addresses). Dropped pins and the current location are not indexed and come back unchanged.
    public func withAddress(_ place: Place) -> Place {
        guard place.address == nil, let address = self.place(id: place.id)?.address else { return place }
        var place = place; place.address = address; return place
    }

    /// The indexed street address nearest to `c` within `meters`, or nil. Labels a place the map has no address for
    /// ("Near 410 Terry Avenue North"), so it carries no snap nodes. At one spot, the building's own address wins
    /// over one of its units.
    public func nearestAddress(to c: Coordinate, within meters: Double = 40) -> Place? {
        lock.lock(); defer { lock.unlock() }
        // A box a little larger than the circle, then the exact distance.
        let dLat = meters / 111_000, dLon = meters / (111_000 * max(0.01, cos(c.lat * .pi / 180)))
        var best: (distance: Double, unit: Bool, place: Place)?
        Self.rows(db, """
            SELECT osm, name, lat, lon, unit IS NOT NULL FROM entries
            WHERE kind = 'address' AND lat BETWEEN ?1 AND ?2 AND lon BETWEEN ?3 AND ?4 ORDER BY id
            """, [.double(c.lat - dLat), .double(c.lat + dLat), .double(c.lon - dLon), .double(c.lon + dLon)]) { row in
            let found = Place(id: Self.text(row, 0) ?? "", name: Self.text(row, 1) ?? "", lat: sqlite3_column_double(row, 2),
                              lon: sqlite3_column_double(row, 3), category: "address", kind: .address, source: source)
            let distance = c.distance(to: found.coordinate), unit = sqlite3_column_int(row, 4) != 0
            guard distance <= meters else { return }
            if let best, (best.distance, best.unit ? 1 : 0) <= (distance, unit ? 1 : 0) { return }
            best = (distance, unit, found)
        }
        return best?.place
    }

    private func run(_ tokens: [String], unit: String?, near: Coordinate?, limit: Int) -> [Place] {
        let prefixes = tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
        let startsWith = "{name}: ^ \"\(tokens.joined(separator: " "))\"*"
        let inName = "{name alias}: (\(prefixes))"
        var number: String?, street = prefixes
        if tokens.count > 1, tokens[0].first!.isNumber, tokens[0].allSatisfy({ $0.isNumber || $0.isLetter }), tokens[0].count <= 6 {
            number = tokens[0]
            street = "{name alias}: (" + tokens.dropFirst().map { "\"\($0)\"*" }.joined(separator: " AND ") + ")"
        }
        var nearest: [Place] = []
        if let number, let n = Int(number.prefix(while: \.isNumber)) {
            var exact = false
            Self.rows(db, "SELECT 1 FROM entries WHERE number = ?1 COLLATE NOCASE AND id IN (SELECT rowid FROM fts WHERE fts MATCH ?2) LIMIT 1",
                      [.text(number), .text(street)]) { _ in exact = true }
            if !exact {
                Self.rows(db, """
                    SELECT \(Self.columns) FROM entries WHERE kind = 'address' AND number GLOB '[0-9]*'
                    AND id IN (SELECT rowid FROM fts WHERE fts MATCH ?1)
                    ORDER BY abs(CAST(number AS INTEGER) - ?2), unit IS NOT NULL, id LIMIT 3
                    """, [.text(street), .int(n)]) { nearest.append(place($0)) }
            }
        }
        var ranked: [Place] = []
        let k = near.map { pow(cos($0.lat * .pi / 180), 2) } ?? 0
        Self.rows(db, """
            SELECT \(Self.columns) FROM entries WHERE id IN (SELECT rowid FROM fts WHERE fts MATCH ?3)
            ORDER BY CASE
                WHEN ?4 IS NOT NULL AND number = ?4 COLLATE NOCASE AND id IN (SELECT rowid FROM fts WHERE fts MATCH ?5) THEN 0
                WHEN id IN (SELECT rowid FROM fts WHERE fts MATCH ?1) THEN 1
                WHEN id IN (SELECT rowid FROM fts WHERE fts MATCH ?2) THEN 2
                ELSE 3 END,
              ?6 IS NOT NULL AND unit IS NOT ?6, weight DESC, kind = 'address' AND unit IS NOT NULL,
              (lat - ?7) * (lat - ?7) + (lon - ?8) * (lon - ?8) * ?9, id
            LIMIT ?10
            """, [.text(startsWith), .text(inName), .text(prefixes), number.map { .text($0) } ?? .null, .text(street),
                  unit.map { .text($0) } ?? .null, .double(near?.lat ?? 0), .double(near?.lon ?? 0), .double(k), .int(limit)]) {
            ranked.append(place($0))
        }
        let ids = Set(nearest.map(\.id))
        return Array((nearest + ranked.filter { !ids.contains($0.id) }).prefix(limit))
    }

    // MARK: Typos

    /// Each word with no prefix match replaced by the closest indexed word (Damerau–Levenshtein, at most 1 edit
    /// for words up to 5 letters, else 2; the more common word wins a tie). Nil when no word could be fixed.
    private func correct(_ tokens: [String]) -> [String]? {
        if vocabulary == nil {
            var terms: [(String, Int)] = []
            Self.exec(db, "CREATE VIRTUAL TABLE IF NOT EXISTS temp.vocab USING fts5vocab(main, fts, row)")
            Self.rows(db, "SELECT term, doc FROM temp.vocab WHERE term GLOB '[a-z]*'", []) {
                terms.append((Self.text($0, 0) ?? "", Int(sqlite3_column_int64($0, 1))))
            }
            vocabulary = terms
        }
        guard let vocabulary, !vocabulary.isEmpty else { return nil }
        var changed = false
        let fixed = tokens.enumerated().map { index, token -> String in
            guard token.count >= 3, !token.first!.isNumber else { return token }
            var hit = false
            Self.rows(db, "SELECT 1 FROM fts WHERE fts MATCH ?1 LIMIT 1", [.text("\"\(token)\"*")]) { _ in hit = true }
            if hit { return token }
            let word = Array(token), budget = token.count <= 5 ? 1 : 2, last = index == tokens.count - 1
            var best: (distance: Int, docs: Int, term: String)?
            for (term, docs) in vocabulary where abs(term.count - word.count) <= budget || (last && term.count > word.count) {
                // The last word may still be half typed: compare it with the start of longer words.
                let chars = Array(term), candidate = last && chars.count > word.count ? Array(chars.prefix(word.count)) : chars
                let d = Self.editDistance(word, candidate, limit: budget)
                guard d <= budget else { continue }
                if best == nil || d < best!.distance || (d == best!.distance && docs > best!.docs) { best = (d, docs, String(candidate)) }
            }
            guard let best else { return token }
            changed = true
            return best.term
        }
        return changed ? fixed : nil
    }

    static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var previous2 = [Int](repeating: 0, count: b.count + 1), previous = Array(0...b.count), current = previous
        for i in 1...a.count {
            current[0] = i
            var rowMin = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { current[j] = min(current[j], previous2[j - 2] + 1) }
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count]
    }

    // MARK: Parsing and rows

    /// "3400 Fremont Ave N #2" or "... unit 2" → ("3400 Fremont Ave N", "2").
    static func splitUnit(_ query: String) -> (String, String?) {
        let pattern = #"(?:#|\b(?:unit|apt|apartment|suite|ste)\.?)\s*([A-Za-z0-9-]+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
              let whole = Range(match.range, in: query), let unit = Range(match.range(at: 1), in: query) else { return (query, nil) }
        return (String(query[..<whole.lowerBound]), String(query[unit]).uppercased())
    }

    private static let columns = "osm, kind, name, category, address, lat, lon, walk, bike, drive"

    private func place(_ row: OpaquePointer) -> Place {
        var snap: [TravelMode: Int] = [:]
        if snapsMatchGraph {
            for (column, mode) in [(7, TravelMode.walk), (8, .bike), (9, .drive)] where sqlite3_column_type(row, Int32(column)) != SQLITE_NULL {
                snap[mode] = Int(sqlite3_column_int64(row, Int32(column)))
            }
        }
        let kind = Place.Kind(rawValue: Self.text(row, 1) ?? "") ?? .place
        return Place(id: Self.text(row, 0) ?? "", name: Self.text(row, 2) ?? "", lat: sqlite3_column_double(row, 5),
                     lon: sqlite3_column_double(row, 6), category: Self.text(row, 3) ?? kind.rawValue, kind: kind,
                     address: Self.text(row, 4), source: source, snap: snap)
    }

    private enum Value { case text(String), int(Int), double(Double), null }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func rows(_ db: OpaquePointer, _ sql: String, _ values: [Value], _ body: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(statement, index, s, -1, transient)
            case .int(let n): sqlite3_bind_int64(statement, index, Int64(n))
            case .double(let d): sqlite3_bind_double(statement, index, d)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        while sqlite3_step(statement) == SQLITE_ROW { body(statement) }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    private static func monthYear(_ date: String?) -> String? {
        guard let parts = date?.split(separator: "-"), parts.count >= 2, let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(names[month - 1]) \(parts[0])"
    }
}
