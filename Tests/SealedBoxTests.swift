#if canImport(CryptoKit)
import XCTest
@testable import PeoplemapsCore

final class SealedBoxTests: XCTestCase {
    private let plain = Data("{\"kind\":\"fix\",\"lat\":47.6295,\"lon\":-122.3599}\n".utf8)

    func testOnlyThePrivateKeyOpensABoxAndOnlyUnderItsNameAndUse() throws {
        let key = SealedBox.newKey(), other = SealedBox.newKey()
        let box = try SealedBox.seal(plain, to: key.publicKey, info: LogSeal.info, context: "use-2026-11-10.jsonl")
        XCTAssertEqual(box.prefix(7), SealedBox.magic)
        XCTAssertEqual(box.count, 7 + 32 + plain.count + 16)
        XCTAssertNil(box.range(of: Data("47.6295".utf8)), "nothing of the log is readable in the box")
        XCTAssertEqual(try SealedBox.open(box, with: key.privateKey, info: LogSeal.info, context: "use-2026-11-10.jsonl"), plain)
        XCTAssertThrowsError(try SealedBox.open(box, with: other.privateKey, info: LogSeal.info, context: "use-2026-11-10.jsonl"))
        XCTAssertThrowsError(try SealedBox.open(box, with: key.privateKey, info: LogSeal.info, context: "use-2026-11-11.jsonl"))
        XCTAssertThrowsError(try SealedBox.open(box, with: key.privateKey, info: "another use", context: "use-2026-11-10.jsonl"))
        var damaged = box
        damaged[damaged.count - 1] ^= 1
        XCTAssertThrowsError(try SealedBox.open(damaged, with: key.privateKey, info: LogSeal.info, context: "use-2026-11-10.jsonl"))
    }

    func testTwoBoxesOfTheSameBytesDiffer() throws {
        let key = SealedBox.newKey()
        XCTAssertNotEqual(try SealedBox.seal(plain, to: key.publicKey, info: "i", context: "c"), try SealedBox.seal(plain, to: key.publicKey, info: "i", context: "c"))
    }

    func testRefusesWhatIsNotABoxOrAKey() {
        let key = SealedBox.newKey()
        XCTAssertThrowsError(try SealedBox.open(plain, with: key.privateKey, info: "i", context: "c")) { XCTAssertEqual($0 as? SealedBox.Failure, .notABox) }
        XCTAssertThrowsError(try SealedBox.seal(plain, to: Data([1, 2, 3]), info: "i", context: "c")) { XCTAssertEqual($0 as? SealedBox.Failure, .badKey) }
        XCTAssertEqual(try SealedBox.publicKey(of: key.privateKey), key.publicKey)
    }

    func testTheShippedLogKeyIsAKeyAndSealsToIt() throws {
        let shipped = try XCTUnwrap(Data(base64Encoded: LogSeal.publicKey))
        XCTAssertEqual(shipped.count, 32)
        XCTAssertEqual(try LogSeal.toOwner(plain, "use-2026-11-10.jsonl").prefix(7), SealedBox.magic)
    }
}
#endif
