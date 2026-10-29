# Search plan

Drafted 28 October 2026. Goal: navigate to any address, place or business in
Seattle, offline, with the same honesty rules as routing. Screens: the
"finding a place" rows of the design canvas
(https://claude.ai/artifact/HW5tDWwDFUmweSopZpuroE).

Today `Graph.search` (`Core/Models.swift`) matches the names of the parks and
landmarks the importer keeps in `places`. There are no addresses, no
businesses, and coverage stops at the routing bounds (47.615–47.678 N,
122.390–122.300 W).

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
| Overture Maps Places | businesses and points of interest, with categories | CDLA-Permissive 2.0 (check each source's attribution) |
| City of Seattle / King County address points | every street address with a point | to confirm before import |

- **Built by the importer.** `Scripts/import_osm.py` (or a sibling script)
  joins the sources, removes duplicates (same normalised name within about
  50 m, OSM wins, Overture fills in categories), and writes a SQLite database
  with an FTS5 table. It ships gzipped and is inflated at first launch, like
  the graph.
- **Query.** Prefix matching as you type, ranked by text match, then category
  weight (landmarks and parks over shops), then distance from the map centre
  or the user. House numbers parse into an address lookup ("3329 Fremont Ave
  N"). Typos are tolerated with a trigram fallback.
- **Snapping.** Each result stores its nearest routable node per mode, so
  routing starts without a search for the nearest road.
- **Size.** Rough guess: a few MB gzipped for all of Seattle. Measure in
  stage 1.
- **Honesty.** Open data goes stale. Business results show their source and
  date ("OpenStreetMap, Oct 2026"). Missing opening hours stay missing, never
  guessed.

## Also in scope

- **My location as the start.** "Current location" heads the origin list once
  permission is granted. If it is denied, the list hides that row and asks for
  nothing.
- **Drop a pin.** Long-press the map for "Dropped pin" plus the nearest
  address from the index.
- **Recents and favourites.** Stored on the device as our own place IDs and
  coordinates.

## Coverage is the gate

Search beyond the area we can route is no use. All-Seattle coverage means
growing the importer's bounds to the city limits (about 47.49–47.74 N,
122.44–122.24 W) for the graph, elevation, map tiles and the index together.
Check app size, launch time and router speed at that size first.

## Stages

1. **Index from OSM and addresses** in the current bounds: importer, SQLite
   FTS5, Swift query layer in `Core` with unit tests, search screen wired to
   it. Confirm the address-point licence first.
2. **Overture places**: business coverage, categories, dedupe tests.
3. **My location, dropped pins, recents and favourites.**
4. **All of Seattle**: bigger bounds for every data set, with size and speed
   budgets.
5. **Apple Maps hand-off button** for queries with no result.
