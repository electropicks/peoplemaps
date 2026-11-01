import XCTest
@testable import PeoplemapsCore

final class PlaceCategoryTests: XCTestCase {
    /// The 80 most common raw categories in the Oct 2026 search index (excluding address rows), with their group.
    private static let top80: [(String, PlaceCategory)] = [
        ("building", .services), ("restaurant", .food), ("office", .services), ("cafe", .coffee), ("artwork", .sights),
        ("fitness_centre", .sport), ("park", .parks), ("fast_food", .food), ("hairdresser", .services),
        ("parking", .transit), ("bar", .nightlife), ("beauty", .services), ("place_of_worship", .services),
        ("pub", .nightlife), ("dentist", .health), ("clothes", .shops), ("craft", .services), ("convenience", .shops),
        ("bank", .services), ("school", .services), ("public_bookcase", .sights), ("social_facility", .services),
        ("massage", .services), ("car_repair", .services), ("hotel", .transit), ("clinic", .health),
        ("supermarket", .shops), ("bicycle_parking", .transit), ("doctors", .health), ("student_accommodation", .services),
        ("fuel", .transit), ("dry_cleaning", .services), ("veterinary", .health), ("sports_centre", .sport),
        ("memorial", .sights), ("library", .sights), ("bakery", .food), ("gift", .shops), ("marina", .transit),
        ("historic", .sights), ("books", .shops), ("kindergarten", .services), ("ice_cream", .food),
        ("theatre", .sights), ("tattoo", .services), ("post_office", .services), ("furniture", .shops),
        ("community_centre", .services), ("pitch", .sport), ("optician", .health), ("information", .sights),
        ("atm", .services), ("wood", .parks), ("music", .shops), ("cannabis", .shops), ("bicycle", .shops),
        ("attraction", .sights), ("garden", .parks), ("art", .shops), ("tobacco", .shops), ("outdoor", .shops),
        ("copyshop", .services), ("pet", .shops), ("water", .parks), ("storage_rental", .services),
        ("pharmacy", .health), ("interior_decoration", .shops), ("wine", .nightlife), ("museum", .sights),
        ("mobile_phone", .shops), ("deli", .food), ("charging_station", .transit), ("arts_centre", .sights),
        ("boat", .transit), ("trade", .shops), ("playground", .parks), ("pastry", .food), ("nightclub", .nightlife),
        ("florist", .shops), ("events_venue", .sights),
    ]

    func testTop80() {
        XCTAssertEqual(Self.top80.count, 80)
        for (raw, group) in Self.top80 { XCTAssertEqual(PlaceCategory(raw: raw), group, raw) }
    }

    func testNamedExamples() {
        XCTAssertEqual(PlaceCategory(raw: "restaurant"), .food)
        XCTAssertEqual(PlaceCategory(raw: "cafe"), .coffee)
        XCTAssertEqual(PlaceCategory(raw: "park"), .parks)
        XCTAssertEqual(PlaceCategory(raw: "clothes"), .shops)
        XCTAssertEqual(PlaceCategory(raw: "Therapist"), .health)
    }

    func testLongTail() {
        let expected: [(String, PlaceCategory)] = [
            ("coffee", .coffee), ("hospital", .health), ("zoo", .sights), ("toys", .shops), ("travel_agency", .services),
            ("kitchen", .shops), ("plants", .shops), ("flooring", .shops), ("townhall", .services), ("courthouse", .services),
            ("swimming_pool", .sport), ("golf_course", .sport), ("cinema", .sights), ("greengrocer", .food),
            ("beverages", .shops), ("stripclub", .nightlife), ("motel", .transit), ("hearing_aids", .health),
        ]
        for (raw, group) in expected { XCTAssertEqual(PlaceCategory(raw: raw), group, raw) }
        for raw in ["proposed", "vacant", "street_vendor", "shelter"] { XCTAssertEqual(PlaceCategory(raw: raw), .services, raw) }
    }

    func testUnknownIsServices() {
        XCTAssertEqual(PlaceCategory(raw: "no_such_category"), .services)
        XCTAssertEqual(PlaceCategory(raw: ""), .services)
    }

    func testSymbols() {
        XCTAssertEqual(PlaceCategory.symbol(for: "restaurant"), "fork.knife")
        XCTAssertEqual(PlaceCategory.symbol(for: "station"), "tram.fill")
        XCTAssertEqual(PlaceCategory.symbol(for: "ferry_terminal"), "ferry.fill")
        XCTAssertEqual(PlaceCategory.symbol(for: "parking"), "parkingsign")
        XCTAssertEqual(PlaceCategory.symbol(for: "museum"), "building.columns.fill")
        XCTAssertEqual(PlaceCategory.symbol(for: "viewpoint"), "binoculars.fill")
        XCTAssertEqual(PlaceCategory.symbol(for: "attraction"), "star.fill")
        XCTAssertEqual(PlaceCategory.symbol(for: "building"), "building.2.fill")
        XCTAssertEqual(PlaceCategory.symbol(for: "bank"), "mappin")
        for group in PlaceCategory.allCases { XCTAssertFalse(group.symbol().isEmpty) }
    }

    func testBadgeSymbols() {
        XCTAssertEqual(PlaceBadge.currentLocation.symbol(), "location.fill")
        XCTAssertEqual(PlaceBadge.address.symbol(), "mappin")
        XCTAssertEqual(PlaceBadge.droppedPin.symbol(), "mappin")
        XCTAssertEqual(PlaceBadge.category(.sights).symbol(raw: "museum"), "building.columns.fill")
        XCTAssertEqual(PlaceBadge.category(.parks).symbol(), "leaf.fill")
    }
}
