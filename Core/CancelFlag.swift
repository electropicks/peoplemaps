import Foundation

/// Cancellation for searches that run on other threads, where `Task.isCancelled` cannot see the request's task.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    /// Throws once this flag or the calling task is cancelled; a task cancelled on the calling thread cancels the flag for the rest.
    func check() throws {
        if Task.isCancelled { cancel() }
        if isCancelled { throw CancellationError() }
    }
}
