import SwiftUI
import PeoplemapsCore

@main
struct PeoplemapsApp: App {
    @State private var graph: StreetGraph?
    @State private var error: String?
    var body: some Scene {
        WindowGroup {
            Group {
                if let graph { ExploreView(graph: graph) }
                else if let error { ContentUnavailableView("Seattle data unavailable", systemImage: "map", description: Text(error)) }
                else { ProgressView("Opening Seattle…").task { await load() } }
            }
            .tint(Palette.forest)
            .preferredColorScheme(.light)
        }
    }
    private func load() async {
        do { graph = try await Task.detached { try StreetGraph.bundled() }.value }
        catch { self.error = error.localizedDescription }
    }
}

enum Palette {
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let forest = Color(red: 0.14, green: 0.31, blue: 0.25)
    static let ink = Color(red: 0.13, green: 0.18, blue: 0.16)
    static let muted = Color(red: 0.39, green: 0.43, blue: 0.40)
    static let line = Color(red: 0.86, green: 0.87, blue: 0.82)
}

#if DEBUG
struct SlowTestRouter: RouteComputing {
    let base: NativeRouter
    func compare(_ request: RouteRequest) async throws -> RouteComparison {
        try await Task.sleep(for: .milliseconds(ProcessInfo.processInfo.arguments.contains("--slow-routing") ? 3000 : 150))
        return try await base.compare(request)
    }
}
#endif
