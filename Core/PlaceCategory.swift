/// The ten place groups a search-index `category` falls into. Pure data, shared by every view that draws a badge.
public enum PlaceCategory: String, CaseIterable, Sendable {
    case food, coffee, nightlife, shops, parks, sport, transit, sights, health, services

    /// Maps a raw index category. The OSM key is already lost, so `clothes`, `bicycle` and `art` are shop values.
    /// Anything not listed is `.services`.
    public init(raw: String) {
        self = Self.lookup[raw.lowercased()] ?? .services
    }

    private static let lookup: [String: PlaceCategory] = {
        var table: [String: PlaceCategory] = [:]
        for (group, values) in groups { for value in values { table[value] = group } }
        return table
    }()

    private static let groups: [(PlaceCategory, [String])] = [
        (.food, ["restaurant", "fast_food", "bakery", "deli", "ice_cream", "pastry", "food_court", "confectionery",
                 "chocolate", "seafood", "restaurants", "greengrocer"]),
        (.coffee, ["cafe", "coffee", "tea"]),
        (.nightlife, ["bar", "pub", "nightclub", "wine", "alcohol", "stripclub", "hookah_lounge", "music_venue"]),
        (.shops, ["clothes", "convenience", "supermarket", "books", "gift", "furniture", "bicycle", "art", "music",
                  "tobacco", "outdoor", "pet", "interior_decoration", "mobile_phone", "florist", "antiques", "shoes",
                  "jewelry", "photo", "musical_instrument", "frame", "sports", "doityourself", "garden_centre",
                  "e-cigarette", "paint", "cannabis", "marketplace", "trade", "second_hand", "grocery", "variety_store",
                  "beverages", "toys", "electronics", "cosmetics", "hardware", "stationery", "games", "video_games",
                  "comics", "mall", "shop", "yarn", "houseware", "kitchenware", "fashion_accessories", "perfumery",
                  "art_materials", "bed", "tyres", "car_parts", "motorcycle", "hifi", "lighting", "tiles", "carpet",
                  "general"]),
        (.parks, ["park", "garden", "wood", "water", "playground", "nature_reserve", "beach", "dog_park", "peak",
                  "paddling_pool", "fishing"]),
        (.sport, ["fitness_centre", "sports_centre", "pitch", "stadium", "swimming_pool", "dojo", "golf_course",
                  "miniature_golf", "track", "pitch_area", "sports;skate", "dance", "scuba_diving", "dancing_school"]),
        (.transit, ["station", "halt", "ferry_terminal", "bicycle_parking", "parking", "fuel", "charging_station",
                    "marina", "hotel", "car_sharing", "car_rental", "boat_rental", "boat", "slipway", "motel",
                    "guest_house", "boat_sales", "ship"]),
        (.sights, ["attraction", "museum", "viewpoint", "gallery", "artwork", "memorial", "monument", "historic",
                   "theatre", "arts_centre", "cinema", "library", "public_bookcase", "events_venue", "information",
                   "zoo", "comedy_club", "amusement_arcade", "escape_game", "maze", "event_space", "stage"]),
        (.health, ["clinic", "doctors", "dentist", "pharmacy", "hospital", "veterinary", "optician", "chemist",
                   "hearing_aids", "medical_supply", "alternative_medicine", "nursing_home", "therapist", "health_supply"]),
        (.services, ["building", "office", "craft", "hairdresser", "beauty", "bank", "atm", "school", "place_of_worship",
                     "post_office", "community_centre", "address", "social_facility", "massage", "car_repair",
                     "student_accommodation", "dry_cleaning", "kindergarten", "tattoo", "copyshop", "storage_rental",
                     "parcel_locker", "animal_boarding", "laundry", "fire_station", "tailor", "pet_grooming",
                     "music_school", "car_wash", "yes", "studio", "research_institute", "locksmith", "college",
                     "childcare", "university", "ticket", "hackerspace", "give_box", "police", "spa", "unknown"]),
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
