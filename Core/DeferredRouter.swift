import Foundation

/// Builds the router off the main thread at launch; requests made before it is ready wait for it.
public final class DeferredRouter: RouteComputing, Sendable {
    private let task: Task<any RouteComputing, Error>
    public init(load: @escaping @Sendable () throws -> any RouteComputing) {
        task = Task.detached(priority: .userInitiated) { try load() }
    }
    public func compare(_ request: RouteRequest) async throws -> RouteComparison {
        try await task.value.compare(request)
    }
}

extension StreetGraph {
    /// What the graph file's 64-byte header says: enough to show the map and test coverage before decoding anything.
    public struct Header: Sendable, Equatable {
        public let bounds: [Double]
        public let nodes: Int
        public let segments: Int
        /// A graph with this header's bounds and nothing else.
        public var boundsOnly: StreetGraph { StreetGraph(bounds: bounds, nodes: [], edges: [], restrictions: [], places: []) }
    }

    static var bundledURL: URL? {
        // Coverage spike: PEOPLEMAPS_GRAPH points the benchmark at an alternative graph file.
        ProcessInfo.processInfo.environment["PEOPLEMAPS_GRAPH"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.dataFile("seattle-graph", "bin")
    }

    public static func bundledHeader() throws -> Header {
        guard let url = bundledURL, let file = try? FileHandle(forReadingFrom: url), let data = try file.read(upToCount: 64) else { throw RoutingError.missingData }
        return try Header(data)
    }

    /// The directed edges `bundled()` would decode, counted from the segments' direction masks without decoding them.
    public static func bundledEdgeCount() throws -> Int {
        guard let url = bundledURL else { throw RoutingError.missingData }
        return try GraphBinary.edgeCount(Data(contentsOf: url, options: .mappedIfSafe))
    }
}

extension StreetGraph.Header {
    init(_ data: Data) throws {
        guard data.count >= 64 else { throw RoutingError.missingData }
        func get<T>(_ type: T.Type, _ offset: Int) -> T { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) } }
        guard get(UInt32.self, 0) == GraphBinary.magic, get(UInt32.self, 4) == GraphBinary.version else { throw RoutingError.missingData }
        self.init(bounds: (0..<4).map { get(Double.self, 8 + 8 * $0) }, nodes: Int(get(UInt32.self, 44)), segments: Int(get(UInt32.self, 48)))
    }
}
