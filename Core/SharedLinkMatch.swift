import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a shared stop turned into. Only `place` and `pin` are things to show, and both are our own records, except
/// that a pin sits at the shared point (Docs/SEARCH.md, "Shared links").
public enum SharedMatch: Equatable, Sendable {
    /// One of our places or addresses that is plainly the shared one.
    case place(Place)
    /// Nothing plain: search for `query` around `near`. `pin` is the shared point itself, offered beside the results.
    case candidates(query: String, near: Coordinate?, pin: Place?)
    /// We have nothing by that name near the shared point: a pin there, named from our data like a dropped pin.
    case pin(Place)
    /// The shared point is outside the map area.
    case outside
}

extension SearchIndex {
    /// A name counts as the shared place within this distance of an exact shared point.
    static let sharedNameReach = 75.0
    /// An address with the same number and street counts within this, since geocoders put the point on the street,
    /// the entrance or the roof.
    static let sharedAddressReach = 150.0
    /// Beyond this from the shared point a search result is some other place.
    static let sharedCandidateReach = 300.0

    /// Our own record for a stop from another app, the nearest thing to it, or a pin. `covers` is the map area;
    /// `here` ranks results when the stop has no point of its own.
    public func match(_ stop: SharedStop, covers: (Coordinate) -> Bool, near here: Coordinate? = nil) -> SharedMatch {
        if let point = stop.coordinate, !covers(point) { return .outside }
        let exact = stop.exact ? stop.coordinate : nil
        let pin = exact.map { droppedPin(at: $0) }
        let anchor = stop.coordinate ?? here
        // The street line of the address, then the name; a name like "Space Needle, 400 Broad St" also on its own.
        var queries: [String] = []
        for text in [stop.address.map(Self.firstPart), stop.name, stop.name.map(Self.firstPart)].compactMap({ $0 }) where !text.isEmpty && !queries.contains(text) { queries.append(text) }
        var fallback: String?
        for query in queries {
            let results = search(query, near: anchor, limit: 20)
            let near = results.filter { r in exact.map { $0.distance(to: r.coordinate) <= Self.sharedCandidateReach } ?? true }
            if let hit = near.first(where: { r in r.kind == .address && Self.sameAddress(query, r.name) && (exact.map { $0.distance(to: r.coordinate) <= Self.sharedAddressReach } ?? true) }) {
                return .place(hit)
            }
            if let exact, let hit = near.filter({ $0.kind == .place && Self.sameName(query, $0.name) && exact.distance(to: $0.coordinate) <= Self.sharedNameReach })
                .min(by: { exact.distance(to: $0.coordinate) < exact.distance(to: $1.coordinate) }) {
                return .place(hit)
            }
            if fallback == nil, !near.isEmpty { fallback = query }
        }
        // The other app's name is often longer than ours ("Broadcast Coffee Roasters"), which a search for every word misses.
        if let exact, let name = stop.name.map(Self.firstPart) {
            let words = name.split(separator: " ")
            for count in [2, 1] where words.count > count && words.prefix(count).joined().count >= 4 {
                let hits = search(words.prefix(count).joined(separator: " "), near: exact, limit: 20)
                    .filter { $0.kind == .place && Self.sameName(name, $0.name) && exact.distance(to: $0.coordinate) <= Self.sharedNameReach }
                if let hit = hits.min(by: { exact.distance(to: $0.coordinate) < exact.distance(to: $1.coordinate) }) { return .place(hit) }
            }
        }
        if let fallback { return .candidates(query: fallback, near: anchor, pin: pin) }
        if let pin { return .pin(pin) }
        if let point = stop.coordinate, queries.isEmpty { return .pin(droppedPin(at: point)) }
        return .candidates(query: queries.first ?? "", near: anchor, pin: nil)
    }

    static func firstPart(_ text: String) -> String {
        String(text.split(whereSeparator: { $0 == "," || $0.isNewline }).first ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// "400 E Pine St" and "400 East Pine Street": the same house number and the same words once the usual street
    /// abbreviations are spelled out.
    static func sameAddress(_ hint: String, _ name: String) -> Bool {
        func words(_ text: String) -> [String] { normalize(text).split(separator: " ").map { streetWords[String($0)] ?? String($0) } }
        let a = words(hint), b = words(name)
        return a.count >= 2 && a == b && a[0].first?.isNumber == true
    }

    static let streetWords = ["n": "north", "s": "south", "e": "east", "w": "west", "ne": "northeast", "nw": "northwest", "se": "southeast",
                              "sw": "southwest", "st": "street", "ave": "avenue", "av": "avenue", "blvd": "boulevard", "dr": "drive", "rd": "road",
                              "pl": "place", "ct": "court", "ln": "lane", "pkwy": "parkway", "ter": "terrace", "hwy": "highway", "cir": "circle",
                              "sq": "square", "aly": "alley"]

    /// The same words, or every word of the shorter name in the longer ("Kelley-Ross Pharmacy" in "Kelley-Ross Capitol Hill Pharmacy").
    static func sameName(_ hint: String, _ name: String) -> Bool {
        let a = Set(normalize(hint).split(separator: " ")), b = Set(normalize(name).split(separator: " "))
        return !a.isEmpty && !b.isEmpty && (a.isSubset(of: b) || b.isSubset(of: a))
    }
}

/// Reads where a short maps link points, by asking its host and reading the redirect. It never loads a page, never
/// follows a redirect itself, and only ever contacts `SharedLink.shortHosts` (Docs/PRIVACY.md).
public struct SharedLinkExpander: Sendable {
    /// The `Location` a request to the URL redirects to, or nil.
    public typealias Hop = @Sendable (URL) async -> URL?
    private let hop: Hop
    public init(hop: @escaping Hop = SharedLinkExpander.redirect) { self.hop = hop }

    /// The place or route behind a `.short` link, or `.unreadable` when offline or when it leads somewhere we don't read.
    public func expand(_ url: URL, text: String? = nil) async -> SharedLink {
        var url = url
        for _ in 0..<3 {
            guard case .short = SharedLink.parse(link: url.absoluteString, text: nil), let next = await hop(url) else { break }
            switch SharedLink.parse(link: next.absoluteString, text: text) {
            case let .short(further, _): url = further
            case let found?: return found
            case nil: return .unreadable(text: text)
            }
        }
        return .unreadable(text: text)
    }

    /// One request with no cookies, cache or identifier, answered by the redirect alone.
    public static let redirect: Hop = { url in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0"]
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            session.dataTask(with: URLRequest(url: url)) { _, response, _ in
                let http = response as? HTTPURLResponse
                let location = (300..<400).contains(http?.statusCode ?? 0) ? http?.value(forHTTPHeaderField: "Location") : nil
                done.resume(returning: location.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL })
            }.resume()
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
