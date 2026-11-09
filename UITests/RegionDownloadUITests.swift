import XCTest
import CryptoKit

/// The Map section of Settings. The offer reads the app's real manifest; the download tests point the app at a small server in this
/// process (`--region-server`) and a made-up manifest (`--region-manifest-json`), so no real county data moves.
final class RegionDownloadUITests: PeoplemapsUITestCase {
    private var server: TinyHTTPServer?

    override func tearDown() { server?.stop(); super.tearDown() }

    /// Launch arguments for a tiny region under the name the app offers, plus the server holding its files.
    @MainActor private func tinyRegionArguments(stallGraph: Bool = false) throws -> [String] {
        let graph = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let map = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let search = Data(String(repeating: "calmer streets\n", count: 5_000).utf8)
        let served: [(String, Data)] = [("expected/seattle-graph.bin", graph), ("expected/seattle-map.pmtiles", map),
                                        ("expected/seattle-search.sqlite.gz", Self.gzip(search)),
                                        ("expected/seattle-coverage.json", Data(#"{"bbox":[1,2,3,4],"rings":[]}"#.utf8)),
                                        ("expected/provenance.json", Data("{}".utf8))]
        var objects: [String: Data] = [:], files: [String: [String: Any]] = [:]
        for (path, data) in served {
            objects["king-county--" + path.replacingOccurrences(of: "/", with: "__")] = data
            files[path] = ["bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        let server = try TinyHTTPServer(files: objects)
        self.server = server
        let manifest: [String: Any] = ["release": "data-ui-test", "regions": ["king-county": [
            "bbox": [1, 2, 3, 4], "files": files, "outputs": served.map { String($0.0.dropFirst(9)) }]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self)
        return ["--region-server", server.baseURL.absoluteString, "--region-manifest-json", json]
    }

    /// The Map section is the first on Settings, so its rows need no scrolling.
    @MainActor private func openMapArea(_ app: XCUIApplication) {
        openSettings(app)
        XCTAssertTrue(app.descendants(matching: .any)["region-current"].waitForExistence(timeout: 5))
    }

    @MainActor func testTheOfferShowsTheManifestsDownloadSizeAndSpace() {
        let app = launchHome()
        openMapArea(app)
        // Data/regions.json: the five king-county outputs add up to 232,312,020 bytes.
        let download = app.buttons["region-download"]
        XCTAssertTrue(download.isHittable, app.debugDescription)
        XCTAssertTrue(rowText(download).contains("Download King County"), rowText(download))
        XCTAssertTrue(rowText(download).contains("232.3 MB"), rowText(download))
        let footer = app.staticTexts["region-footer"].label
        XCTAssertTrue(footer.hasPrefix("The whole county and 3 miles beyond, about 350 MB on your phone."), footer)
        let current = rowText(app.descendants(matching: .any)["region-current"])
        XCTAssertTrue(current.contains("On this phone") && current.contains("Seattle"), current)
        capture("region-offer", app: app)
    }

    @MainActor func testDownloadsATinyRegionAndShowsReady() throws {
        let app = launchHome(extra: try tinyRegionArguments())
        openMapArea(app)
        app.buttons["region-download"].tap()
        let status = app.staticTexts["region-status"]
        let ready = NSPredicate { _, _ in status.exists && status.label.hasPrefix("Ready") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 40), .completed, "Status: \(status.label)")
        XCTAssertEqual(status.label, "Ready. Switches at next launch")
        XCTAssertTrue(app.buttons["region-switch"].exists, "No route is showing, so the map may switch now")
        XCTAssertEqual(Set(server?.requests.map(\.path) ?? []).count, 5, "Only the five outputs were asked for")
        capture("region-ready", app: app)
    }

    @MainActor func testPauseKeepsTheBytesAndResumeFinishes() throws {
        let arguments = try tinyRegionArguments()
        let graph = "king-county--expected__seattle-graph.bin"
        server?.stall(graph, after: 100_000)
        let app = launchHome(extra: arguments)
        openMapArea(app)
        app.buttons["region-download"].tap()
        XCTAssertTrue(app.buttons["region-pause"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["region-bytes"].exists)
        capture("region-progress", app: app)
        app.buttons["region-pause"].tap()
        XCTAssertTrue(app.buttons["region-resume"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["region-status"].label, "Paused")
        server?.release(graph)
        app.buttons["region-resume"].tap()
        let ready = NSPredicate { _, _ in app.staticTexts["region-status"].label.hasPrefix("Ready") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 40), .completed)
    }

    @MainActor func testAFailedDownloadShowsTheReasonAndRetry() throws {
        let arguments = try tinyRegionArguments()
        server?.replace("king-county--expected__seattle-map.pmtiles", with: Data(repeating: 1, count: 10_000))   // right size, wrong bytes
        let app = launchHome(extra: arguments)
        openMapArea(app)
        app.buttons["region-download"].tap()
        XCTAssertTrue(app.buttons["region-retry"].waitForExistence(timeout: 40))
        XCTAssertTrue(app.staticTexts["region-status"].label.contains("nothing was installed"), app.staticTexts["region-status"].label)
        XCTAssertFalse(app.buttons["region-switch"].exists)
        capture("region-failed", app: app)
    }

    @MainActor func testRemoveReturnsToTheOffer() throws {
        let app = launchHome(extra: try tinyRegionArguments())
        openMapArea(app)
        app.buttons["region-download"].tap()
        XCTAssertTrue(app.buttons["region-remove"].waitForExistence(timeout: 40))
        app.buttons["region-remove"].tap()
        // The row says "Remove King County"; the confirmation's button is the only plain "Remove".
        let confirm = app.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["region-download"].waitForExistence(timeout: 10))
    }

    /// The made-up files are not a map, so the next launch cannot load them: Seattle shows, and Settings says why.
    @MainActor func testADownloadedRegionThatWillNotLoadFallsBackToSeattle() throws {
        let arguments = try tinyRegionArguments()
        var app = launchHome(extra: arguments)
        openMapArea(app)
        app.buttons["region-download"].tap()
        XCTAssertTrue(app.buttons["region-remove"].waitForExistence(timeout: 40))
        app.terminate()

        app = launchHome(extra: arguments + ["--keep-regions"])
        XCTAssertEqual(app.buttons["search-field"].label, "Where to?", "Home still works on the bundled map")
        openMapArea(app)
        let fallback = app.staticTexts["region-fallback"]
        // openMapArea may have scrolled past it, either way: look both directions.
        for _ in 0..<4 where !(fallback.exists && fallback.isHittable) { app.collectionViews.firstMatch.swipeDown() }
        for _ in 0..<4 where !(fallback.exists && fallback.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(app.staticTexts["region-fallback"].waitForExistence(timeout: 5))
        capture("region-fallback", app: app)
    }

    /// One gzip member in stored blocks, so the app's unpacking runs on real gzip framing.
    private static func gzip(_ data: Data) -> Data {
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
        var offset = 0
        repeat {
            let n = min(65535, data.count - offset)
            out += [offset + n >= data.count ? 1 : 0, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
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
