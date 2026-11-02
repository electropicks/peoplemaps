/// The ten place groups a search-index `category` falls into. Pure data, shared by every view that draws a badge.
public enum PlaceCategory: String, CaseIterable, Sendable {
    case food, coffee, nightlife, shops, parks, sport, transit, sights, health, services

    /// Maps a raw index category. The OSM key is already lost, so `clothes`, `bicycle` and `art` are shop values.
    /// Anything not listed is `.services`.
    public init(raw: String) {
        let raw = raw.lowercased()
        self = Self.lookup[raw] ?? Self.bySuffix(raw) ?? .services
    }

    /// Overture's long tail names its kind in the last word ("thai_restaurant", "shoe_store", "pediatric_clinic").
    private static func bySuffix(_ raw: String) -> PlaceCategory? {
        suffixes.first { $0.endings.contains { raw.hasSuffix($0) } }?.group
    }

    private static let suffixes: [(group: PlaceCategory, endings: [String])] = [
        (.food, ["_restaurant"]),
        (.health, ["_clinic", "_medicine", "_therapy", "_surgery", "ology", "iatry", "_health_care", "_care_facility", "_treatment_center"]),
        (.shops, ["_store", "_shop", "_boutique", "_market"]),
        (.sport, ["_gym", "_field", "_court"]),
    ]

    private static let lookup: [String: PlaceCategory] = {
        var table: [String: PlaceCategory] = [:]
        for (group, values) in groups { for value in values { table[value] = group } }
        return table
    }()

    private static let groups: [(PlaceCategory, [String])] = [
        (.food, ["restaurant", "fast_food", "bakery", "deli", "ice_cream", "pastry", "food_court", "confectionery",
                 "chocolate", "seafood", "restaurants", "greengrocer", "food_truck_stand", "sandwich_shop", "delicatessen", "diner",
                 "ice_cream_shop", "dessert_shop", "donut_shop", "bagel_shop", "steakhouse", "salad_bar", "smoothie_juice_bar",
                 "chocolatier", "soul_food", "food_and_drink", "butcher", "butcher_shop", "fishmonger", "seafood_market"]),
        (.coffee, ["cafe", "coffee", "tea", "tea_room", "bubble_tea_shop"]),
        (.nightlife, ["bar", "pub", "nightclub", "wine", "alcohol", "stripclub", "hookah_lounge", "music_venue", "brewery", "winery",
                      "distillery", "tapas_bar", "dance_club", "nightlife_venue", "adult_entertainment_venue"]),
        (.shops, ["shopping", "cannabis_dispensary", "clothes","convenience", "supermarket", "books", "gift", "furniture", "bicycle", "art", "music",
                  "tobacco", "outdoor", "pet", "interior_decoration", "mobile_phone", "florist", "antiques", "shoes",
                  "jewelry", "photo", "musical_instrument", "frame", "sports", "doityourself", "garden_centre",
                  "e-cigarette", "paint", "cannabis", "marketplace", "trade", "second_hand", "grocery", "variety_store",
                  "beverages", "toys", "electronics", "cosmetics", "hardware", "stationery", "games", "video_games",
                  "comics", "mall", "shop", "yarn", "houseware", "kitchenware", "fashion_accessories", "perfumery",
                  "art_materials", "bed", "tyres", "car_parts", "motorcycle", "hifi", "car", "lighting", "tiles", "carpet",
                  "general",
                  "kitchen", "bridal", "window_blind", "rugs", "posters", "printer_ink", "video", "vacuum_cleaner", "upholstery", "flooring", "fireplace", "glass", "cabinets", "building_supply", "bathroom_supply_store", "bathroom_furnishing", "canvas", "computer", "clock", "plants", "pottery", "nutrition_supplements", "herbalist", "esoteric", "concrete", "hairdresser_supply", "erotic", "pawnbroker", "marine_supply", "ship_chandler", "university_bookstore", "charity"]),
        (.parks, ["park", "garden", "wood", "water", "playground", "nature_reserve", "beach", "dog_park", "peak",
                  "paddling_pool", "fishing", "picnic_site", "skate_park", "public_plaza"]),
        (.sport, ["fitness_centre", "sports_centre", "pitch", "stadium", "swimming_pool", "dojo", "golf_course",
                  "miniature_golf", "track", "pitch_area", "sports;skate", "dance", "scuba_diving", "dancing_school",
                  "sports_and_recreation", "sport_or_fitness_facility", "sport_or_recreation_club", "sport_league", "yoga_studio",
                  "pilates_studio", "dance_studio", "martial_arts_club", "fitness_trainer", "gymnastics_center", "soccer_club",
                  "sailing_club", "bowling_alley", "boot_camp"]),
        (.transit, ["station", "halt", "ferry_terminal", "bicycle_parking", "parking", "fuel", "charging_station",
                    "marina", "hotel", "car_sharing", "car_rental", "boat_rental", "boat", "slipway", "motel",
                    "guest_house", "boat_sales", "ship", "travel_and_transportation", "airport", "airport_shuttle", "ev_charging_station",
                    "public_transit_facility_or_service", "boat_rental_and_training", "pier"]),
        (.sights, ["attraction", "museum", "viewpoint", "gallery", "artwork", "memorial", "monument", "historic",
                   "theatre", "arts_centre", "cinema", "library", "public_bookcase", "events_venue", "information",
                   "zoo", "comedy_club", "amusement_arcade", "escape_game", "maze", "event_space", "stage",
                   "arts_and_entertainment", "aquarium", "festival_venue", "escape_room", "casino", "boat_tour", "sightseeing_tour_agency"]),
        (.health, ["clinic", "doctors", "dentist", "pharmacy", "hospital", "veterinary", "optician", "chemist",
                   "hearing_aids", "medical_supply", "alternative_medicine", "nursing_home", "therapist", "health_supply",
                   "health_care", "counseling", "chiropractic", "acupuncture", "psychotherapy", "nursing", "surgery", "optometry",
                   "orthopedics", "podiatry", "family_practice", "family_counseling", "emergency_department", "diagnostic_imaging",
                   "laboratory_testing", "ear_nose_and_throat", "midwifery", "drugstore", "surgery_center", "rehabilitation_center",
                   "maternity_center", "retirement_home"]),
        (.services, ["massage_therapy", "auto_body_shop", "tire_shop", "building","office", "craft", "hairdresser", "beauty", "bank", "atm", "school", "place_of_worship",
                     "post_office", "community_centre", "address", "social_facility", "massage", "car_repair",
                     "student_accommodation", "dry_cleaning", "kindergarten", "tattoo", "copyshop", "storage_rental",
                     "parcel_locker", "animal_boarding", "laundry", "fire_station", "tailor", "pet_grooming",
                     "music_school", "car_wash", "yes", "studio", "research_institute", "locksmith", "college",
                     "childcare", "university", "ticket", "hackerspace", "give_box", "police", "spa", "unknown",
                     "travel_agency", "telecommunication", "repair", "rental", "motorcycle_repair", "social_club", "signs", "sign", "shoe_repair", "self_storage", "recycling", "funeral_directors", "delivery_locker", "coworking_space", "townhall", "study_lounge", "social_centre", "rug_cleaning", "printing", "post_depot", "plumbing", "mailing_center", "makerspace", "financial_advice", "courthouse", "conference_centre", "car_detail", "boat_repair", "apartment", "manufacturer", "driving_school", "sauna", "public_bath", "prep_school", "trade_school", "training", "classes", "cooking_school", "tool_library", "electronics_repair", "psychic", "animal_shelter", "animal_service"]),
    ]

    /// The SF Symbol for a badge of this group; `raw` picks a more specific one for transit and sights.
    public func symbol(for raw: String? = nil) -> String {
        let raw = raw?.lowercased() ?? ""
        switch self {
        case .food: return "fork.knife"
        case .coffee: return "cup.and.saucer.fill"
        case .nightlife: return "wineglass.fill"
        case .shops: return "bag.fill"
        case .parks: return "leaf.fill"
        case .sport: return "figure.run"
        case .health: return "cross.case.fill"
        case .transit:
            switch raw {
            case "ferry_terminal", "marina", "boat", "boat_rental", "boat_sales", "slipway", "ship": return "ferry.fill"
            case "bicycle_parking": return "bicycle"
            case "parking": return "parkingsign"
            case "fuel": return "fuelpump.fill"
            case "charging_station": return "bolt.car.fill"
            case "hotel", "motel", "guest_house": return "bed.double.fill"
            default: return "tram.fill"
            }
        case .sights:
            switch raw {
            case "museum": return "building.columns.fill"
            case "viewpoint": return "binoculars.fill"
            case "theatre", "cinema", "comedy_club": return "theatermasks.fill"
            case "library", "public_bookcase": return "books.vertical.fill"
            case "gallery", "artwork", "arts_centre": return "paintpalette.fill"
            default: return "star.fill"
            }
        case .services:
            return raw == "building" || raw == "office" ? "building.2.fill" : "mappin"
        }
    }

    /// The symbol for a raw category string.
    public static func symbol(for raw: String) -> String { PlaceCategory(raw: raw).symbol(for: raw) }
}

/// What a place's circular badge shows. The fixed kinds keep their own look; everything else is a category group.
public enum PlaceBadge: Equatable, Sendable {
    case category(PlaceCategory), currentLocation, address, droppedPin

    /// The SF Symbol; `raw` (the place's category string) refines transit and sights.
    public func symbol(raw: String? = nil) -> String {
        switch self {
        case .category(let group): group.symbol(for: raw)
        case .currentLocation: "location.fill"
        case .address, .droppedPin: "mappin"
        }
    }
}
