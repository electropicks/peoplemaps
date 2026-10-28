import Foundation

/// Distances in text, in the device's units: feet and miles in the US, metres and kilometres elsewhere.
enum NavigationFormat {
    static var usesImperial: Bool { Locale.current.measurementSystem == .us }

    /// "300 ft", "0.4 mi", "250 m", "1.2 km". With `spoken`, the units are written out ("300 feet").
    static func distance(_ meters: Double, spoken: Bool = false) -> String {
        let m = max(0, meters)
        if usesImperial {
            let feet = m * 3.28084
            if feet < 528 {
                let rounded = feet < 100 ? max(10, Int((feet / 10).rounded()) * 10) : Int((feet / 50).rounded()) * 50
                return "\(rounded) \(spoken ? "feet" : "ft")"
            }
            let miles = m / 1609.344
            if miles < 0.2 { return "\(Int((feet / 100).rounded()) * 100) \(spoken ? "feet" : "ft")" }
            let value = miles < 10 ? String(format: "%.1f", miles) : String(format: "%.0f", miles)
            return spoken ? "\(value) \(value == "1.0" ? "mile" : "miles")" : "\(value) mi"
        }
        if m < 1000 {
            let rounded = m < 100 ? max(10, Int((m / 10).rounded()) * 10) : Int((m / 50).rounded()) * 50
            return "\(rounded) \(spoken ? "metres" : "m")"
        }
        let km = m / 1000
        let value = km < 10 ? String(format: "%.1f", km) : String(format: "%.0f", km)
        return spoken ? "\(value) \(value == "1.0" ? "kilometre" : "kilometres")" : "\(value) km"
    }

    static func minutes(_ seconds: Double) -> Int { max(1, Int((seconds / 60).rounded(.up))) }
}
