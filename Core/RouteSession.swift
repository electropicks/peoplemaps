import Foundation
import Observation

@MainActor @Observable
public final class RouteSession {
    public enum State {
        case idle, loading, ready(RouteComparison), failed(String), cancelled
    }
    public private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let router: any RouteComputing
    public init(router: any RouteComputing) { self.router = router }

    public func start(_ request: RouteRequest) {
        generation += 1
        let current = generation
        task?.cancel()
        state = .loading
        task = Task { [weak self, router] in
            do {
                let comparison = try await router.compare(request)
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.state = .ready(comparison)
            } catch is CancellationError {
                guard let self, self.generation == current else { return }
                self.state = .cancelled
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }
    public func cancel() {
        generation += 1; task?.cancel(); task = nil; state = .cancelled
    }
    public var comparison: RouteComparison? { if case let .ready(c) = state { c } else { nil } }
}
