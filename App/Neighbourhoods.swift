import PeoplemapsCore

extension Place {
    var categoryLabel: String { Self.categoryLabel(category) }
    static func categoryLabel(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "_", with: " ")
        switch raw { case "cafe": return "Café"; default: return words.prefix(1).uppercased() + words.dropFirst() }
    }
    /// "Category · Address" when the map has the place's address, else "Category · Neighbourhood" when one is clearly
    /// nearest, else just the category. Addresses read "Address · Neighbourhood". A dropped pin named from a nearby
    /// address or place says so; an unnamed one gives its neighbourhood when clear. Both add their coordinates.
    var subtitle: String {
        if isDroppedPin {
            return (name == Self.pinName ? Neighbourhoods.nearest(to: coordinate) : Self.pinName).map { "\($0) · \(coordinateLabel)" } ?? coordinateLabel
        }
        return [categoryLabel, address ?? Neighbourhoods.nearest(to: coordinate)].compactMap { $0 }.joined(separator: " · ")
    }
    /// The place card's subtitle: "Category · Near 410 Terry Avenue North" when the place has no address of its own
    /// and `nearest` is the closest indexed one, else `subtitle`.
    func subtitle(near nearest: String?) -> String {
        guard let nearest, address == nil, kind == .place, !isDroppedPin, !isCurrentLocation else { return subtitle }
        return "\(categoryLabel) · Near \(nearest)"
    }
    var badge: PlaceBadge {
        if isCurrentLocation { return .currentLocation }
        if isDroppedPin { return .droppedPin }
        if kind == .address { return .address }
        return .category(PlaceCategory(raw: category))
    }
    var symbol: String { badge.symbol(raw: category) }
    /// An address or a dropped pin: its name says only where it is, so the user may give it one.
    var canBeNamed: Bool { kind == .address || isDroppedPin }
}
