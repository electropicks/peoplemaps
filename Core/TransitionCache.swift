import Foundation

/// What the search takes from one turn from an edge onto the next. The stress model's additions are kept in order,
/// so replaying them under any preferences gives exactly the totals a direct call would.
struct TransitionCost {
    static let unknown: UInt8 = 255, overflow: UInt8 = 5
    /// Preference option index recorded for additions that no option scales.
    static let unscaled: UInt8 = 7
    var seconds = Double.nan
    /// Number of additions kept, `overflow` when there were too many to keep, `unknown` before the stress was worked out.
    var count = unknown
    var costs = SIMD4<Double>()
    var options = SIMD4<UInt8>(repeating: unscaled)

    mutating func record(_ log: AdditionLog) {
        count = log.overflow ? Self.overflow : UInt8(log.count); costs = log.costs; options = log.options
    }
}

/// Collects the additions `StressModel.transition` makes, in order.
struct AdditionLog: StressRecorder {
    var count = 0, overflow = false
    var costs = SIMD4<Double>()
    var options = SIMD4<UInt8>(repeating: TransitionCost.unscaled)
    mutating func add(_ factor: Factor, amount: Double, cost: Double) {
        guard count < 4 else { overflow = true; return }
        costs[count] = cost; options[count] = factor.preferenceOption.map { UInt8($0.index) } ?? TransitionCost.unscaled
        count += 1
    }
}

/// Turn costs worked out so far for one request, shared by its searches (which mostly cover the same junctions).
/// Bounded, so a long trip cannot grow it without limit; a missing entry is simply worked out again.
final class TransitionCache: @unchecked Sendable {
    private final class Shard {
        let lock = NSLock()
        var table: [Int: TransitionCost] = [:]
    }
    private static let capacity = 1 << 14
    private let shards = (0..<16).map { _ in Shard() }

    private func shard(_ key: Int) -> Shard { shards[Int((UInt64(truncatingIfNeeded: key) &* 0x9e37_79b9_7f4a_7c15) >> 60)] }

    func entry(_ key: Int) -> TransitionCost? {
        let s = shard(key)
        s.lock.lock(); defer { s.lock.unlock() }
        return s.table[key]
    }

    func store(_ key: Int, _ cost: TransitionCost) {
        let s = shard(key)
        s.lock.lock(); defer { s.lock.unlock() }
        if s.table.count < Self.capacity || s.table.index(forKey: key) != nil { s.table[key] = cost }
    }
}
