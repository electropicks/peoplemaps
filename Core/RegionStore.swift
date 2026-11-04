import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Downloaded regions (Docs/ARCHITECTURE.md "Region data"). The store fetches a region's five importer outputs, checks each against the
// manifest's size and SHA-256, inflates the search index, and moves the whole folder into place at once. Nothing is installed unless
// everything checks out. The app loads an installed region through `RegionSelection`.

/// What the Map area section shows for a region.
public enum RegionState: Equatable, Sendable {
    case notDownloaded
    case downloading(RegionProgress)
    /// Cellular is not allowed yet and there is no Wi-Fi; the download starts when Wi-Fi returns, or on `useCellular`.
    case waitingForWiFi
    case paused
    /// The plain reason. Files already received are kept, so Retry continues.
    case failed(String)
    /// Checking sizes and checksums, unpacking the search index and moving the folder into place.
    case verifying
    case ready
}

public struct RegionProgress: Equatable, Sendable {
    public var received: Int64
    public var total: Int64
    public init(received: Int64, total: Int64) { self.received = received; self.total = total }
    public var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
}

public enum RegionError: Error, LocalizedError, Equatable, Sendable {
    case unknownRegion(String)
    case notPublished(String)
    case sourceUnavailable
    case badStatus(Int)
    case wrongSize(String)
    case checksumMismatch(String)
    case notEnoughSpace(needed: Int64)
    case unpackFailed
    /// App Attest isn't available here (the Simulator, some devices).
    case deviceCannotAttest
    /// The server or Apple's check didn't give a download pass this time.
    case attestFailed
    case attestUnavailable
    /// A 429 from the attest routes.
    case serverBusy

    public var errorDescription: String? {
        switch self {
        case .unknownRegion: "This version of PeopleMaps doesn\u{2019}t know that map area."
        case .notPublished: "That map area isn\u{2019}t published yet."
        case .sourceUnavailable: "The map server isn\u{2019}t available."
        case .deviceCannotAttest: "This device can\u{2019}t prove it\u{2019}s a genuine copy of the app, so map downloads aren\u{2019}t available."
        case .attestFailed: "The server couldn\u{2019}t confirm this copy of PeopleMaps just now. Try again in a moment."
        case .attestUnavailable: "Apple\u{2019}s check for this app didn\u{2019}t answer. Try again in a moment."
        case .serverBusy: "The map server is busy right now. Try again in a little while."
        case let .badStatus(code): code == 401 || code == 403 ? "The server wouldn\u{2019}t send the map to this app." : "The server answered with an error (\(code))."
        case .wrongSize, .checksumMismatch: "A downloaded file didn\u{2019}t match what the app expected, so nothing was installed."
        case let .notEnoughSpace(needed): "There isn\u{2019}t enough free space. About \(RegionManifest.roughSizeLabel(needed)) is needed while it installs."
        case .unpackFailed: "The search data couldn\u{2019}t be unpacked, so nothing was installed."
        }
    }
}

/// Where a region's files come from. The released app uses `WorkerSource`; tests and development use `DirectSource`.
public protocol RegionSource: Sendable {
    /// The address of one file. `file` is the manifest's path (`expected/seattle-graph.bin`).
    func url(for file: String, in region: String, release: String) async throws -> URL
    /// The `Authorization` header value, or nil to send none. A bare token gets "Bearer " put in front.
    func authorization() async throws -> String?
    /// The server answered a download with a 401 for this `Authorization` value: forget it so the next `authorization()` is a new one.
    func authorizationRejected(_ authorization: String?) async
}

extension RegionSource {
    public func authorizationRejected(_ authorization: String?) async {}
}

/// A plain GET of `<base>/<region>--<path with / as __>`, with no authorization: what `Scripts/fetch_data` does without credentials.
public struct DirectSource: RegionSource {
    public let base: URL
    public init(base: URL) { self.base = base }
    public func url(for file: String, in region: String, release: String) async throws -> URL {
        base.appendingPathComponent(RegionManifest.objectName(region: region, file: file))
    }
    public func authorization() async throws -> String? { nil }
}

/// The server the released app uses: `GET /v1/regions/<release>/<region>--<file>` with `Authorization: Bearer <token>` (Docs/REPORTS.md 4.7).
/// The token comes from the App Attest exchange (`DownloadAuthorizer`, 4.5) and is kept in the Keychain for its 24 hours.
public struct WorkerSource: RegionSource {
    /// The Worker's documented address (Docs/REPORTS.md 7.5): the one place the app names it.
    public static let defaultBase = URL(string: "https://peoplemaps-reports.peoplemaps.workers.dev")!

    public let base: URL
    private let authorizer: DownloadAuthorizer

    public init(base: URL = WorkerSource.defaultBase, authorizer: DownloadAuthorizer) { self.base = base; self.authorizer = authorizer }

    #if canImport(DeviceCheck) && canImport(Security)
    public init(base: URL = WorkerSource.defaultBase) {
        self.init(base: base, authorizer: DownloadAuthorizer(client: AttestClient(baseURL: base, service: DeviceCheckAttestService()), store: KeychainDownloadTokenStore()))
    }
    #endif

    public func url(for file: String, in region: String, release: String) async throws -> URL {
        base.appendingPathComponent("v1/regions/\(release)/\(RegionManifest.objectName(region: region, file: file))")
    }
    public func authorization() async throws -> String? { "Bearer " + (try await authorizer.token()) }
    public func authorizationRejected(_ authorization: String?) async {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return }
        await authorizer.rejected(String(authorization.dropFirst(7)))
    }
}

public actor RegionStore {
    public static let backgroundIdentifier = "electrocorp.peoplemaps.regions"

    public nonisolated let manifest: RegionManifest
    public nonisolated let root: URL
    private let source: any RegionSource
    private let session: URLSession
    private let delegate: Delegate

    private struct Run {
        var pending: Set<String>
        var received: [String: Int64]
        var allowCellular: Bool
        var lastPublish = Date.distantPast
        /// Files that already got one fresh token after a 401.
        var retried: Set<String> = []
        var reattested = false
    }
    private var states: [RegionID: RegionState] = [:]
    private var runs: [RegionID: Run] = [:]
    private var subscribers: [UUID: (region: RegionID, continuation: AsyncStream<RegionState>.Continuation)] = [:]

    /// The session the released app uses: it keeps going when the app is suspended or killed, and waits for Wi-Fi or a connection.
    public static func backgroundConfiguration() -> URLSessionConfiguration {
        #if canImport(Darwin)
        let configuration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        return configuration
        #else
        return .default
        #endif
    }

    public init(manifest: RegionManifest, source: any RegionSource, root: URL = RegionSelection.root,
                configuration: URLSessionConfiguration = RegionStore.backgroundConfiguration()) {
        self.manifest = manifest; self.source = source; self.root = root
        let delegate = Delegate(root: root, release: manifest.release)
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.store = self
    }

    deinit { session.invalidateAndCancel() }

    // MARK: Reading

    /// Regions of the manifest's release that are completely installed.
    public nonisolated var installed: [RegionID] {
        manifest.regions.keys.filter { RegionSelection.isUsable(folder(for: $0)) }.sorted()
    }

    public func state(of region: RegionID) -> RegionState {
        states[region] ?? (RegionSelection.isUsable(folder(for: region)) ? .ready : .notDownloaded)
    }

    /// The state now, then each change.
    public func updates(for region: RegionID) -> AsyncStream<RegionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RegionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(state(of: region))
        subscribers[id] = (region, continuation)
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }
    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// An older release of the region is installed (an app update brought a newer manifest): still usable, and a download replaces it.
    public nonisolated func hasOlderRelease(of region: RegionID) -> Bool {
        releaseFolders().contains { $0.lastPathComponent != manifest.release && RegionSelection.isUsable($0.appendingPathComponent(region)) }
    }

    // MARK: Locations

    nonisolated func folder(for region: RegionID) -> URL {
        root.appendingPathComponent(manifest.release, isDirectory: true).appendingPathComponent(region, isDirectory: true)
    }
    private nonisolated func stagingFolder(for region: RegionID) -> URL {
        root.appendingPathComponent(".staging", isDirectory: true).appendingPathComponent(manifest.release, isDirectory: true)
            .appendingPathComponent(region, isDirectory: true)
    }
    private nonisolated func releaseFolders() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.hasDirectoryPath }
    }
    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    // MARK: Starting, pausing, removing

    /// Downloads the region's files, one task each. Files already complete in the staging folder, and resume data from an earlier stop,
    /// are reused. Without `allowCellular` the tasks wait for Wi-Fi.
    public func download(region: RegionID, allowCellular: Bool = false) async {
        guard let entry = manifest.regions[region] else { return fail(region, RegionError.unknownRegion(region)) }
        guard entry.isDownloadable else { return fail(region, RegionError.notPublished(region)) }
        switch state(of: region) {
        case .downloading, .waitingForWiFi, .verifying, .ready: return
        case .notDownloaded, .paused, .failed: break
        }
        let staging = stagingFolder(for: region)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            Self.excludeFromBackup(root)
            try checkSpace(entry)
        } catch { return fail(region, error) }

        var run = Run(pending: [], received: [:], allowCellular: allowCellular)
        for (path, file) in entry.downloads {
            let have = staging.appendingPathComponent(Self.name(path))
            if (try? have.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == file.bytes { run.received[path] = file.bytes } else {
                try? FileManager.default.removeItem(at: have)
                run.pending.insert(path); run.received[path] = 0
            }
        }
        runs[region] = run
        publish(region, progressState(region))
        if run.pending.isEmpty { return await install(region) }
        for path in run.pending.sorted() {
            guard runs[region] != nil else { return }
            do { try await startTask(region: region, path: path, entry: entry, allowCellular: allowCellular) } catch { return await failAndStop(region, error) }
        }
    }

    /// Waiting for Wi-Fi and the person said cellular is fine: start over from the bytes already in place, with cellular allowed.
    public func useCellular(region: RegionID) async {
        guard runs[region]?.allowCellular == false else { return }
        await stopTasks(region, keepResumeData: false)
        runs[region] = nil; states[region] = .paused
        await download(region: region, allowCellular: true)
    }

    /// Stops the transfers and keeps what has arrived, resume data included.
    public func pause(region: RegionID) async {
        guard runs[region] != nil else { return }
        await stopTasks(region, keepResumeData: true)
        runs[region] = nil
        publish(region, .paused)
    }

    /// Cancels any transfer, deletes what was downloaded and installed, and selects Seattle again. A folder the app has open this launch is
    /// only marked, and goes at the next launch.
    public func remove(region: RegionID) async {
        await stopTasks(region, keepResumeData: false)
        runs[region] = nil
        try? FileManager.default.removeItem(at: stagingFolder(for: region))
        let inUse = RegionSelection.root == root ? RegionSelection.launchFolder : nil
        for release in releaseFolders() {
            let folder = release.appendingPathComponent(region, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            if folder.resolvingSymlinksInPath().path == inUse?.resolvingSymlinksInPath().path { FileManager.default.createFile(atPath: folder.appendingPathComponent(RegionSelection.removedMarker).path, contents: nil) }
            else { try? FileManager.default.removeItem(at: folder) }
        }
        RegionSelection.clearSelection(root: root, ifRegion: region)
        publish(region, .notDownloaded)
    }

    /// At launch: picks up transfers the system kept going while the app was gone, finishes a download whose files all arrived, and
    /// deletes what is no longer needed (removed regions, older releases, abandoned staging).
    public func restore() async {
        prune()
        for region in manifest.regions.keys where states[region] == nil && !RegionSelection.isUsable(folder(for: region)) {
            let staging = stagingFolder(for: region)
            let tasks = await currentTasks().compactMap { task -> (String, String)? in
                guard let key = Key(task.taskDescription), key.region == region else { return nil }
                return (key.region, key.path)
            }
            if !tasks.isEmpty, let entry = manifest.regions[region] {
                var run = Run(pending: Set(tasks.map(\.1)), received: [:], allowCellular: true)
                for (path, file) in entry.downloads where !run.pending.contains(path) { run.received[path] = file.bytes }
                runs[region] = run
                publish(region, progressState(region))
            } else if let contents = try? FileManager.default.contentsOfDirectory(atPath: staging.path), !contents.isEmpty {
                let complete = manifest.regions[region]?.downloads.allSatisfy { path, file in
                    (try? staging.appendingPathComponent(Self.name(path)).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == file.bytes
                } ?? false
                if complete { await install(region) } else { states[region] = .paused }
            }
        }
    }

    // MARK: Tasks

    private func startTask(region: RegionID, path: String, entry: RegionManifest.Region, allowCellular: Bool) async throws {
        let url = try await source.url(for: path, in: region, release: manifest.release)
        var request = URLRequest(url: url)
        request.allowsCellularAccess = allowCellular
        #if canImport(Darwin)
        request.allowsExpensiveNetworkAccess = allowCellular
        #endif
        if let token = try await source.authorization() {
            request.setValue(token.hasPrefix("Bearer ") ? token : "Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let resume = stagingFolder(for: region).appendingPathComponent(Self.name(path) + ".resume")
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resume), !data.isEmpty {
            try? FileManager.default.removeItem(at: resume)
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: request)
        }
        task.taskDescription = Key(region: region, path: path).description
        task.resume()
    }

    private func currentTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in session.getAllTasks { continuation.resume(returning: $0) } }
    }

    /// Cancels this region's tasks. With `keepResumeData` each task's resume data is written next to the files, so a later start continues.
    private func stopTasks(_ region: RegionID, keepResumeData: Bool) async {
        let staging = stagingFolder(for: region)
        for task in await currentTasks() {
            guard let key = Key(task.taskDescription), key.region == region, let download = task as? URLSessionDownloadTask else { continue }
            if keepResumeData {
                let data: Data? = await withCheckedContinuation { continuation in download.cancel(byProducingResumeData: { continuation.resume(returning: $0) }) }
                if let data, !data.isEmpty { try? data.write(to: staging.appendingPathComponent(Self.name(key.path) + ".resume")) }
            } else {
                download.cancel()
                try? FileManager.default.removeItem(at: staging.appendingPathComponent(Self.name(key.path) + ".resume"))
            }
        }
    }

    // MARK: Delegate events

    fileprivate func wrote(_ key: Key, total: Int64) {
        guard var run = runs[key.region] else { return }
        run.received[key.path] = total
        if Date().timeIntervalSince(run.lastPublish) > 0.15 { run.lastPublish = Date(); runs[key.region] = run; publish(key.region, progressState(key.region)) }
        else { runs[key.region] = run }
    }

    fileprivate func waiting(_ key: Key) {
        guard let run = runs[key.region], !run.allowCellular else { return }
        publish(key.region, .waitingForWiFi)
    }

    fileprivate func completed(_ key: Key, error: Error?, status: Int?, authorization: String? = nil) async {
        guard var run = runs[key.region] else { return }   // paused, removed or failed already
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            if let data = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data {
                try? data.write(to: stagingFolder(for: key.region).appendingPathComponent(Self.name(key.path) + ".resume"))
            }
            return await failAndStop(key.region, error)
        }
        if status == 401, !run.retried.contains(key.path), let entry = manifest.regions[key.region] {
            // One fresh token per download: the first 401 forgets the token, the other files only retry with whatever
            // token is current. Otherwise each file's retry could mint another token after a rejection.
            run.retried.insert(key.path)
            let first = !run.reattested
            run.reattested = true
            runs[key.region] = run
            if first { await source.authorizationRejected(authorization) }
            do { return try await startTask(region: key.region, path: key.path, entry: entry, allowCellular: run.allowCellular) } catch { return await failAndStop(key.region, error) }
        }
        let file = stagingFolder(for: key.region).appendingPathComponent(Self.name(key.path))
        guard FileManager.default.fileExists(atPath: file.path) else { return await failAndStop(key.region, RegionError.badStatus(status ?? 0)) }
        run.pending.remove(key.path)
        run.received[key.path] = manifest.regions[key.region]?.files[key.path]?.bytes ?? run.received[key.path]
        runs[key.region] = run
        publish(key.region, progressState(key.region))
        if run.pending.isEmpty { await install(key.region) }
    }

    // MARK: Install

    private func install(_ region: RegionID) async {
        guard let entry = manifest.regions[region] else { return }
        runs[region] = nil
        publish(region, .verifying)
        let staging = stagingFolder(for: region), downloads = entry.downloads
        let outcome = await Task.detached(priority: .utility) { () -> Result<Void, Error> in
            Result { try Self.verifyAndUnpack(staging: staging, downloads: downloads) }
        }.value
        switch outcome {
        case .failure(let error): return fail(region, error)
        case .success: break
        }
        let destination = folder(for: region)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: staging, to: destination)   // one rename: the region is there whole or not at all
            try RegionSelection.select(root: root, release: manifest.release, region: region)
        } catch { return fail(region, error) }
        prune()
        publish(region, .ready)
    }

    /// Sizes, then checksums (streamed), then the search index inflated beside the other files, then the gzip deleted and the folder marked complete.
    /// A file that fails is deleted from staging so a retry fetches it again. Nothing here touches the installed folder.
    private static func verifyAndUnpack(staging: URL, downloads: [(path: String, file: RegionManifest.File)]) throws {
        let fm = FileManager.default
        for (path, file) in downloads {
            let url = staging.appendingPathComponent(name(path))
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            guard size == file.bytes else { try? fm.removeItem(at: url); throw RegionError.wrongSize(path) }
            guard try Sha256.hex(of: url) == file.sha256.lowercased() else { try? fm.removeItem(at: url); throw RegionError.checksumMismatch(path) }
        }
        for (path, _) in downloads where path.hasSuffix(".gz") {
            let gz = staging.appendingPathComponent(name(path))
            let out = staging.appendingPathComponent(String(name(path).dropLast(3)))
            do { try GzipFile.gunzip(from: gz, to: out) } catch { try? fm.removeItem(at: out); throw RegionError.unpackFailed }
            try fm.removeItem(at: gz)
        }
        for stale in (try? fm.contentsOfDirectory(atPath: staging.path)) ?? [] where stale.hasSuffix(".resume") {
            try? fm.removeItem(at: staging.appendingPathComponent(stale))
        }
        guard fm.createFile(atPath: staging.appendingPathComponent(RegionSelection.completeMarker).path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Keeps the folder selected and the one this launch has open; deletes every other installed folder, removed ones, empty release
    /// folders and the staging of other releases. Run after an install and at launch.
    func prune() {
        let fm = FileManager.default
        let keep = Set([RegionSelection.current(root: root)?.folder, RegionSelection.root == root ? RegionSelection.launchFolder : nil]
            .compactMap { $0?.resolvingSymlinksInPath().path })
        for release in releaseFolders() {
            for folder in (try? fm.contentsOfDirectory(at: release, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(folder.resolvingSymlinksInPath().path) {
                try? fm.removeItem(at: folder)
            }
            if ((try? fm.contentsOfDirectory(atPath: release.path)) ?? []).isEmpty { try? fm.removeItem(at: release) }
        }
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        for release in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] where release.lastPathComponent != manifest.release {
            try? fm.removeItem(at: release)
        }
    }

    // MARK: State

    private func progressState(_ region: RegionID) -> RegionState {
        guard let run = runs[region], let entry = manifest.regions[region] else { return .notDownloaded }
        return .downloading(RegionProgress(received: min(run.received.values.reduce(0, +), entry.downloadBytes), total: entry.downloadBytes))
    }

    private func publish(_ region: RegionID, _ state: RegionState) {
        states[region] = state
        for subscriber in subscribers.values where subscriber.region == region { subscriber.continuation.yield(state) }
    }

    private func fail(_ region: RegionID, _ error: Error) {
        runs[region] = nil
        publish(region, .failed(Self.message(for: error)))
    }

    /// A transfer failed: the others stop too (keeping their resume data) so Retry has one state to start from.
    private func failAndStop(_ region: RegionID, _ error: Error) async {
        guard runs[region] != nil else { return }
        runs[region] = nil
        await stopTasks(region, keepResumeData: true)
        publish(region, .failed(Self.message(for: error)))
    }

    static func message(for error: Error) -> String {
        if let error = error as? RegionError, let text = error.errorDescription { return text }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "The connection dropped. Check your internet and try again."
            case .timedOut: return "The server took too long to answer."
            case .cannotConnectToHost, .cannotFindHost: return "The map server couldn\u{2019}t be reached."
            default: break
            }
        }
        return error.localizedDescription
    }

    private func checkSpace(_ entry: RegionManifest.Region) throws {
        #if canImport(Darwin)
        // Peak use: the gzip and the inflated index exist together for a moment.
        let inflated = entry.downloads.filter { $0.path.hasSuffix(".gz") }.reduce(Int64(0)) { $0 + Int64(Double($1.file.bytes) * RegionManifest.searchInflateRatio) }
        let needed = entry.downloadBytes + inflated
        if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, free < needed {
            throw RegionError.notEnoughSpace(needed: needed)
        }
        #endif
    }

    private static func excludeFromBackup(_ url: URL) {
        #if canImport(Darwin)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #endif
    }

    // MARK: Background launches

    private static let completionLock = NSLock()
    nonisolated(unsafe) private static var backgroundCompletion: (@Sendable () -> Void)?
    /// The system woke the app to finish downloads; `completion` runs once the session has delivered its events.
    public static func setBackgroundCompletion(_ completion: @escaping @Sendable () -> Void) {
        completionLock.lock(); backgroundCompletion = completion; completionLock.unlock()
    }
    fileprivate static func takeBackgroundCompletion() -> (@Sendable () -> Void)? {
        completionLock.lock(); defer { completionLock.unlock() }
        let completion = backgroundCompletion; backgroundCompletion = nil
        return completion
    }

    /// `region` and the manifest path, carried in a task's description so a task the system kept alive is recognised after a relaunch.
    fileprivate struct Key: Sendable {
        let region: RegionID
        let path: String
        init(region: RegionID, path: String) { self.region = region; self.path = path }
        init?(_ description: String?) {
            guard let parts = description?.split(separator: "\n", maxSplits: 1).map(String.init), parts.count == 2 else { return nil }
            region = parts[0]; path = parts[1]
        }
        var description: String { region + "\n" + path }
    }

    /// Receives the session's events off the actor; the finished file is moved into staging before the callback returns, since the
    /// system deletes it after.
    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        nonisolated(unsafe) weak var store: RegionStore?
        let root: URL
        let release: String
        init(root: URL, release: String) { self.root = root; self.release = release }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard let key = Key(downloadTask.taskDescription), let store else { return }
            Task { await store.wrote(key, total: totalBytesWritten) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let key = Key(downloadTask.taskDescription) else { return }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status) else { return }   // `completed` reports the missing file with this status
            let fm = FileManager.default
            let folder = root.appendingPathComponent(".staging", isDirectory: true).appendingPathComponent(release, isDirectory: true)
                .appendingPathComponent(key.region, isDirectory: true)
            let destination = folder.appendingPathComponent(RegionStore.name(key.path))
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try? fm.moveItem(at: location, to: destination)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let key = Key(task.taskDescription), let store else { return }
            let status = (task.response as? HTTPURLResponse)?.statusCode
            let authorization = task.originalRequest?.value(forHTTPHeaderField: "Authorization")
            Task { await store.completed(key, error: error, status: status, authorization: authorization) }
        }

        #if canImport(Darwin)
        func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
            guard let key = Key(task.taskDescription), let store else { return }
            Task { await store.waiting(key) }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            guard let completion = RegionStore.takeBackgroundCompletion() else { return }
            DispatchQueue.main.async { completion() }
        }
        #endif
    }
}
