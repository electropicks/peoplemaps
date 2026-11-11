import Foundation

/// What a link from another maps app says about one place. These are hints for our own search (`SearchIndex.match`):
/// they are never shown as a result or stored (Docs/SEARCH.md, "Shared links").
public struct SharedStop: Equatable, Sendable {
    public var name: String?
    public var address: String?
    public var coordinate: Coordinate?
    /// False when the coordinate is only where the other app's map was centred, not the place itself.
    public var exact = true
    public init(name: String? = nil, address: String? = nil, coordinate: Coordinate? = nil, exact: Bool = true) {
        self.name = name; self.address = address; self.coordinate = coordinate; self.exact = exact
    }
    var isEmpty: Bool { name == nil && address == nil && coordinate == nil }
}

/// A link or text shared or pasted from another maps app, read without any network.
public enum SharedLink: Equatable, Sendable {
    case place(SharedStop)
    /// The stops only: the other app's path, time and distance are not in the link and are never used. `origin` is
    /// nil for "from where I am".
    case route(origin: SharedStop?, stops: [SharedStop], mode: TravelMode?)
    /// A short link that hides the place until its redirect is read (`SharedLinkExpander`). `text` is whatever else
    /// came with it, for a plain search when offline.
    case short(URL, text: String?)
    /// A maps link in a form we don't read.
    case unreadable(text: String?)

    /// The text a `peoplemaps://share?text=…` URL carries: what the Share Extension (Share/ShareViewController.swift)
    /// was handed, link and words together. Any app or web page can open such a URL, so the text gets no more trust
    /// than a paste.
    public static func sharedText(opened url: URL) -> String? {
        guard url.scheme?.lowercased() == "peoplemaps", url.host?.lowercased() == "share",
              let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "text" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(4_000))
    }

    /// Hosts whose short links may be expanded. Nothing else is ever contacted.
    static let shortHosts: Set<String> = ["maps.apple", "maps.app.goo.gl", "goo.gl", "g.co"]

    /// Nil for anything that is not a maps link or a bare coordinate pair, so ordinary search text passes through.
    public static func parse(_ input: String) -> SharedLink? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let pair = coordinate(trimmed, loose: true) { return .place(SharedStop(coordinate: pair)) }
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:(?:https?|maps|comgooglemaps)://|geo:)[^\s<>"]+"#, options: .caseInsensitive) else { return nil }
        let ranges = regex.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)).compactMap { Range($0.range, in: trimmed) }
        guard !ranges.isEmpty else { return nil }
        var rest = trimmed
        for range in ranges.reversed() { rest.removeSubrange(range) }
        let words = rest.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        // A share can carry more than one link (Safari adds the site's own): the first that says where wins.
        var unreadable: SharedLink?
        for range in ranges {
            // Punctuation after a link in a sentence is not part of it; a closing bracket is, when the link opened one.
            var link = String(trimmed[range])
            while let last = link.last, ".,;".contains(last) || (last == ")" && !link.contains("(")) { link.removeLast() }
            switch parse(link: link, text: words.isEmpty ? nil : words) {
            case .unreadable?: unreadable = unreadable ?? .unreadable(text: words.isEmpty ? nil : words)
            case let found?: return found
            case nil: continue
            }
        }
        return unreadable
    }

    static func parse(link: String, text: String?) -> SharedLink? {
        if link.lowercased().hasPrefix("geo:") { return geo(link) }
        guard let parts = URLComponents(string: link) ?? URLComponents(string: link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""),
              let scheme = parts.scheme?.lowercased() else { return nil }
        let host = (parts.host ?? "").lowercased().replacingOccurrences(of: #"^(www|m)\."#, with: "", options: .regularExpression)
        let query = Query(parts)
        switch (scheme, host) {
        case ("https", _) where shortHosts.contains(host) && (host != "goo.gl" && host != "g.co" || parts.path.hasPrefix("/maps")):
            return parts.url.map { .short($0, text: text) }
        case ("maps", _), (_, "maps.apple.com"):
            return apple(path: parts.path, query) ?? .unreadable(text: text)
        case ("comgooglemaps", _):
            return google(path: "", query, fragment: nil) ?? .unreadable(text: text)
        case (_, "maps.google.com"), (_, "google.com") where host == "maps.google.com" || parts.path.hasPrefix("/maps"):
            return google(path: parts.percentEncodedPath, query, fragment: parts.fragment) ?? .unreadable(text: text)
        case (_, "waze.com"), (_, "ul.waze.com"):
            return waze(query) ?? .unreadable(text: text)
        case (_, "openstreetmap.org"), (_, "osm.org"):
            return osm(query, fragment: parts.fragment) ?? .unreadable(text: text)
        default:
            return nil
        }
    }

    // MARK: Apple Maps (developer.apple.com/documentation/mapkit/unified-map-urls, and the older ll/q/daddr form)

    private static func apple(path: String, _ q: Query) -> SharedLink? {
        if path.hasPrefix("/directions") || q["daddr"] != nil || q["destination"] != nil {
            let stops = (q.all("waypoint") + [q["destination"] ?? q["daddr"]].compactMap { $0 }).compactMap(stop)
            guard !stops.isEmpty else { return nil }
            let mode: TravelMode? = switch q["mode"] ?? q["dirflg"] { case "driving", "d": .drive; case "walking", "w": .walk; case "cycling", "c", "b": .bike; default: nil }
            return .route(origin: (q["source"] ?? q["saddr"]).flatMap(stop), stops: stops, mode: mode)
        }
        var found = SharedStop(name: q["name"] ?? q["q"], address: q["address"], coordinate: (q["coordinate"] ?? q["ll"]).flatMap { coordinate($0) })
        // `q` alone may be a coordinate pair or an address rather than a name.
        if found.coordinate == nil, let name = found.name, let pair = coordinate(name) { found.coordinate = pair; found.name = nil }
        return found.isEmpty ? nil : .place(found)
    }

    // MARK: Google Maps (developers.google.com/maps/documentation/urls for `api=1`; the path forms are observed, not documented)

    private static func google(path: String, _ q: Query, fragment: String?) -> SharedLink? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let view = segments.first { $0.hasPrefix("@") }.flatMap { coordinate(String($0.dropFirst()).split(separator: ",").prefix(2).joined(separator: ",")) }
        let data = segments.first { $0.hasPrefix("data=") } ?? ""
        let mode: TravelMode? = switch q["travelmode"] ?? q["directionsmode"] ?? q["dirflg"] {
            case "driving", "d": .drive; case "walking", "w": .walk; case "bicycling", "b": .bike; default: nil }
        if let at = segments.firstIndex(of: "dir") {
            if q["destination"] != nil || q["daddr"] != nil {
                let stops = ((q["waypoints"]?.split(separator: "|").map(String.init) ?? []) + [q["destination"] ?? q["daddr"]].compactMap { $0 }).compactMap(stop)
                return stops.isEmpty ? nil : .route(origin: (q["origin"] ?? q["saddr"]).flatMap(stop), stops: stops, mode: mode)
            }
            let named = segments[(at + 1)...].prefix { !$0.hasPrefix("@") && !$0.hasPrefix("data=") }.map(unescape)
            guard named.count >= 2 else { return nil }
            let stops = named.dropFirst().compactMap(stop)
            return stops.isEmpty ? nil : .route(origin: stop(named[0]), stops: Array(stops), mode: mode)
        }
        if let daddr = q["daddr"], let end = stop(daddr) { return .route(origin: q["saddr"].flatMap(stop), stops: [end], mode: mode) }
        // The pin itself is `!3d<lat>!4d<lon>`; `@lat,lon` is only where the map was centred.
        let pin = data.range(of: #"!3d(-?\d+(\.\d+)?)!4d(-?\d+(\.\d+)?)"#, options: .regularExpression)
            .flatMap { coordinate(data[$0].dropFirst(3).replacingOccurrences(of: "!4d", with: ",")) }
        if let at = segments.firstIndex(where: { $0 == "place" || $0 == "search" }), segments.count > at + 1, !segments[at + 1].isEmpty,
           var found = stop(unescape(segments[at + 1])) {
            if found.coordinate == nil { found.coordinate = pin ?? (segments[at] == "place" ? view : nil); found.exact = pin != nil || found.coordinate == nil }
            return .place(found)
        }
        if let text = q["query"] ?? q["q"] ?? q["center"], var found = stop(text) {
            if found.coordinate == nil, let ll = q["ll"].flatMap({ coordinate($0) }) { found.coordinate = ll; found.exact = false }
            return .place(found)
        }
        if let pin { return .place(SharedStop(coordinate: pin)) }
        if let view = view ?? q["ll"].flatMap({ coordinate($0) }) { return .place(SharedStop(coordinate: view, exact: false)) }
        return nil
    }

    // MARK: Waze, OpenStreetMap, geo:

    private static func waze(_ q: Query) -> SharedLink? {
        let point = (q["ll"] ?? q["latlng"] ?? q["to"].map { $0.replacingOccurrences(of: "ll.", with: "") }).flatMap { coordinate($0) }
        let found = SharedStop(name: point == nil ? q["q"] : nil, coordinate: point)
        return found.isEmpty ? nil : .place(found)
    }

    private static func osm(_ q: Query, fragment: String?) -> SharedLink? {
        if let lat = q["mlat"].flatMap(Double.init), let lon = q["mlon"].flatMap(Double.init), let pair = valid(lat, lon) { return .place(SharedStop(coordinate: pair)) }
        // `#map=zoom/lat/lon` is the view, not a marker.
        let view = (fragment ?? "").split(separator: "&").first { $0.hasPrefix("map=") }?.dropFirst(4).split(separator: "/") ?? []
        if view.count == 3, let lat = Double(view[1]), let lon = Double(view[2]), let pair = valid(lat, lon) { return .place(SharedStop(coordinate: pair, exact: false)) }
        return nil
    }

    /// RFC 5870, plus the common `?q=lat,lon(Label)` and `?q=address` extensions. `geo:0,0?q=…` means "no point, search this".
    private static func geo(_ link: String) -> SharedLink? {
        let body = link.dropFirst(4), split = body.split(separator: "?", maxSplits: 1)
        let point = split.first.flatMap { coordinate($0.split(separator: ";")[0].split(separator: ",").prefix(2).joined(separator: ",")) }
        var found = SharedStop(coordinate: point.flatMap { $0.lat == 0 && $0.lon == 0 ? nil : $0 })
        if split.count == 2, let q = Query(URLComponents(string: "geo://x?\(split[1])"))["q"] {
            let label = q.range(of: #"\(([^)]*)\)\s*$"#, options: .regularExpression)
            let head = label.map { String(q[..<$0.lowerBound]) } ?? q
            if let pair = coordinate(head) { found.coordinate = pair; found.name = label.map { String(q[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "() ")) } }
            else { found.name = q }
        }
        if found.name?.isEmpty == true { found.name = nil }
        return found.isEmpty ? .unreadable(text: nil) : .place(found)
    }

    // MARK: Pieces

    /// A stop written as either a coordinate pair or text. "Current Location"-style placeholders come back nil.
    private static func stop(_ text: String) -> SharedStop? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !["current location", "my location", "current+location"].contains(text.lowercased()) else { return nil }
        if let pair = coordinate(text) { return SharedStop(coordinate: pair) }
        return SharedStop(name: text)
    }

    private static func unescape(_ segment: String) -> String {
        (segment.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? segment).trimmingCharacters(in: .whitespaces)
    }

    private static func valid(_ lat: Double, _ lon: Double) -> Coordinate? {
        abs(lat) <= 90 && abs(lon) <= 180 ? Coordinate(lat: lat, lon: lon) : nil
    }

    /// "47.6205,-122.3493". `loose` also takes what a person pastes: spaces, degree signs and N/S/E/W
    /// ("47.6205° N, 122.3493° W"), but then needs a decimal point in both, so "3400, 2" stays a search.
    static func coordinate(_ text: some StringProtocol, loose: Bool = false) -> Coordinate? {
        let number = #"([-+]?\d{1,3}(?:\.\d+)?)"#
        let pattern = loose ? "^\\s*\(number)\\s*°?\\s*([NSns])?\\s*[, ]\\s*\(number)\\s*°?\\s*([EWew])?\\s*$" : "^\\s*\(number)\\s*,\\s*\(number)\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = String(text)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? { Range(match.range(at: i), in: text).map { String(text[$0]) } }
        guard let first = group(1), let second = group(loose ? 3 : 2), var lat = Double(first), var lon = Double(second) else { return nil }
        if loose {
            guard first.contains("."), second.contains(".") else { return nil }
            if group(2)?.lowercased() == "s" { lat = -abs(lat) }
            if group(4)?.lowercased() == "w" { lon = -abs(lon) }
        }
        return valid(lat, lon)
    }

    /// Query items by lower-cased name, with `+` read as a space the way these links write it.
    private struct Query {
        let items: [(String, String)]
        init(_ parts: URLComponents?) {
            items = (parts?.percentEncodedQueryItems ?? []).compactMap { item in
                guard let value = item.value?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
                return (item.name.lowercased(), value)
            }
        }
        subscript(name: String) -> String? { items.first { $0.0 == name }?.1 }
        func all(_ name: String) -> [String] { items.filter { $0.0 == name }.map(\.1) }
    }
}
