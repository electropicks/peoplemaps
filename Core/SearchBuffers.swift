import Foundation

/// A* working state for one search, indexed by edge state. A generation stamp stands in for clearing,
/// so reusing it costs nothing per search however large the graph is.
final class SearchBuffers {
    let stamp: UnsafeMutablePointer<UInt32>
    let cost: UnsafeMutablePointer<Double>
    let parent: UnsafeMutablePointer<Int32>
    let size: Int
    private var generation: UInt32 = 0

    init(size: Int) {
        self.size = size
        stamp = .allocate(capacity: size); stamp.initialize(repeating: 0, count: size)
        cost = .allocate(capacity: size); parent = .allocate(capacity: size)
    }
    deinit { stamp.deallocate(); cost.deallocate(); parent.deallocate() }

    /// Starts a search. A state is reached when its stamp equals the result and closed when it equals the result plus one.
    func begin() -> UInt32 {
        if generation > UInt32.max - 4 { stamp.update(repeating: 0, count: size); generation = 0 }
        generation += 2
        return generation
    }
}

/// Hands out `SearchBuffers` so concurrent searches never share one, and sequential ones reuse the same.
final class BufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private var free: [SearchBuffers] = []

    func take(size: Int) -> SearchBuffers {
        lock.lock(); defer { lock.unlock() }
        return free.popLast() ?? SearchBuffers(size: size)
    }
    func give(_ buffers: SearchBuffers) {
        lock.lock(); defer { lock.unlock() }
        if free.count < 2 { free.append(buffers) }
    }
}
