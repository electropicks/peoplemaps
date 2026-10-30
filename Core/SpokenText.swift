import Foundation

/// Turns on-screen instruction text ("Turn left onto N 45th St") into text a speech synthesizer reads well
/// ("Turn left onto North 45th Street"). Pure text; the banner keeps the short form.
public enum SpokenText {
    public static func normalize(_ text: String) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        for i in tokens.indices {
            let (core, tail) = split(tokens[i])
            let hasNext = i + 1 < tokens.count
            if let route = route(core) { tokens[i] = route + tail }
            else if let word = directionals[core] { tokens[i] = word + tail }
            else if let word = names[core] { tokens[i] = word + tail }
            else if let title = titles[core], hasNext, i == 0 || introducers.contains(tokens[i - 1].lowercased()) { tokens[i] = title + tail }
            else if i > 0, let word = streetTypes[core] { tokens[i] = word + tail }
        }
        return distances(tokens.joined(separator: " "))
    }

    private static func split(_ token: String) -> (core: String, tail: String) {
        var core = token, tail = ""
        while let last = core.last, ",.;:!".contains(last), core.count > 1 {
            if last != "." { tail = String(last) + tail }   // "St." loses its dot: the expanded word needs none
            core.removeLast()
        }
        return (core, tail)
    }

    private static let directionals = [
        "N": "North", "S": "South", "E": "East", "W": "West",
        "NE": "Northeast", "NW": "Northwest", "SE": "Southeast", "SW": "Southwest",
    ]

    private static let introducers: Set<String> = ["onto", "on", "at", "to", "cross", "toward", "towards"]

    /// Street types, expanded wherever they follow the first word.
    private static let streetTypes = [
        "St": "Street", "Ave": "Avenue", "Av": "Avenue", "Pl": "Place", "Blvd": "Boulevard", "Dr": "Drive",
        "Ct": "Court", "Ln": "Lane", "Pkwy": "Parkway", "Hwy": "Highway", "Ter": "Terrace", "Terr": "Terrace",
        "Rd": "Road", "Cir": "Circle", "Sq": "Square", "Trl": "Trail", "Expy": "Expressway", "Fwy": "Freeway",
        "Aly": "Alley", "Bvd": "Boulevard", "Brg": "Bridge", "Pt": "Point",
    ]

    /// Abbreviations safe in any position.
    private static let names = [
        "Mt": "Mount", "Ft": "Fort", "Jr": "Junior", "Sr": "Senior", "Rte": "Route",
    ]

    /// Abbreviations that mean something else at the start of a name ("onto St Marks Pl", "onto Dr Jose Rizal Bridge").
    private static let titles = ["St": "Saint", "Dr": "Doctor"]

    /// "SR 99" / "SR-99" / "WA-520" → "State Route 99"; "I-5" → "I 5"; "US-2" → "U S 2".
    private static func route(_ token: String) -> String? {
        let parts = token.split(whereSeparator: { $0 == "-" }).map(String.init)
        guard parts.count == 2, parts[1].allSatisfy(\.isNumber), !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "I": return "I \(parts[1])"
        case "SR", "WA": return "State Route \(parts[1])"
        case "US": return "U S \(parts[1])"
        default: return nil
        }
    }

    private static func distances(_ text: String) -> String {
        var out = text
        // "SR 99" and "US 2" written with a space.
        out = out.replacing(/\b(SR|WA) (\d+)/) { "State Route \($0.2)" }
        out = out.replacing(/\bUS (\d+)/) { "U S \($0.1)" }
        out = out.replacing(/\bI-(\d+)/) { "I \($0.1)" }
        out = out.replacing(/\b(\d+)\.(\d) miles?\b/) { match in
            let whole = Int(match.1) ?? 0, tenth = Int(match.2) ?? 0
            switch (whole, tenth) {
            case (0, 2...3): return "a quarter mile"
            case (0, 4...6): return "half a mile"
            case (0, 7...8): return "three quarters of a mile"
            case (0, 9): return "almost a mile"
            case (_, 0): return whole == 1 ? "1 mile" : "\(whole) miles"
            case (1, 4...6): return "a mile and a half"
            default: return "\(whole).\(tenth) miles"
            }
        }
        return out
    }
}
