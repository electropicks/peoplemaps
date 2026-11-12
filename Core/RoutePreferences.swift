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
    /// The order is the display order within a mode.
    public enum Option: String, Codable, CaseIterable, Sendable {
        case stops, trafficLights, stopSigns, unprotectedLefts, busyStreets, busyCrossings, hills, steps, turns
        case highwayMerges, drawbridges, complexJunctions, narrowStreets, roughSurfaces, noSidewalks

        /// The options that change anything in a mode, in display order.
        public static func available(in mode: TravelMode) -> [Option] { allCases.filter { !$0.factors(in: mode).isEmpty } }

        /// The factors this option scales in a mode; empty where the mode has none of them.
        /// Within a mode no two options share a factor, or factors that share a `Factor.preferenceOption`.
        public func factors(in mode: TravelMode) -> [Factor] {
            switch (self, mode) {
            case (.stops, .drive): [.signal, .stopSign, .allWayStop]
            case (.stops, _): []
            case (.trafficLights, .drive): []
            case (.trafficLights, .bike): [.signal]
            case (.trafficLights, .walk): [.signalCrossing]
            case (.stopSigns, .bike): [.stopSign, .allWayStop]
            case (.stopSigns, _): []
            case (.unprotectedLefts, .walk): []
            case (.unprotectedLefts, _): [.unsignalledLeft, .leftAtSignal]
            case (.busyStreets, .drive): []
            case (.busyStreets, .bike): [.arterialRiding, .busyArterialRiding, .bikeRouteGap]
            case (.busyStreets, .walk): [.besideTraffic]
            case (.busyCrossings, .walk): [.unmarkedCrossing, .markedCrossing]
            case (.busyCrossings, _): [.unsignalledCrossing]
            case (.hills, .drive): [.hillStop]
            case (.hills, .bike): [.climb, .steepDescent, .hillStop]
            case (.hills, .walk): [.climb]
            case (.steps, .walk): [.stairs]
            case (.steps, _): []
            case (.turns, .walk): []
            case (.turns, _): [.turn]
            case (.highwayMerges, .drive): [.freewayEntry]
            case (.highwayMerges, _): []
            case (.drawbridges, .walk): []
            case (.drawbridges, _): [.movableBridge]
            case (.complexJunctions, .drive): [.complexJunction]
            case (.complexJunctions, _): []
            case (.narrowStreets, .drive): [.narrowWithParking]
            case (.narrowStreets, _): []
            case (.roughSurfaces, .bike): [.roughSurface]
            case (.roughSurfaces, _): []
            case (.noSidewalks, .walk): [.noSidewalk]
            case (.noSidewalks, _): []
            }
        }

        public var title: String {
            switch self {
            case .stops: "Stops"
            case .trafficLights: "Traffic lights"
            case .stopSigns: "Stop signs"
            case .unprotectedLefts: "Left turns across traffic"
            case .busyStreets: "Busy streets"
            case .busyCrossings: "Busy crossings"
            case .hills: "Hills"
            case .steps: "Steps"
            case .turns: "Turns"
            case .highwayMerges: "Highway on-ramps"
            case .drawbridges: "Drawbridges"
            case .complexJunctions: "Complex intersections"
            case .narrowStreets: "Narrow streets"
            case .roughSurfaces: "Rough surfaces"
            case .noSidewalks: "Streets without sidewalks"
            }
        }

        /// A second line where the title alone doesn't say what the option covers.
        public var detail: String? {
            switch self {
            case .stops: "Lights and stop signs"
            case .busyCrossings: "Without a signal"
            case .complexJunctions: "Five or more streets"
            case .narrowStreets: "Parked on both sides"
            default: nil
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
            case .stops: 7
            case .steps: 8
            case .highwayMerges: 9
            case .drawbridges: 10
            case .complexJunctions: 11
            case .narrowStreets: 12
            case .roughSurfaces: 13
            case .noSidewalks: 14
            }
        }
        static let count = allCases.count
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

    /// Choices saved before each mode had its own options, carried over: driving's Traffic lights and Stop signs become Stops
    /// (Avoid if either was, Don't mind only if both were), and a walker's Hills level also covers Steps, as it used to.
    public func upgraded(in mode: TravelMode) -> RoutePreferences {
        var p = self
        switch mode {
        case .drive:
            let old = [self[.trafficLights], self[.stopSigns]]
            if self[.stops] == .normal { p[.stops] = old.contains(.avoid) ? .avoid : old == [.dontMind, .dontMind] ? .dontMind : .normal }
            p[.trafficLights] = .normal; p[.stopSigns] = .normal
        case .walk: if self[.steps] == .normal { p[.steps] = self[.hills] }
        case .bike: break
        }
        return p
    }

    /// True when nothing would change in `mode`.
    public func isDefault(in mode: TravelMode) -> Bool {
        levels.keys.allSatisfy { $0.factors(in: mode).isEmpty }
    }
}

/// Stored as `{"trafficLights": "avoid"}`, listing only options that aren't normal.
/// Unknown options or levels, say from a newer version, are skipped rather than failing the whole value.
/// A value that isn't an object at all (an array, a string, null) decodes as the defaults.
extension RoutePreferences: Codable {
    private struct Key: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Key.self) else { return }
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
    /// The search's multiplier slot for this factor: the option that scales it wherever a mode offers it under that name.
    /// Driving offers signals and stop signs together as `.stops`, which sets both of their slots.
    var preferenceOption: RoutePreferences.Option? {
        switch self {
        case .signal, .signalCrossing: .trafficLights
        case .stopSign, .allWayStop: .stopSigns
        case .unsignalledLeft, .leftAtSignal: .unprotectedLefts
        case .arterialRiding, .busyArterialRiding, .bikeRouteGap, .besideTraffic: .busyStreets
        case .unsignalledCrossing, .unmarkedCrossing, .markedCrossing: .busyCrossings
        case .climb, .steepDescent, .hillStop: .hills
        case .stairs: .steps
        case .turn: .turns
        case .freewayEntry: .highwayMerges
        case .movableBridge: .drawbridges
        case .complexJunction: .complexJunctions
        case .narrowWithParking: .narrowStreets
        case .roughSurface: .roughSurfaces
        case .noSidewalk: .noSidewalks
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
        var m = [Double](repeating: 1, count: RoutePreferences.Option.count)
        for option in RoutePreferences.Option.allCases {
            for factor in option.factors(in: mode) { if let slot = factor.preferenceOption { m[slot.index] = preferences[option].multiplier } }
        }
        multipliers = m
    }
    private init(multipliers: [Double]) { self.multipliers = multipliers }
    static let identity = FactorScale(multipliers: .init(repeating: 1, count: RoutePreferences.Option.count))

    subscript(_ factor: Factor) -> Double {
        guard let option = factor.preferenceOption else { return 1 }
        return multipliers[option.index]
    }

    /// Multipliers by slot index (`Factor.preferenceOption.index`).
    var bySlot: [Double] { multipliers }

    /// Route stress as this person weighs it. The breakdown itself keeps the model's real costs.
    func stress(_ b: Breakdown) -> Double { Factor.allCases.reduce(0) { $0 + (b.tallies[$1]?.cost ?? 0) * self[$1] } }
}

/// Sums costs as scaled by a person's preferences; used inside the search.
struct ScaledRecord: StressRecorder {
    let scale: FactorScale
    var total = 0.0
    mutating func add(_ factor: Factor, amount: Double, cost: Double) { total += cost * scale[factor] }
}

/// Splits exposure costs by preference option, for precomputing what each option contributes per edge.
struct OptionSplit: StressRecorder {
    var costs = [Double](repeating: 0, count: RoutePreferences.Option.count)
    mutating func add(_ factor: Factor, amount: Double, cost: Double) {
        if let option = factor.preferenceOption { costs[option.index] += cost }
    }
}
