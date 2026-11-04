import XCTest
@testable import PeoplemapsCore

final class HeadingBlenderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testStoppedUsesCompassEvenWithACourse() {
        var b = HeadingBlender()
        XCTAssertEqual(b.update(course: 200, speed: 0.3, compass: 40, at: t0)!, 40, accuracy: 0.001)
    }

    func testInvalidCourseUsesCompass() {
        var b = HeadingBlender()
        XCTAssertEqual(b.update(course: nil, speed: 10, compass: 123, at: t0)!, 123, accuracy: 0.001)
    }

    func testFastUsesCourse() {
        var b = HeadingBlender()
        XCTAssertEqual(b.update(course: 90, speed: 8, compass: 270, at: t0)!, 90, accuracy: 0.001)
    }

    func testHandOverBlendsOverTheBlendTimeAndNeverJumps() {
        var b = HeadingBlender()
        _ = b.update(course: 90, speed: 0.5, compass: 70, at: t0)
        var previous = 70.0
        var now = t0
        var reached = false
        for _ in 0..<10 {
            now = now.addingTimeInterval(0.1)
            let h = b.update(course: 90, speed: 6, compass: 70, at: now)!
            XCTAssertGreaterThanOrEqual(h, previous)
            XCTAssertLessThanOrEqual(h - previous, 20 * 0.1 / HeadingBlender.blendSeconds + 0.001, "A step of the blend must stay small")
            previous = h
            if h == 90 { reached = true }
        }
        XCTAssertTrue(reached, "Course should be in full after the blend time")
        XCTAssertEqual(b.courseWeight, 1)
    }

    func testBlendTakesTheShorterArcAcrossNorth() {
        XCTAssertEqual(HeadingBlender.mix(350, 10, 0.5), 0, accuracy: 0.001)
        XCTAssertEqual(HeadingBlender.mix(10, 350, 0.25), 5, accuracy: 0.001)
        XCTAssertEqual(HeadingBlender.mix(10, 350, 0), 10)
        XCTAssertEqual(HeadingBlender.mix(10, 350, 1), 350)
    }

    func testHysteresisKeepsCourseBetweenReleaseAndCourseSpeed() {
        var b = HeadingBlender()
        var now = t0
        _ = b.update(course: 90, speed: 5, compass: 0, at: now)
        now = now.addingTimeInterval(1)
        XCTAssertEqual(b.update(course: 90, speed: 1.7, compass: 0, at: now)!, 90, accuracy: 0.001, "Between 1.5 and 2 m/s course stays")
        now = now.addingTimeInterval(1)
        XCTAssertEqual(b.update(course: 90, speed: 1.0, compass: 0, at: now)!, 0, accuracy: 0.001, "Below 1.5 m/s the compass is back after a second")
        var c = HeadingBlender()
        XCTAssertEqual(c.update(course: 90, speed: 1.7, compass: 0, at: t0)!, 0, accuracy: 0.001, "From a stop it takes 2 m/s to engage course")
    }

    func testUnknownSpeedWithCourseCountsAsMoving() {
        var b = HeadingBlender()
        XCTAssertEqual(b.update(course: 33, speed: nil, compass: 200, at: t0)!, 33, accuracy: 0.001)
    }

    func testNoCompassFallsBackToCourseOnlyWhileMoving() {
        var b = HeadingBlender()
        XCTAssertEqual(b.update(course: 33, speed: 6, compass: nil, at: t0)!, 33, accuracy: 0.001)
        var s = HeadingBlender()
        XCTAssertNil(s.update(course: 33, speed: 0.2, compass: nil, at: t0), "Stopped course without a compass is noise")
        XCTAssertNil(s.update(course: nil, speed: nil, compass: nil, at: t0))
    }

    func testNegativeAndLargeDegreesAreNormalised() {
        var b = HeadingBlender()
        XCTAssertEqual(b.update(course: nil, speed: nil, compass: -10, at: t0)!, 350, accuracy: 0.001)
        XCTAssertEqual(b.update(course: nil, speed: nil, compass: 370, at: t0)!, 10, accuracy: 0.001)
    }
}
