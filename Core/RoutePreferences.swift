import Foundation

/// How much one person minds each kind of hassle in one travel mode, on top of the stress model's own weights.
/// Every option starts at `.normal`, which leaves the model untouched; see "Preferences" in Docs/STRESS_MODEL.md.
/// Only the calmer search uses it: the fastest route and every time estimate ignore it.
public struct RoutePreferences: Hashable, Sendable {
    public enum Level: String, Codable, CaseIterable, Sendable {
        case avoid, normal, dontMind
        /// Multiplier on the costs of the option's factors.
        public var multiplier: Double {
            switch self { case .avoid: 3; case .normal: 1; case .dontMind: 0.3 }
        }
        public var title: String {
            switch self { case .avoid: "Avoid"; case .normal: "Normal"; case .dontMind: "Don't mind" }
        }
    }

    /// A user-facing group of stress factors. Raw values are the stored keys: never rename them.
    public enum Option: String, Codable, CaseIterable, Sendable {
        case trafficLights, stopSigns, unprotectedLefts, busyStreets, busyCrossings, hills, turns

        /// The options that change anything in a mode, in display order.
        public static func available(in mode: TravelMode) -> [Option] { allCases.filter { !$0.factors(in: mode).isEmpty } }

        /// The factors this option scales in a mode; empty where the mode has none of them.
        public func factors(in mode: TravelMode) -> [Factor] {
            switch (self, mode) {
            case (.trafficLights, .walk): [.signalCrossing]
            case (.trafficLights, _): [.signal]
            case (.stopSigns, .walk): []
            case (.stopSigns, _): [.stopSign, .allWayStop]
            case (.unprotectedLefts, .walk): []
            case (.unprotectedLefts, _): [.unsignalledLeft, .leftAtSignal]
            case (.busyStreets, .drive): []
            case (.busyStreets, .bike): [.arterialRiding, .busyArterialRiding, .bikeRouteGap]
            case (.busyStreets, .walk): [.besideTraffic]
            case (.busyCrossings, .walk): [.unmarkedCrossing, .markedCrossing]
            case (.busyCrossings, _): [.unsignalledCrossing]
            case (.hills, .drive): [.hillStop]
            case (.hills, .bike): [.climb, .steepDescent, .hillStop]
            case (.hills, .walk): [.climb, .stairs]
            case (.turns, .walk): []
            case (.turns, _): [.turn]
            }
        }

        public var title: String {
            switch self {
            case .trafficLights: "Traffic lights"
            case .stopSigns: "Stop signs"
            case .unprotectedLefts: "Left turns across traffic"
            case .busyStreets: "Busy streets"
            case .busyCrossings: "Busy crossings without a signal"
            case .hills: "Hills"
            case .turns: "Turns"
            }
        }

        var index: Int {
            switch self {
            case .trafficLights: 0
            case .stopSigns: 1
            case .unprotectedLefts: 2
            case .busyStreets: 3
            case .busyCrossings: 4
            case .hills: 5
            case .turns: 6
            }
        }
    }

    /// Only the levels that differ from `.normal`, so equal preferences are equal values.
    private var levels: [Option: Level] = [:]

    public init(_ levels: [Option: Level] = [:]) {
        for (option, level) in levels { self[option] = level }
    }

    /// Today's model, unchanged: the per-mode weights in `StressModel` already are each mode's defaults.
    public static func `default`(for mode: TravelMode) -> RoutePreferences { RoutePreferences() }

    public subscript(_ option: Option) -> Level {
        get { levels[option] ?? .normal }
        set { levels[option] = newValue == .normal ? nil : newValue }
    }

    /// True when nothing would change in `mode`.
    public func isDefault(in mode: TravelMode) -> Bool {
        levels.keys.allSatisfy { $0.factors(in: mode).isEmpty }
    }
}

/// Stored as `{"trafficLights": "avoid"}`, listing only options that aren't normal.
/// Unknown options or levels, say from a newer version, are skipped rather than failing the whole value.
extension RoutePreferences: Codable {
    private struct Key: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        for key in c.allKeys {
            guard let option = Option(rawValue: key.stringValue), let raw = try? c.decode(String.self, forKey: key),
                  let level = Level(rawValue: raw) else { continue }
            self[option] = level
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for option in Option.allCases where self[option] != .normal { try c.encode(self[option].rawValue, forKey: Key(stringValue: option.rawValue)) }
    }
}

extension Factor {
    /// The preference option that scales this factor, in whichever mode records it.
    var preferenceOption: RoutePreferences.Option? {
        switch self {
        case .signal, .signalCrossing: .trafficLights
        case .stopSign, .allWayStop: .stopSigns
        case .unsignalledLeft, .leftAtSignal: .unprotectedLefts
        case .arterialRiding, .busyArterialRiding, .bikeRouteGap, .besideTraffic: .busyStreets
        case .unsignalledCrossing, .unmarkedCrossing, .markedCrossing: .busyCrossings
        case .climb, .steepDescent, .hillStop, .stairs: .hills
        case .turn: .turns
        default: nil
        }
    }
}

/// One request's preference multipliers, resolved once so the search pays only a table lookup per recorded factor.
/// Nil when nothing changes in the mode, so default requests take exactly today's code path.
struct FactorScale: Sendable {
    private let multipliers: [Double]

    init?(_ preferences: RoutePreferences, mode: TravelMode) {
        guard !preferences.isDefault(in: mode) else { return nil }
        multipliers = RoutePreferences.Option.allCases.map { $0.factors(in: mode).isEmpty ? 1 : preferences[$0].multiplier }
    }
    private init(multipliers: [Double]) { self.multipliers = multipliers }
    static let identity = FactorScale(multipliers: RoutePreferences.Option.allCases.map { _ in 1 })

    subscript(_ factor: Factor) -> Double {
        guard let option = factor.preferenceOption else { return 1 }
        return multipliers[option.index]
    }

    func multiplier(_ option: RoutePreferences.Option) -> Double { multipliers[option.index] }

    /// Route stress as this person weighs it. The breakdown itself keeps the model's real costs.
    func stress(_ b: Breakdown) -> Double { b.tallies.reduce(0) { $0 + $1.value.cost * self[$1.key] } }
}

/// Sums costs as scaled by a person's preferences; used inside the search.
struct ScaledRecord: StressRecorder {
    let scale: FactorScale
    var total = 0.0
    mutating func add(_ factor: Factor, amount: Double, cost: Double) { total += cost * scale[factor] }
}

/// Splits exposure costs by preference option, for precomputing what each option contributes per edge.
struct OptionSplit: StressRecorder {
    var costs = [Double](repeating: 0, count: RoutePreferences.Option.allCases.count)
    mutating func add(_ factor: Factor, amount: Double, cost: Double) {
        if let option = factor.preferenceOption { costs[option.index] += cost }
    }
}
