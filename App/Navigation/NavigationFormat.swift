import Foundation
import PeoplemapsCore

enum NavigationFormat {
    /// Imperial whatever the locale; see `DistanceFormat`.
    static func distance(_ meters: Double, spoken: Bool = false) -> String { DistanceFormat.distance(meters, spoken: spoken) }

    static func minutes(_ seconds: Double) -> Int { max(1, Int((seconds / 60).rounded(.up))) }
}
