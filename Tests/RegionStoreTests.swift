import XCTest
@testable import PeoplemapsCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A small made-up region: files with the right sizes and checksums, served under the bucket's object names.
struct FakeRegion {
    let release: String
    let region: String
    var graph: Data
    let map: Data
    let search: Data       // what the inflated index holds
    let coverage: Data
    let provenance: Data

    init(release: String, region: String = "king-county", graphBytes: Int = 400_000, seed: UInt8 = 1) {
        self.release = release; self.region = region
        graph = Data((0..<graphBytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
        map = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) })
        search = Data(String(repeating: "calmer streets \(seed)\n", count: 20_000).utf8)
        coverage = Data(#"{"bbox":[1,2,3,4],"rings":[]}"#.utf8)
        provenance = Data(#"{"release":"\#(release)"}"#.utf8)
    }

    var searchGz: Data { Self.gzip(search) }
    /// Path in the manifest, then contents as served.
    var served: [(path: String, data: Data)] {
        [("expected/seattle-graph.bin", graph), ("expected/seattle-map.pmtiles", map), ("expected/seattle-search.sqlite.gz", searchGz),
         ("expected/seattle-coverage.json", coverage), ("expected/provenance.json", provenance)]
    }
    func objects() -> [String: Data] {
        Dictionary(uniqueKeysWithValues: served.map { (RegionManifest.objectName(region: region, file: $0.path), $0.data) })
    }
    func manifest(corruptingGraph: Bool = false) -> RegionManifest {
        var files: [String: RegionManifest.File] = [:]
        for (path, data) in served {
            var hash = Sha256.portableHex(of: data)
            if corruptingGraph && path.hasSuffix("graph.bin") { hash = String(repeating: "0", count: 64) }
            files[path] = .init(bytes: Int64(data.count), sha256: hash)
        }
        files["seattle-osm.json.gz"] = .init(bytes: 5, sha256: "00")   // an input, never downloaded
        return RegionManifest(release: release, regions: [region: .init(bbox: [1, 2, 3, 4], files: files, outputs: served.map { String($0.path.dropFirst(9)) })])
    }

    /// One gzip member holding `data` in stored (uncompressed) blocks.
    static func gzip(_ data: Data) -> Data {
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
        var offset = 0
        repeat {
            let n = min(65535, data.count - offset)
            let last: UInt8 = offset + n >= data.count ? 1 : 0
            out += [last, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            out += data.subdata(in: offset..<offset + n)
            offset += n
        } while offset < data.count
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? crc >> 1 ^ 0xEDB88320 : crc >> 1 }
        }
        crc = ~crc
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8(truncatingIfNeeded: crc >> UInt32(shift))) }
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8(truncatingIfNeeded: UInt32(data.count) >> UInt32(shift))) }
        return out
    }
}

final class RegionStoreTests: XCTestCase {
    private var root: URL!
    private var servers: [TinyHTTPServer] = []

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("region-store-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        servers.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    private func serve(_ region: FakeRegion) throws -> TinyHTTPServer {
        let server = try TinyHTTPServer(files: region.objects())
        servers.append(server)
        return server
    }

    private func store(_ manifest: RegionManifest, _ server: TinyHTTPServer) -> RegionStore {
        RegionStore(manifest: manifest, source: DirectSource(base: server.baseURL), root: root, configuration: .default)
    }

    /// The first state from the store's stream that `matches`, or nil after `timeout` seconds.
    private func wait(_ store: RegionStore, _ matches: @escaping @Sendable (RegionState) -> Bool, timeout: Double = 30) async -> RegionState? {
        let stream = await store.updates(for: "king-county")
        return await withTaskGroup(of: RegionState?.self) { group in
            group.addTask { for await state in stream where matches(state) { return state }; return nil }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
    private static func isFailed(_ s: RegionState) -> Bool { if case .failed = s { true } else { false } }

    private func installedFolder(_ release: String) -> URL { root.appendingPathComponent(release).appendingPathComponent("king-county") }

    // MARK: Download and install

    func testDownloadVerifiesInflatesAndInstalls() async throws {
        let fake = FakeRegion(release: "data-test-1")
        let store = store(fake.manifest(), try serve(fake))
        let initial = await store.state(of: "king-county")
        XCTAssertEqual(initial, .notDownloaded)
        await store.download(region: "king-county")
        let done = await wait(store, { $0 == .ready })
        XCTAssertEqual(done, .ready)

        let folder = installedFolder("data-test-1")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("seattle-graph.bin")), fake.graph)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("seattle-map.pmtiles")), fake.map)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("seattle-search.sqlite")), fake.search, "inflated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("seattle-search.sqlite.gz").path), "the gzip is not kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("seattle-osm.json.gz").path), "inputs are never fetched")
        XCTAssertEqual(store.installed, ["king-county"])
        XCTAssertEqual(RegionSelection.current(root: root)?.folder, folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".staging/data-test-1/king-county").path))
        XCTAssertEqual(Set(server(of: servers).requests.map(\.path)), Set(fake.objects().keys), "only the five outputs were requested")
    }

    private func server(of servers: [TinyHTTPServer]) -> TinyHTTPServer { servers[0] }

    func testChecksumMismatchInstallsNothing() async throws {
        let fake = FakeRegion(release: "data-test-2")
        let store = store(fake.manifest(corruptingGraph: true), try serve(fake))
        await store.download(region: "king-county")
        let end = await wait(store, { Self.isFailed($0) || $0 == .ready })
        guard case let .failed(message)? = end else { return XCTFail("expected a failure, got \(String(describing: end))") }
        XCTAssertTrue(message.contains("nothing was installed"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedFolder("data-test-2").path))
        XCTAssertNil(RegionSelection.current(root: root))
        XCTAssertEqual(store.installed, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".staging/data-test-2/king-county/seattle-graph.bin").path),
                       "the bad file is deleted so Retry fetches it again")
    }

    func testRetryAfterAFailureReusesTheGoodFiles() async throws {
        let fake = FakeRegion(release: "data-test-3")
        var wrong = fake; wrong.graph = Data(repeating: 9, count: fake.graph.count)   // same size, other bytes
        let server = try TinyHTTPServer(files: wrong.objects()); servers.append(server)
        let store = store(fake.manifest(), server)
        await store.download(region: "king-county")
        let failed = await wait(store, { Self.isFailed($0) })
        XCTAssertNotNil(failed)
        server.replace(RegionManifest.objectName(region: "king-county", file: "expected/seattle-graph.bin"), with: fake.graph)
        let before = server.requests.count
        await store.download(region: "king-county")
        let done = await wait(store, { $0 == .ready })
        XCTAssertEqual(done, .ready)
        XCTAssertEqual(server.requests.count - before, 1, "only the bad file was fetched again")
    }

    func testAMissingFileFailsWithTheStatus() async throws {
        let fake = FakeRegion(release: "data-test-4")
        var objects = fake.objects()
        objects[RegionManifest.objectName(region: "king-county", file: "expected/seattle-map.pmtiles")] = nil
        let server = try TinyHTTPServer(files: objects); servers.append(server)
        let store = store(fake.manifest(), server)
        await store.download(region: "king-county")
        let end = await wait(store, { Self.isFailed($0) || $0 == .ready })
        guard case let .failed(message)? = end else { return XCTFail("expected a failure, got \(String(describing: end))") }
        XCTAssertTrue(message.contains("404"), message)
        XCTAssertEqual(store.installed, [])
    }

    func testAnUnpublishedRegionIsRefused() async throws {
        let fake = FakeRegion(release: "data-test-5")
        var manifest = fake.manifest()
        manifest = RegionManifest(release: manifest.release, regions: ["king-county": .init(bbox: [1, 2, 3, 4], files: [:], outputs: ["seattle-graph.bin"])])
        let store = store(manifest, try serve(fake))
        await store.download(region: "king-county")
        let state = await store.state(of: "king-county")
        guard case .failed = state else { return XCTFail("\(state)") }
    }

    // MARK: Pause and resume

    func testResumeContinuesAPausedDownload() async throws {
        #if os(Linux)
        throw XCTSkip("URLSession on Linux has no resume data; the app runs on iOS")
        #endif
        let fake = FakeRegion(release: "data-test-6", graphBytes: 3_000_000)
        let server = try serve(fake)
        let graph = RegionManifest.objectName(region: "king-county", file: "expected/seattle-graph.bin")
        server.stall(graph, after: 1_000_000)
        let store = store(fake.manifest(), server)
        await store.download(region: "king-county")
        let deadline = Date().addingTimeInterval(20)
        while !server.isStalled(graph), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(server.isStalled(graph), "the server held the graph part-way")
        try await Task.sleep(for: .milliseconds(300))   // let URLSession record what it received

        await store.pause(region: "king-county")
        let paused = await store.state(of: "king-county")
        XCTAssertEqual(paused, .paused)
        let resumeFile = root.appendingPathComponent(".staging/data-test-6/king-county/seattle-graph.bin.resume")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumeFile.path), "resume data kept")
        server.release(graph)

        await store.download(region: "king-county")
        let done = await wait(store, { $0 == .ready })
        XCTAssertEqual(done, .ready)
        XCTAssertEqual(try Data(contentsOf: installedFolder("data-test-6").appendingPathComponent("seattle-graph.bin")), fake.graph)
        let graphRequests = server.requests.filter { $0.path == graph }
        XCTAssertEqual(graphRequests.count, 2)
        XCTAssertNotNil(graphRequests.last?.range, "the second request asked for the rest, not the whole file")
    }

    // MARK: Remove and upgrade

    func testRemoveDeletesTheRegionAndTheSelection() async throws {
        let fake = FakeRegion(release: "data-test-7")
        let store = store(fake.manifest(), try serve(fake))
        await store.download(region: "king-county")
        _ = await wait(store, { $0 == .ready })
        XCTAssertEqual(store.installed, ["king-county"])
        await store.remove(region: "king-county")
        XCTAssertEqual(store.installed, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedFolder("data-test-7").path))
        XCTAssertNil(RegionSelection.current(root: root))
        let state = await store.state(of: "king-county")
        XCTAssertEqual(state, .notDownloaded)
    }

    func testANewReleaseKeepsTheOldFolderUntilItIsIn() async throws {
        let old = FakeRegion(release: "data-test-old", seed: 1)
        let oldStore = store(old.manifest(), try serve(old))
        await oldStore.download(region: "king-county")
        _ = await wait(oldStore, { $0 == .ready })
        XCTAssertEqual(RegionSelection.current(root: root)?.folder, installedFolder("data-test-old"))

        let new = FakeRegion(release: "data-test-new", graphBytes: 2_000_000, seed: 2)
        let server = try serve(new)
        let graph = RegionManifest.objectName(region: "king-county", file: "expected/seattle-graph.bin")
        server.stall(graph, after: 500_000)
        let newStore = store(new.manifest(), server)
        XCTAssertTrue(newStore.hasOlderRelease(of: "king-county"))
        XCTAssertEqual(newStore.installed, [], "the new release is not in yet")
        await newStore.download(region: "king-county")
        let deadline = Date().addingTimeInterval(20)
        while !server.isStalled(graph), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedFolder("data-test-old").appendingPathComponent(".complete").path), "old kept mid-download")
        XCTAssertEqual(RegionSelection.current(root: root)?.folder, installedFolder("data-test-old"))

        server.release(graph)
        let done = await wait(newStore, { $0 == .ready })
        XCTAssertEqual(done, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("data-test-old").path), "old deleted once the new is in")
        XCTAssertEqual(RegionSelection.current(root: root)?.folder, installedFolder("data-test-new"))
        XCTAssertFalse(newStore.hasOlderRelease(of: "king-county"))
    }

    func testAFailedUpgradeLeavesTheOldRegionInUse() async throws {
        let old = FakeRegion(release: "data-test-old2", seed: 1)
        let oldStore = store(old.manifest(), try serve(old))
        await oldStore.download(region: "king-county")
        _ = await wait(oldStore, { $0 == .ready })

        let new = FakeRegion(release: "data-test-new2", seed: 2)
        let newStore = store(new.manifest(corruptingGraph: true), try serve(new))
        await newStore.download(region: "king-county")
        _ = await wait(newStore, { Self.isFailed($0) })
        XCTAssertEqual(RegionSelection.current(root: root)?.folder, installedFolder("data-test-old2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedFolder("data-test-old2").appendingPathComponent("seattle-graph.bin").path))
    }

    // MARK: The Worker source

    /// A Worker stand-in: files under `v1/regions/<release>/`, and a fake device whose n-th attestation yields `pmd_n`.
    private func workerStore(_ fake: FakeRegion, accepting: Set<String>) throws -> (RegionStore, TinyHTTPServer, AttestFixture) {
        var files: [String: Data] = [:]
        for (name, data) in fake.objects() { files["v1/regions/\(fake.release)/\(name)"] = data }
        let server = try TinyHTTPServer(files: files)
        server.requireAuthorization(accepting)
        servers.append(server)
        let attest = AttestFixture(challenge: Data(repeating: 7, count: 68), supported: true, now: Date(), lifetime: 86_400, statuses: [:])
        let authorizer = DownloadAuthorizer(client: AttestClient(baseURL: server.baseURL, service: attest, transport: attest.transport), store: attest)
        let store = RegionStore(manifest: fake.manifest(), source: WorkerSource(base: server.baseURL, authorizer: authorizer), root: root, configuration: .default)
        return (store, server, attest)
    }

    func testAFirstRejectedTokenIsReplacedOnceAndTheDownloadFinishes() async throws {
        let fake = FakeRegion(release: "data-test-w1")
        let (store, server, attest) = try workerStore(fake, accepting: ["Bearer pmd_1"])
        attest.save(DownloadToken(value: "pmd_old", expiresAt: Date().addingTimeInterval(3_600)))   // cached, but the server has forgotten it
        await store.download(region: "king-county")
        let done = await wait(store, { $0 == .ready })
        XCTAssertEqual(done, .ready)
        XCTAssertEqual(attest.keysMade, 1, "one re-attestation, however many files saw the 401")
        XCTAssertTrue(server.requests.contains { $0.auth == "Bearer pmd_old" })
        XCTAssertTrue(server.requests.contains { $0.auth == "Bearer pmd_1" })
    }

    func testASecondRejectionSurfacesAndStops() async throws {
        let fake = FakeRegion(release: "data-test-w2")
        let (store, _, attest) = try workerStore(fake, accepting: ["Bearer nothing-matches"])
        await store.download(region: "king-county")
        let failed = await wait(store, { Self.isFailed($0) })
        XCTAssertEqual(failed, .failed(RegionError.badStatus(401).errorDescription!))
        XCTAssertLessThanOrEqual(attest.keysMade, 2, "no loop of attestations")
        let state = await store.state(of: "king-county")
        XCTAssertTrue(Self.isFailed(state))
    }

    func testAnUnsupportedDeviceFailsTheDownloadWithThePlainMessage() async throws {
        let fake = FakeRegion(release: "data-test-w3")
        let server = try TinyHTTPServer(files: [:]); servers.append(server)
        let attest = AttestFixture(challenge: Data(repeating: 7, count: 68), supported: false, now: Date(), lifetime: 86_400, statuses: [:])
        let authorizer = DownloadAuthorizer(client: AttestClient(baseURL: server.baseURL, service: attest, transport: attest.transport), store: attest)
        let store = RegionStore(manifest: fake.manifest(), source: WorkerSource(base: server.baseURL, authorizer: authorizer), root: root, configuration: .default)
        await store.download(region: "king-county")
        let failed = await wait(store, { Self.isFailed($0) })
        XCTAssertEqual(failed, .failed("This device can\u{2019}t prove it\u{2019}s a genuine copy of the app, so map downloads aren\u{2019}t available."))
        XCTAssertTrue(server.requests.isEmpty)
    }

    // MARK: Pieces

    func testSourcesNameFilesAsTheBucketDoes() async throws {
        let direct = DirectSource(base: URL(string: "http://127.0.0.1:9")!)
        let url = try await direct.url(for: "expected/seattle-graph.bin", in: "king-county", release: "r")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:9/king-county--expected__seattle-graph.bin")
        let auth = try await direct.authorization()
        XCTAssertNil(auth)
    }

    func testTheShippedManifestPinsTheCountyOutputs() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Data/regions.json")
        let manifest = try RegionManifest(json: Data(contentsOf: file))
        let county = try XCTUnwrap(manifest.regions["king-county"])
        XCTAssertTrue(county.isDownloadable)
        XCTAssertEqual(county.downloads.count, 5)
        XCTAssertTrue(county.downloads.allSatisfy { $0.path.hasPrefix("expected/") }, "inputs are never downloaded")
        XCTAssertEqual(county.downloadBytes, county.downloads.reduce(0) { $0 + $1.file.bytes })
        XCTAssertTrue((230_000_000...235_000_000).contains(county.downloadBytes), "about 232 MB, not the stale 111 MB")
        // 232 MB sent; the search index inflates about 3.3 times.
        XCTAssertTrue((340_000_000...360_000_000).contains(county.installedBytesEstimate), "\(county.installedBytesEstimate)")
    }

    func testPortableSha256MatchesTheSystemOne() throws {
        let samples = [Data(), Data("abc".utf8), Data(repeating: 0x61, count: 55), Data(repeating: 0x61, count: 56), Data(repeating: 0x61, count: 64),
                       Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })]
        for sample in samples {
            let file = root.appendingPathComponent("sample")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try sample.write(to: file)
            XCTAssertEqual(Sha256.portableHex(of: sample), try Sha256.hex(of: file), "\(sample.count) bytes")
        }
        XCTAssertEqual(Sha256.portableHex(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testGunzipFileStreamsAndRejectsDamage() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: ($0 >> 3) &* 5) })   // several chunks
        let gz = root.appendingPathComponent("a.gz"), out = root.appendingPathComponent("a")
        try FakeRegion.gzip(original).write(to: gz)
        try GzipFile.gunzip(from: gz, to: out)
        XCTAssertEqual(try Data(contentsOf: out), original)

        var damaged = FakeRegion.gzip(original)
        damaged[damaged.count - 6] ^= 0xFF   // the CRC
        try damaged.write(to: gz)
        XCTAssertThrowsError(try GzipFile.gunzip(from: gz, to: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "no partial output left")

        try Data("not gzip at all".utf8).write(to: gz)
        XCTAssertThrowsError(try GzipFile.gunzip(from: gz, to: out)) { XCTAssertEqual($0 as? GzipFile.Failure, .notGzip) }
        try FakeRegion.gzip(original).prefix(5000).write(to: gz)
        XCTAssertThrowsError(try GzipFile.gunzip(from: gz, to: out)) { XCTAssertEqual($0 as? GzipFile.Failure, .corrupt) }
    }

    func testTheSelectionSwitchesOnlyOnReload() throws {
        let launch = root.appendingPathComponent("launch")
        RegionSelection.configure(root: launch)
        addTeardownBlock { RegionSelection.configure(root: nil) }
        XCTAssertNil(RegionSelection.launchFolder)
        XCTAssertNil(RegionSelection.file("seattle-graph.bin"))
        // A region becomes ready after launch: it is pending, and not loaded.
        let folder = launch.appendingPathComponent("r1/king-county")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("g".utf8).write(to: folder.appendingPathComponent("seattle-graph.bin"))
        FileManager.default.createFile(atPath: folder.appendingPathComponent(".complete").path, contents: nil)
        try RegionSelection.select(root: launch, release: "r1", region: "king-county")
        XCTAssertNil(RegionSelection.file("seattle-graph.bin"), "never switches under a running app")
        XCTAssertTrue(RegionSelection.switchPending)
        XCTAssertFalse(RegionSelection.usesCounty)
        XCTAssertTrue(RegionSelection.reload())
        XCTAssertEqual(RegionSelection.file("seattle-graph.bin"), folder.appendingPathComponent("seattle-graph.bin"))
        XCTAssertTrue(RegionSelection.usesCounty)
        XCTAssertFalse(RegionSelection.switchPending)
        // Files that fail to load: Seattle for the rest of the launch.
        RegionSelection.suppress()
        XCTAssertNil(RegionSelection.file("seattle-graph.bin"))
        XCTAssertTrue(RegionSelection.fellBack)
        XCTAssertFalse(RegionSelection.switchPending)
    }
}
