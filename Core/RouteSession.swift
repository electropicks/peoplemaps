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
        let began = DispatchTime.now().uptimeNanoseconds
        let ms = { Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6 }
        AppEvents.shared.log(.route, "route compare started", mode: request.mode)
        task = Task { [weak self, router] in
            do {
                let comparison = try await router.compare(request)
                AppEvents.shared.log(.route, "route compare finished", mode: request.mode, ["ms": ms(), "candidates": Double(comparison.candidateCount)])
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.state = .ready(comparison)
            } catch is CancellationError {
                AppEvents.shared.log(.route, "route compare cancelled", mode: request.mode, ["ms": ms()])
                guard let self, self.generation == current else { return }
                self.state = .cancelled
            } catch {
                AppEvents.shared.log(.error, "route compare failed", error: error, mode: request.mode, ["ms": ms()])
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }
    /// Shows a comparison already computed for the same request, without running it again.
    public func start(_ request: RouteRequest, seed: RouteComparison) {
        generation += 1
        task?.cancel(); task = nil
        AppEvents.shared.log(.route, "route compare reused", mode: request.mode)
        state = .ready(seed)
    }
    public func cancel() {
        generation += 1; task?.cancel(); task = nil; state = .cancelled
    }
    public var comparison: RouteComparison? { if case let .ready(c) = state { c } else { nil } }
}
