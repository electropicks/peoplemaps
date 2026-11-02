import XCTest
@testable import PeoplemapsCore

final class MapTilesTests: XCTestCase {
    func testBundledTilesAreAPMTilesArchiveCoveringTheGraph() throws {
        let url = try XCTUnwrap(StreetGraph.mapURL)
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        XCTAssertEqual(Array(bytes.prefix(8)), Array("PMTiles".utf8) + [3])
        XCTAssertEqual(bytes[97], 1, "directories are uncompressed")
        XCTAssertEqual(bytes[98], 1, "tiles are uncompressed")
        XCTAssertEqual(bytes[99], 1, "tile type is MVT")
        XCTAssertEqual(bytes[100], 8)
        XCTAssertEqual(bytes[101], 14)
        func e7(_ offset: Int) -> Double {
            let raw = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
            return Double(Int32(bitPattern: raw)) / 1e7
        }
        let (west, south, east, north) = (e7(102), e7(106), e7(110), e7(114))
        let b = try StreetGraph.bundled().bounds  // S, W, N, E
        XCTAssertLessThanOrEqual(west, b[1]); XCTAssertLessThanOrEqual(south, b[0])
        XCTAssertGreaterThanOrEqual(east, b[3]); XCTAssertGreaterThanOrEqual(north, b[2])
    }
}
