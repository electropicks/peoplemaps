# Search plan

Drafted 28 October 2026. Goal: navigate to any address, place or business in
Seattle, offline, with the same honesty rules as routing. Screens: the
"finding a place" rows of the design canvas
(https://claude.ai/artifact/HW5tDWwDFUmweSopZpuroE).

Stages 1 and 2 are built: `SearchIndex` (`Core/SearchIndex.swift`) searches OSM
named places, Overture Maps businesses and OSM street addresses offline.
Coverage stops at the routing bounds (47.615–47.678 N, 122.390–122.300 W).

## Apple's terms rule out an Apple layer

The plan was an offline open index with live MapKit search (`MKLocalSearch`,
`MKLocalSearchCompleter`, geocoding) merged on top when online. The Apple
Developer Program License Agreement, Attachment 6 ("Use of the Apple Maps
Service"), does not allow that with our MapLibre map:

- **2.4:** Map Data shown on a map must be shown "only on an Apple map", and an
  app may not surface Map Data (their example is an address result) without
  the corresponding Apple map.
- **2.5:** Map Data may not be cached or stored beyond temporary use, so
  saving Apple results as favourites or mixing them into our index is out.
- **2.2–2.3:** no derived databases, and no using Apple data to improve
  another mapping service.

Points of interest, coordinates and addresses all count as Map Data (section
1.2). Switching the whole map to MapKit would break offline use and our own
styling, so it is not an option either.

**Allowed, and kept:** a "Look up in Apple Maps" button for queries we cannot
answer. It opens the Apple Maps app (`MKMapItem.openInMaps`) and hands the
user off. Showing nothing from Apple inside PeopleMaps is what keeps this within
the terms.

**Decided 10 November 2026: links the user brings are accepted as search
hints.** A link shared or pasted from Apple Maps is supplied by the user, not
obtained by us from the Apple Maps Service, and Apple documents how to expand
its short links. It is still a grey area, so the handling is conservative; see
"Shared links" below. `CLGeocoder` (Core Location) falls outside the "Apple
Maps Service" definition on paper but returns Apple data, so do not rely on it.

## Design: one offline index from open data

| Source | Gives | Licence |
|---|---|---|
| OpenStreetMap (snapshot we already import) | named places, shops, parks, streets, some addresses | ODbL 1.0 |
| Overture Maps Places (release 2026-10-21.0) | businesses and points of interest, with categories | per source: CDLA-Permissive 2.0 (Meta, Microsoft, BrightQuery and others), Apache 2.0 (Foursquare), CC0 1.0 (AllThePlaces); see `Data/LICENSE.md` |
| City of Seattle / King County address points | every street address with a point | not used: terms don't clearly allow redistribution (see `Data/LICENSE.md`); OSM has about as many points |

- **Built by the importer.** `Scripts/import_osm.py` calls
  `Scripts/build_search.py`, which joins the sources, removes duplicates (same
  normalised name within about 50 m, or 250 m for parks and civic places; OSM
  wins on name and position, and Overture fills in the category of an OSM place
  that only has a building or office tag), and writes a SQLite database with an
  FTS5 table. It ships gzipped and is inflated at first launch, like the graph.
  Each row has a `source` column (`OpenStreetMap`, `Overture · Foursquare`, ...)
  and the meta table records the Overture release.
- **Query.** Prefix matching as you type, ranked by text match, then category
  weight (landmarks and parks over shops), then distance from the map centre
  or the user. House numbers parse into an address lookup ("3329 Fremont Ave
  N"). Typos are tolerated with a trigram fallback.
- **Snapping.** Each result stores its nearest routable node per mode, so
  routing starts without a search for the nearest road.
- **Size.** Measured in stage 1 for the routing bounds (6,742 places, 50,026
  addresses): 3.4 MB gzipped, 11.7 MB inflated. All of Seattle is roughly 8×
  the area, so expect tens of MB inflated; check before stage 4.
- **Honesty.** Open data goes stale. Business results show their source and
  date ("OpenStreetMap, Oct 2026", "Overture (Foursquare), Oct 2026"; the date
  is the release's, not the record's age). Missing opening hours stay missing,
  never guessed.

## Also in scope

- **My location as the start.** The app asks once, on first launch. When
  allowed, routes start from "Current location", which heads the origin list.
  If it is denied, the start is an empty "Choose start" field, the list hides
  that row, and nothing asks again.
- **Near an address.** A place with no address of its own shows the nearest
  indexed address within 40 m ("Near 211 West Highland Drive"), else its
  neighbourhood (`SearchIndex.nearestAddress`). Neighbourhoods are centroids,
  not boundaries, so one shows only within 800 m and when no other centroid is
  within 1.5 times as far (`Neighbourhoods.nearest`); otherwise no label.
- **Drop a pin.** Long-press the map. The pin takes the name of the nearest
  address or place within 50 m (`SearchIndex.droppedPin`): plainly within 15 m,
  as "Near ..." farther out, since the pin is not the thing itself. With
  nothing close it stays "Dropped pin" with its neighbourhood (when clear) and
  coordinates.
- **Category words.** "gas station", "coffee", "grocery", "pharmacy" and the
  like map to index categories (`SearchIndex.categoryWords`, query side) and
  list those places after the name matches, ahead of text found only in a
  category or address.
- **Start outside the map.** When the start is outside the routing bounds
  (`graph.contains`), the preview says so and offers "Choose start"; the router
  throws `RoutingError.startOutsideCoverage`.
- **Recents and favourites.** Stored on the device as our own place IDs and
  coordinates.

## Overture places (stage 2)

- **Archive.** Overture keeps only its last two releases online (about 60
  days), so `Scripts/fetch_overture.py` stores a bounded extract in
  `Data/seattle-overture-places.json.gz`: release 2026-10-21.0, every place in
  the all-Seattle box (47.49–47.74 N, 122.44–122.24 W), so the same file serves
  stage 4. It reads Overture's public S3 bucket with pyarrow only (not run by the
  importer; needs `pip install pyarrow`), downloads just the Parquet row groups
  whose bbox statistics overlap the box (about 50 MB of 12 GB), and keeps name,
  position, taxonomy, confidence, status, freeform address and the sources. No
  phones, emails, websites, socials or brands. The importer records the
  archive's SHA-256, release and fetch date in `Data/provenance.json`.
- **Licences are per source**, not one for the theme: CDLA-Permissive 2.0
  (Meta, Microsoft, BrightQuery, PinMeTo, Uberall, DAC, Krick, RenderSEO,
  Birdeye, OpenTravel), Apache 2.0 (Foursquare, with its NOTICE) and CC0 1.0
  (AllThePlaces). Texts are in `Data/licenses/`. The only condition on
  CDLA-Permissive data is to include the licence text when sharing. The importer
  keeps a record only if its first source is on that list under its own licence
  and every other source is on it or is Overture's own.
- **Filters.** Inside the importer's box; not `permanently_closed`; confidence
  at least 0.6 (every source clusters at 0.8 to 1.0, and below 0.6 sit a long tail
  of Meta records with no operating status and a spike of one-person
  registrations at exactly 0.55); and a category people go to. Business services
  (lawyers, consultants, software, real estate) and delivery-only or utility
  listings are dropped; everything else maps to our category names and weights
  (`OVERTURE_GROUPS` in `build_search.py`), unmapped ones keeping Overture's own
  name at a shop-like weight. Overture rows rank 5 below an OSM place of the same
  category, and carry no address: addresses come from OSM only, so a business
  shows the nearest OSM address.
- **Derivative database.** Merging with OSM makes the search index a derived
  database, so it stays under ODbL 1.0, and every Overture-sourced row is
  identifiable by its `source` column.
- **Next fetch.** Run the script for a newer release, then `import_osm.py`.

## Shared links

A link from another maps app is a search the person did not have to retype.
Design and decisions: https://claude.ai/artifact/32QugGzJS3TRMLgUsgaLQM.

- **Read** (`Core/SharedLink.swift`). `SharedLink.parse` takes pasted text and
  returns hints per stop (name, address, point) for Apple Maps, Google Maps,
  Waze, OpenStreetMap and `geo:` links and bare coordinate pairs; nil for
  anything else, so ordinary search text passes through. A point that is only
  the other app's map centre is marked not exact and never becomes a pin.
  Google's path forms are observed, not documented, and may change.
- **Expand** (`SharedLinkExpander`). `maps.apple` and `maps.app.goo.gl` short
  links need one request to read their redirect: no page load, no cookies, at
  most three hops, and only to `SharedLink.shortHosts`. Offline, the link is
  unreadable and any text that came with it becomes the search.
- **Match** (`SearchIndex.match`). The hints go through the ordinary search. A
  result is taken as the shared place only when it is plainly the same: the
  same house number and street within 150 m of the shared point (or with no
  point at all), or the same name within 75 m. Otherwise results within 300 m
  are offered as a search sorted from the shared point, with the point itself
  as a pin beside them; with none, the pin alone. Outside the map area says so.
- **Rules.** No MapKit call anywhere. The other app's name, address and place
  ID are never shown or stored: what shows is our record with its own source
  line, plus "Matched from a shared link". The only thing of theirs that can
  reach our map is the point of a pin for a place we lack, named from our data
  by `droppedPin`. A shared route gives its stops only, never a path or time.
- **Built so far:** paste into search. A route link opens its last stop.
  **Next:** the share sheet (Share Extension and a `peoplemaps://` URL), then a
  stop picker for routes. Multi-stop routing is its own project.

## Coverage is the gate

Search beyond the area we can route is no use. All-Seattle coverage means
growing the importer's bounds to the city limits (about 47.49–47.74 N,
122.44–122.24 W) for the graph, elevation, map tiles and the index together.
Check app size, launch time and router speed at that size first.

## Stages

1. **Index from OSM and addresses** in the current bounds: importer, SQLite
   FTS5, Swift query layer in `Core` with unit tests, search screen wired to
   it. Done; addresses come from OSM only.
2. **Overture places**: business coverage, categories, dedupe tests. Done; see below.
3. **My location, dropped pins, recents and favourites.**
4. **All of Seattle**: bigger bounds for every data set, with size and speed
   budgets.
5. **Apple Maps hand-off button** for queries with no result.
