import Foundation

/// Distances and climb in text, always imperial (feet and miles) whatever the device locale. Calculations stay in metres.
public enum DistanceFormat {
    public static let feetPerMeter = 3.28084
    public static let metersPerMile = 1609.344

    /// "300 ft", "0.4 mi", "12 mi". With `spoken`, the units are written out ("300 feet", "2 miles").
    public static func distance(_ meters: Double, spoken: Bool = false) -> String {
        let m = max(0, meters)
        let feet = m * feetPerMeter
        if feet < 528 {
            let rounded = feet < 100 ? max(10, Int((feet / 10).rounded()) * 10) : Int((feet / 50).rounded()) * 50
            return "\(rounded) \(spoken ? "feet" : "ft")"
        }
        let miles = m / metersPerMile
        if miles < 0.2 { return "\(max(550, Int((feet / 100).rounded()) * 100)) \(spoken ? "feet" : "ft")" }
        let value = miles < 10 ? String(format: "%.1f", miles) : String(format: "%.0f", miles)
        guard spoken else { return "\(value) mi" }
        let natural = value.hasSuffix(".0") ? String(value.dropLast(2)) : value
        return "\(natural) \(natural == "1" ? "mile" : "miles")"
    }

    /// Metres climbed as whole feet: "16 ft".
    public static func climb(_ meters: Double) -> String { "\(Int((max(0, meters) * feetPerMeter).rounded())) ft" }
}
