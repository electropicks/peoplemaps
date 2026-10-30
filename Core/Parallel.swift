import Foundation

/// `body(0..<count)` on all cores, results in index order.
func parallelMap<T: Sendable>(_ count: Int, _ body: @Sendable (Int) -> T) -> [T] {
    let slots = Slots<T>(count)
    DispatchQueue.concurrentPerform(iterations: count) { slots.set($0, body($0)) }
    return slots.values()
}

/// `body` over consecutive ranges of `0..<count`, concatenated in order.
func parallelChunks<T: Sendable>(_ count: Int, size: Int = 8192, _ body: @Sendable (Range<Int>) -> [T]) -> [T] {
    parallelMap((count + size - 1) / size) { body($0 * size..<min(count, ($0 + 1) * size)) }.flatMap { $0 }
}

private final class Slots<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T?]
    init(_ count: Int) { items = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ value: T) { lock.lock(); items[i] = value; lock.unlock() }
    func values() -> [T] { items.map { $0! } }
}
