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

**Open question, not planned:** a place the user shares *into* PeopleMaps
from Apple Maps (a share-sheet link with coordinates). The user supplies it,
not the Apple Maps Service, but it is a grey area. Decide before building it.
`CLGeocoder` (Core Location) falls outside the "Apple Maps Service" definition
on paper but returns Apple data, so do not rely on it either.

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

- **My location as the start.** "Current location" heads the origin list once
  permission is granted. If it is denied, the list hides that row and asks for
  nothing.
- **Drop a pin.** Long-press the map for "Dropped pin" plus the nearest
  address from the index.
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
  name at a shop-like weight.
- **Derivative database.** Merging with OSM makes the search index a derived
  database, so it stays under ODbL 1.0, and every Overture-sourced row is
  identifiable by its `source` column.
- **Next fetch.** Run the script for a newer release, then `import_osm.py`.

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
