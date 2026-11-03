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

    public init(value: Int) { self.value = min(100, max(0, value)) }

    /// `tripSeconds` is the same for every route in a comparison: the fastest route's time, so a slower route can't
    /// look calmer only because it takes longer. Very short trips count as 5 minutes, so one junction doesn't swamp them.
    /// Driving `freewaySeconds` of that trip on a freeway counts half: freeway minutes carry almost no stress, so a long
    /// freeway run would otherwise dilute the rate and make a trip with busy ends read calmer than it is. Display only:
    /// the router never reads the score.
    public init(stress: Double, tripSeconds: Double, freewaySeconds: Double = 0, mode: TravelMode) {
        let counted = tripSeconds - Self.freewayWeight * min(max(0, freewaySeconds), tripSeconds)
        let perMinute = max(0, stress) / max(counted / 60, 5)
        let relative = perMinute / Self.scale(mode)
        self.init(value: Int((100 / (1 + relative * relative)).rounded()))
    }

    /// How much of a freeway minute leaves the denominator.
    static let freewayWeight = 0.5

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
        CalmScore(stress: route.metrics.stress, tripSeconds: fastest.metrics.seconds, freewaySeconds: fastestFreewaySeconds, mode: request.mode)
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

    /// True when the person's Calmer means settings picked a route that avoids what they asked to avoid but has more model
    /// stress overall than the fastest. The route is then described by what it avoids, never as calmer overall.
    public var tradesStress: Bool {
        guard let calmer, !request.preferences.isDefault(in: request.mode) else { return false }
        return calmer.metrics.stress > fastest.metrics.stress
    }

    /// What the calmer route mostly saves: "mostly fewer unsignalled lefts", or the two biggest when none is the majority.
    public var mainGain: String? {
        guard calmer != nil else { return nil }
        guard let top = gains.first else { return "fewer small hassles" }
        let total = gains.reduce(0) { $0 + $1.saved }
        if top.saved >= total * 0.5 || gains.count == 1 { return "mostly \(top.factor.gain)" }
        return "\(top.factor.gain) and \(gains[1].factor.gain)"
    }

    /// What the calmer route saves that's big enough to notice, biggest first.
    private var gains: [(factor: Factor, saved: Double)] {
        guard let calmer else { return [] }
        let f = fastest.metrics.breakdown, c = calmer.metrics.breakdown
        let scale = FactorScale(request.preferences, mode: request.mode)
        return Factor.allCases.filter { !$0.isUnknown && $0.isNoticeable(abs(f[$0].amount - c[$0].amount)) }
            .map { (factor: $0, saved: (f[$0].cost - c[$0].cost) * (scale?[$0] ?? 1)) }.filter { $0.saved > 0 }.sorted { $0.saved > $1.saved }
    }

    /// The line under the time: "Yikes → Chill, mostly fewer unsignalled lefts", or what the router found: "Meh, already the calmest we found".
    public var calmSummary: String { summary(calmChange) }
    /// As `calmSummary`, for VoiceOver.
    public var spokenCalmSummary: String { summary(spokenCalmChange) }
    private func summary(_ change: String) -> String {
        if tradesStress, let mainGain { return "Avoids \(mainGain.replacingOccurrences(of: "mostly ", with: "")) as you chose, not calmer overall by our estimates" }
        if let mainGain { return "\(change), \(mainGain)" }
        return "\(change), \(noCalmer.title.prefix(1).lowercased())\(noCalmer.title.dropFirst())"
    }

    /// The line under the rating: what the calmer route costs and its biggest gain, "3 min more than fastest, 4 fewer unsignalled lefts".
    public var reasonLine: String {
        guard let calmer else { return noCalmer.title }
        if tradesStress { return calmSummary }
        let shown = calmer.minutes - fastest.minutes
        // By the real difference, not only the displayed minutes: 10 s across a minute boundary isn't "1 min more".
        let cost = extraSeconds < 1 ? "No extra time" : extraSeconds < 60 || shown <= 0 ? "Under a minute more than fastest" : "\(shown) min more than fastest"
        guard let top = gains.first?.factor else { return "\(cost), fewer small hassles" }
        // A count only where the short form counts things, and not for one: "1 fewer unsignalled lefts" isn't English.
        let saved = Int((fastest.metrics.breakdown[top].amount - calmer.metrics.breakdown[top].amount).rounded())
        return top.isExposure || !top.gain.hasPrefix("fewer") || saved < 2 ? "\(cost), \(top.gain)" : "\(cost), \(saved) \(top.gain)"
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
        case .freewayEntry: "fewer highway merges"
        case .shortFreewayHop: "fewer short highway hops"
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
