import Foundation

/// Which way the person faces while guiding: GPS course when moving, the phone's compass when slow or stopped
/// (`Docs/NAVIGATION.md`, "Camera and heading while guiding").
///
/// Course is only meaningful at speed, and at a light or at the start of a trip it is missing or noise, while the compass
/// still knows. Course takes over at `courseSpeed` and hands back below `releaseSpeed` (a gap, so the source does not flicker
/// around the threshold). Every hand-over fades over `blendSeconds` along the shorter arc, so the marker never jumps.
public struct HeadingBlender: Equatable, Sendable {
    /// Metres per second from which GPS course is trusted.
    public static let courseSpeed = 2.0
    /// Below this the compass takes over again.
    public static let releaseSpeed = 1.5
    public static let blendSeconds = 0.6

    /// 0 is all compass, 1 is all course.
    public private(set) var courseWeight = 0.0
    private var usingCourse = false
    private var last: Date?

    public init() {}

    /// The heading to show in degrees from north, or nil when nothing is known and the caller keeps what it had.
    /// `course` is nil when invalid. A nil `speed` with a known course counts as moving (the simulated provider has none).
    public mutating func update(course: Double?, speed: Double?, compass: Double?, at now: Date) -> Double? {
        if course == nil { usingCourse = false }
        else if let speed { usingCourse = speed >= Self.courseSpeed || (usingCourse && speed >= Self.releaseSpeed) }
        else { usingCourse = true }
        defer { last = now }
        switch (course, compass) {
        case (nil, nil): return nil
        case (nil, let compass?): courseWeight = 0; return Self.normalized(compass)
        case (let course?, nil):
            // No compass: course while moving, nothing new while stopped (it is noise then).
            courseWeight = usingCourse ? 1 : 0
            return usingCourse ? Self.normalized(course) : nil
        case let (course?, compass?):
            let target = usingCourse ? 1.0 : 0.0
            if let last { 
                let step = max(0, now.timeIntervalSince(last)) / Self.blendSeconds
                courseWeight = courseWeight < target ? min(target, courseWeight + step) : max(target, courseWeight - step)
            } else { courseWeight = target }
            return Self.mix(compass, course, courseWeight)
        }
    }

    /// `from` turned `weight` of the way to `to` along the shorter arc.
    static func mix(_ from: Double, _ to: Double, _ weight: Double) -> Double {
        if weight <= 0 { return normalized(from) }
        if weight >= 1 { return normalized(to) }
        return normalized(from + shortestDelta(from, to) * weight)
    }

    /// Signed degrees from `from` to `to`, in -180...180.
    static func shortestDelta(_ from: Double, _ to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        return delta
    }

    static func normalized(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }
}
