import SwiftUI
import PeoplemapsCore

/// What the Map area section of About shows and does: the King County download, its state, and switching to it. Holds no map data itself;
/// `RegionStore` downloads and installs, `RegionSelection` decides what the app loads.
@MainActor @Observable
final class RegionModel {
    static let regionID = "king-county"

    private let store: RegionStore?
    private let region: RegionManifest.Region?
    private(set) var state: RegionState = .notDownloaded
    /// The last progress seen, kept while paused or waiting so the bar doesn't empty.
    private(set) var progress: RegionProgress?
    /// King County is selected on disk but this launch loaded something else: it loads at the next launch, or on Switch now.
    private(set) var switchPending = false
    private(set) var usesCounty = RegionSelection.usesCounty
    /// The downloaded map's files would not load, so Seattle is showing.
    private(set) var fellBack = RegionSelection.fellBack
    private(set) var hasOlderRelease = false
    /// Set by the app: reloads the map data and rebuilds the screen.
    var reload: (() -> Void)?

    /// Nil when this build has no manifest, or the region is not published in it: the section is not shown.
    var offer: Offer? {
        guard let region, region.isDownloadable else { return nil }
        return Offer(download: region.downloadBytes, installed: region.installedBytesEstimate)
    }
    struct Offer: Equatable {
        let download: Int64
        let installed: Int64
        var downloadLabel: String { RegionManifest.sizeLabel(download) }
        var installedLabel: String { RegionManifest.roughSizeLabel(installed) }
    }

    init(manifest: RegionManifest?, store: RegionStore?) {
        self.store = store
        region = manifest?.regions[Self.regionID]
        refreshSelection()
    }

    /// The model the app uses. Debug builds can point it at a local test server (`--region-server URL`) and a made-up manifest
    /// (`--region-manifest-json JSON`); release builds use the Worker, which is not built yet, so their Download reports that.
    static func make() -> RegionModel {
        var manifest = RegionManifest.bundled()
        var source: any RegionSource = WorkerSource()
        var configuration = RegionStore.backgroundConfiguration()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        if let server = value(after: "--region-server").flatMap(URL.init(string:)) {
            source = DirectSource(base: server)
            configuration = .default
        }
        if let json = value(after: "--region-manifest-json")?.data(using: .utf8), let injected = try? RegionManifest(json: json) { manifest = injected }
        #endif
        guard let manifest else { return RegionModel(manifest: nil, store: nil) }
        return RegionModel(manifest: manifest, store: RegionStore(manifest: manifest, source: source, configuration: configuration))
    }

    /// Picks up transfers that went on while the app was away, then follows the store's state for the life of the app.
    func start() async {
        guard let store else { return }
        await store.restore()
        for await next in await store.updates(for: Self.regionID) {
            if case let .downloading(progress) = next { self.progress = progress }
            state = next
            hasOlderRelease = store.hasOlderRelease(of: Self.regionID)
            refreshSelection()
        }
    }

    private func refreshSelection() {
        usesCounty = RegionSelection.usesCounty
        fellBack = RegionSelection.fellBack
        switchPending = RegionSelection.switchPending
    }

    // MARK: Actions

    func download() { run { await $0.download(region: Self.regionID) } }
    func resume() { download() }
    func retry() { download() }
    func pause() { run { await $0.pause(region: Self.regionID) } }
    func useCellular() { run { await $0.useCellular(region: Self.regionID) } }
    func remove() {
        progress = nil
        run { await $0.remove(region: Self.regionID) }
    }
    /// Loads the downloaded map now. The caller has checked that no route is active and the person is not navigating.
    func switchNow() {
        RegionSelection.reload()
        refreshSelection()
        reload?()
        refreshSelection()
    }

    private func run(_ work: @escaping @Sendable (RegionStore) async -> Void) {
        guard let store else { return }
        Task { await work(store) }
    }
}
