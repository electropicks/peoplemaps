import Foundation

/// Five words for how calm a route is estimated to be, calmest first, left to right on the bar. Cutoffs and their
/// calibration: Docs/STRESS_MODEL.md, Calm score.
public enum CalmLevel: Int, CaseIterable, Sendable, Identifiable {
    case breezy, chill, meh, spicy, yikes
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .breezy: "Breezy"
        case .chill: "Chill"
        case .meh: "Meh"
        case .spicy: "Spicy"
        case .yikes: "Yikes"
        }
    }
    /// The lowest score in this level.
    public var cutoff: Int {
        switch self {
        case .breezy: 80
        case .chill: 60
        case .meh: 40
        case .spicy: 20
        case .yikes: 0
        }
    }
    public init(score: Int) { self = Self.allCases.first { score >= $0.cutoff } ?? .yikes }
}

/// An estimate from 0 to 100, higher is calmer. Built from the stress model, so it knows what the map knows and is
/// never a safety rating. A route's score depends on stress per minute of the trip, so a long drive isn't marked down
/// just for being long.
public struct CalmScore: Hashable, Sendable {
    public let value: Int
    public var level: CalmLevel { CalmLevel(score: value) }
    /// Where this score sits along the bar: 0 at the Breezy end, 1 at the Yikes end.
    public var barPosition: Double { Double(100 - value) / 100 }

    public init(value: Int) { self.value = min(100, max(0, value)) }

    /// `tripSeconds` is the same for every route in a comparison: the fastest route's time, so a slower route can't
    /// look calmer only because it takes longer. Very short trips count as 5 minutes, so one junction doesn't swamp them.
    public init(stress: Double, tripSeconds: Double, mode: TravelMode) {
        let perMinute = max(0, stress) / max(tripSeconds / 60, 5)
        let relative = perMinute / Self.scale(mode)
        self.init(value: Int((100 / (1 + relative * relative)).rounded()))
    }

    /// Stress per minute that scores 50. Each mode has its own stress factors and its own scale.
    static func scale(_ mode: TravelMode) -> Double {
        switch mode {
        case .drive: 50
        case .bike: 65
        case .walk: 12
        }
    }
}

extension Route {
    /// "16–19 min": a little under the estimate and a bit more over it, since queues and waiting for gaps aren't in it.
    public var timeRange: String {
        let (low, high) = timeBounds
        return low == high ? "\(low) min" : "\(low)–\(high) min"
    }
    /// "16 to 19 minutes"
    public var spokenTimeRange: String {
        let (low, high) = timeBounds
        return low == high ? "\(low) \(low == 1 ? "minute" : "minutes")" : "\(low) to \(high) minutes"
    }
    private var timeBounds: (Int, Int) {
        let low = max(1, Int((metrics.seconds * 0.95 / 60).rounded()))
        return (low, max(low, Int((metrics.seconds * 1.12 / 60).rounded()), minutes))
    }
}

extension RouteComparison {
    public var fastestCalm: CalmScore { calm(fastest) }
    public var calmerCalm: CalmScore? { calmer.map(calm) }
    private func calm(_ route: Route) -> CalmScore {
        CalmScore(stress: route.metrics.stress, tripSeconds: fastest.metrics.seconds, mode: request.mode)
    }

    /// Fastest to calmer: "Yikes → Chill", with the scores when the word doesn't change: "Chill, 62 → 71". One word with no calmer route.
    public var calmChange: String { calmChange(arrow: "→") }
    /// As `calmChange`, for VoiceOver.
    public var spokenCalmChange: String { calmChange(arrow: "to") }
    private func calmChange(arrow: String) -> String {
        let from = fastestCalm
        guard let to = calmerCalm else { return from.level.title }
        return from.level == to.level ? "\(to.level.title), \(from.value) \(arrow) \(to.value)" : "\(from.level.title) \(arrow) \(to.level.title)"
    }

    /// What the calmer route mostly saves: "mostly fewer unsignalled lefts", or the two biggest when none is the majority.
    public var mainGain: String? {
        guard let calmer else { return nil }
        let f = fastest.metrics.breakdown, c = calmer.metrics.breakdown
        let gains = Factor.allCases.filter { !$0.isUnknown && $0.isNoticeable(abs(f[$0].amount - c[$0].amount)) }
            .map { (factor: $0, saved: f[$0].cost - c[$0].cost) }.filter { $0.saved > 0 }.sorted { $0.saved > $1.saved }
        guard let top = gains.first else { return "fewer small hassles" }
        let total = gains.reduce(0) { $0 + $1.saved }
        if top.saved >= total * 0.5 || gains.count == 1 { return "mostly \(top.factor.gain)" }
        return "\(top.factor.gain) and \(gains[1].factor.gain)"
    }

    /// The line under the time: "Yikes → Chill, mostly fewer unsignalled lefts", or what the router found: "Meh, already the calmest we found".
    public var calmSummary: String { summary(calmChange) }
    /// As `calmSummary`, for VoiceOver.
    public var spokenCalmSummary: String { summary(spokenCalmChange) }
    private func summary(_ change: String) -> String {
        if let mainGain { return "\(change), \(mainGain)" }
        return "\(change), \(noCalmer.title.prefix(1).lowercased())\(noCalmer.title.dropFirst())"
    }

    /// The route Start defaults to, as a headline: "Calmer: 16–19 min, 6.2 mi", or "16–19 min, 6.2 mi" when it's the only one.
    public var startHeadline: String {
        guard let calmer else { return "\(fastest.timeRange), \(fastest.distance)" }
        return "Calmer: \(calmer.timeRange), \(calmer.distance)"
    }
}

extension Factor {
    /// The short form of what a calmer route has less of. Only for the summary; `describe` carries the counts.
    var gain: String {
        switch self {
        case .unsignalledLeft: "fewer unsignalled lefts"
        case .unsignalledCrossing: "fewer unsignalled crossings"
        case .unsignalledRight: "fewer unsignalled rights"
        case .leftAtSignal: "fewer lefts at signals"
        case .turn: "fewer turns"
        case .stopSign: "fewer stop signs"
        case .allWayStop: "fewer all-way stops"
        case .signal: "fewer signals"
        case .yield: "fewer yields"
        case .stopAndGo: "less stop-and-go"
        case .complexJunction: "fewer 5-way junctions"
        case .hillStop: "fewer hill stops"
        case .freewayEntry: "fewer freeway entries"
        case .shortFreewayHop: "fewer short freeway hops"
        case .movableBridge: "fewer drawbridges"
        case .cutThrough: "fewer side-street shortcuts"
        case .bikeRouteGap: "fewer bike route gaps"
        case .unmarkedCrossing: "fewer unmarked crossings"
        case .markedCrossing: "fewer crossings without a signal"
        case .signalCrossing: "fewer signalled crossings"
        case .sideStreetCrossing: "fewer side-street crossings"
        case .stairs: "fewer steps"
        case .residential: "fewer residential streets"
        case .narrowWithParking: "fewer narrow streets"
        case .quietStreet: "less riding on shared streets"
        case .arterialRiding: "less riding on arterials"
        case .busyArterialRiding: "less riding in busy traffic"
        case .roughSurface: "less rough surface"
        case .steepDescent: "less steep downhill"
        case .besideTraffic: "less walking beside traffic"
        case .noSidewalk: "less walking without a sidewalk"
        case .climb: "less climbing"
        case .unknownSurface, .unknownSidewalk: "fewer unknowns"
        }
    }
}
