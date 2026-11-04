# Why this slice

Peoplemaps is a working name. The product hypothesis is that a person can set a
small time allowance and understand why a different route may ask less of them.
The prototype tests that interaction using real Seattle network data.

The native client is SwiftUI, with a small `UIViewRepresentable` bridge to
MapLibre Native. A local Swift package owns routing, estimates, comfort costs,
place search, and request lifecycle. Both display and routing use bundled OSM
data, so the actual app needs no network, API key, account, or location prompt.

Valhalla and GraphHopper are stronger starting points for production routing.
For this local, inspectable slice, installing a daemon/container, configuring
regional tiles, and bridging custom cost models would have added more operational
surface than the experience needed. The small owned router makes the preference
and budget behavior executable and reviewable now. `RouteComputing` is the
replaceable boundary for a later self-hosted routing service. This choice is not
a claim of parity with mature routing engines.

## Data boundaries

`Scripts/import_osm.py` compiles the preserved Overpass responses into a graph
and the map tiles. Routing segments retain full geometry, OSM way IDs, names,
road classes, mode permissions, surfaces, posted speed text, incline text, and
direction-specific cycleway tags. Shared nodes, signals, barriers, endpoints,
and restriction nodes split segments. The app never infers missing attributes
as facts. Places use OSM node coordinates or simple means of feature vertices;
they are not verified entrances.

The compiler applies an explicit conservative policy:

- Mode-specific access overrides general access; unknown access values,
  private/customer/destination access, and conditional access are excluded.
- Driving excludes non-road paths and driveway/parking-aisle service roads.
- Cycling excludes motorway/trunk roads and footways/paths without an explicit
  bicycle permission. This deliberately omits some locally legal paths.
- One-way direction, reverse one-way, roundabouts, bicycle exemptions, and
  opposite-cycleway tags are handled. Reversible/unknown one-way tags are excluded.
- Via-node `no_*`/`only_*` restrictions, per-mode variants, and exceptions are
  compiled. A restriction never removes a way. A via-way `no_*` keeps only a ban of the
  final transition from its last via way into the to way (over-restricting a legal
  turn at worst, never allowing a banned one). Not represented, and ignored:
  via-way `only_*`, via-way `no_u_turn` (the router bans immediate U-turns anyway),
  conditional restrictions, and malformed ones. `restrictionClasses` in
  `Data/provenance.json` counts each class.
- A `barrier=lift_gate` blocks driving and cycling except with `access=yes` or on a
  bridge or a primary-or-bigger road, where it is a movable bridge's gate (Montlake,
  1st Ave S). Bridge openings are not modeled.
- Explicit access barriers are respected under the compiler's documented policy.
  A mapped cycle barrier does not prove that a particular bicycle can pass it.

Routing remains incomplete: lane-specific maneuvers, vehicle dimensions,
conditional schedules, construction, seasonal closures, traffic, ferry routing,
turn-protection phases, complex intersection rules, and many access subtleties
are not modeled. Missing OSM restrictions can still produce infeasible routes.

## Map tiles

`Core/Resources/seattle-map.pmtiles` is PMTiles v3 holding Mapbox Vector Tiles (version 2), zoom 8 to 14, overzoomed
by MapLibre to the app's maximum of 18. The app opens it with `pmtiles://file://`. `Scripts/build_tiles.py` writes
it, stdlib only. Each tile has at most one feature per source layer (all lines one MultiLineString, all polygons one
MultiPolygon), with no properties or names. The style never filters, so zoom detail is decided only by what each
layer holds.

| Source layer | Type | Contents and first zoom |
|---|---|---|
| `water` | polygon | z8: coast polygons, `natural=water` |
| `park` | polygon | z10: `leisure=park/garden/pitch` |
| `arterial` | line | z8: motorway, trunk. z10: primary. z11: secondary |
| `road` | line | z11: tertiary and the motorway, trunk and primary links. z12: secondary and tertiary links, residential, unclassified, living street, busway. z13: pedestrian, service with no `service` tag or an alley. z14: other service |
| `path` | line | z12: cycleway. z14: footway, path, steps, track |

Other `highway` values and `area=yes` ways are not drawn.

| Zoom | Extent | Buffer | Simplify | Drop polygon under |
|---:|---:|---:|---:|---:|
| 14 | 8192 | 128 | 1.5 units (0.3 m) | 1 unit |
| 12 to 13 | 4096 | 64 | 6 | 8 units |
| 8 to 11 | 4096 | 64 | 10 | 8 units |

Tiles and directories are stored **uncompressed**: gzip would save about 22% of the file, but the bytes would then
depend on a zlib build, and the App Store compresses the download anyway. The output is deterministic, so
`Scripts/verify.sh` compares it with a fresh import.

**Coastline.** Puget Sound is not a polygon in OSM; `natural=coastline` ways have land on their left and water on
their right. `coast_water` joins the ways end to start without reversing them, clips the chains to the water box
(the routing box plus 0.1°), and closes each run clockwise along the box edge, so the water side is filled. A coastline
that ends inside the box fails the import rather than flooding the map. Islands become holes.

`python3 Scripts/import_osm.py --tiles-only` rewrites only the tiles and the `sources` and `map` entries of
`Data/provenance.json`. Use it on a machine whose SQLite differs from the one that built the shipped search index; a
full import there would rewrite the index.

## Region data

What is in git is a small test fixture: the Seattle box in `Data/` and `Core/Resources/`, reproduced byte for
byte by `Scripts/verify.sh`. Full regions are too big for git (GitHub rejects files over 100 MB, and this
repo's history is permanent), so they live in a private Cloudflare R2 bucket, `peoplemaps-data`, and are fetched
at build time. Git LFS is not used. The derived database is available on request under ODbL 1.0 (see
`Data/LICENSE.md`). Map data comes from Geofabrik extracts. `Data/regions.json` is the committed manifest: the
release name, and per region its bounding box, every file's size and SHA-256, and which files are expected
importer outputs. Nothing under `Data/region/` is committed. CI and `swift test` never need it.

```bash
Scripts/fetch_data [region]      # downloads into Data/region/<region>/, checks pins, silent when present
Scripts/verify.sh --region       # also re-imports each fetched region and compares with its expected outputs
Scripts/upload_data [region]     # owner only: puts the manifest's files into the bucket
```

Without fetched data `--region` prints `SKIPPED` lines and passes; plain `Scripts/verify.sh` does not look at regions.

The bucket holds one object per file, keyed `<release>/<region>--<path with / replaced by __>`, for example
`data-seattle-all-2026-11d/seattle-all--expected__seattle-graph.bin`. Both scripts are Python standard library
only and sign requests with SigV4 (`Scripts/s3sig.py`, region `auto`, service `s3`). They read three variables:

| Variable | Value |
|---|---|
| `PEOPLEMAPS_DATA_URL` | `https://<account id>.r2.cloudflarestorage.com/peoplemaps-data` |
| `PEOPLEMAPS_DATA_KEY_ID` | the R2 API token's access key id |
| `PEOPLEMAPS_DATA_SECRET` | the R2 API token's secret access key |

With all three set, `fetch_data` signs its requests. With only `PEOPLEMAPS_DATA_URL` it does a plain GET of
`<url>/<region>--<path>` (no release folder), which is what tests and mirrors use; a local `file://` folder works.
With no URL (or an empty one, as a fork's CI run sees the secrets) it exits saying the three variables are needed;
there is no public fallback. The scripts never print
the secret or a signed header, and their errors name the object, not the endpoint.

### Secrets

Three GitHub repository secrets feed the `region=true` CI run: `PEOPLEMAPS_DATA_URL`, `PEOPLEMAPS_DATA_KEY_ID`
and `PEOPLEMAPS_DATA_SECRET`. The owner creates in the Cloudflare dashboard (R2, Manage API tokens):

- a read-only token scoped to the `peoplemaps-data` bucket, whose key id and secret go into those secrets and
  into the owner's shell for local `fetch_data`;
- a separate read-and-write token, used only by `Scripts/upload_data` in the owner's own terminal, never stored
  in GitHub.

No token value is ever written in the repo, a doc, a commit or a chat.

Add or update a region file:

1. Make the files: the importer's input snapshots at the region folder's root (names as in `Data/`), and the
   outputs from importing them (`PEOPLEMAPS_DATA`, `PEOPLEMAPS_BBOX`, `PEOPLEMAPS_OUT`) under `expected/`.
2. Put them in `Data/region/<region>/` and pick a new release name rather than replacing objects.
3. Put each file's size and `shasum -a 256` in `Data/regions.json` under `regions.<region>.files`, set `bbox`
   (S,W,N,E), list the expected outputs under `outputs`, and set `release` to the new name.
4. `Scripts/upload_data <region>` with the read-and-write token (it checks the pins first and skips objects
   already there), then in a clean checkout `Scripts/fetch_data <region>` and `Scripts/verify.sh --region`, and
   commit the manifest.

### Downloading a region on the phone

The app ships `Data/regions.json` (through `Scripts/generate_project.py`, so the project is regenerated, not hand-edited) and offers
King County from About, under Map area. Only a region's outputs (`expected/<output>`, five for king-county) are downloaded, never
its inputs; the size on the offer card is the sum of their `bytes` in the manifest (232.3 MB for release `data-seattle-all-2026-11d`).
The space it takes on the phone is an estimate, "about 350 MB": the search index arrives gzipped and is inflated, and its ratio
(3.3) is measured on the bundled Seattle index, not on the county files. Nothing on a phone has measured it yet.

- `Core/RegionStore.swift` (an actor) owns `Application Support/Regions/<release>/<region>/`, excluded from backup. One
  `URLSession` download task per file; the released app uses a background session, so a download goes on while the app is
  suspended or gone. Wi-Fi only unless the person taps Use cellular. Pause keeps resume data. Files land in
  `Regions/.staging/<release>/<region>/`; after all five arrive each is checked for size and SHA-256, the search index is
  inflated to a file in chunks (`GzipFile`, never in memory) and its gzip deleted, and the staging folder is renamed into
  place at once. A file that fails a check is deleted and nothing is installed.
- Where files come from is a `RegionSource` (`url(for:in:release:)`, `authorization()`). `DirectSource(base:)` does a plain GET of
  `<base>/<region>--<path with / as __>` for tests and development. `WorkerSource` is a stub until the Worker exists: its endpoint
  is `GET /v1/regions/<release>/<region>--<file>` with `Authorization: Bearer <token>`.
- `Core/RegionSelection.swift` decides what the app loads. `Bundle.dataFile` asks it first, so the order is the downloaded region,
  then the app bundle, then the package fixture, and the graph, map, search index and coverage always come from the same one.
  The choice is read once per launch. A finished download selects itself and takes effect at the next launch, or on Switch now
  when no route is shown and the person is not navigating; the map never changes under a route or guidance. If the downloaded
  files fail to load, Seattle is used for that launch and About says so.
- A new app build with a different `release` keeps the old folder in use until the new one is in; the old one is deleted after
  that, at the next launch if the running app has it open. Remove marks an open folder and deletes it at the next launch.
- UI tests keep regions in their own folder and aim the app at a local server: `--region-server URL` and
  `--region-manifest-json JSON` (Debug only).

### Coverage polygons

A region may be a polygon rather than a box. `Scripts/region_polygon.py` (needs `shapely`; run it with `uv run --with shapely`)
takes one OSM boundary relation from a Geofabrik extract, grows it by a buffer and simplifies it. It writes
`{osmRelation, bufferMeters, bbox, rings}`. The result is small, so it is committed: `Data/king-county-coverage.json`
is relation 1153346 (King County) plus 4,828 m (3 miles), one ring.

- `PEOPLEMAPS_COVERAGE=<file>` makes the importer keep only nodes inside the polygon; `PEOPLEMAPS_BBOX` defaults to its box.
- `coverage` in a `Data/regions.json` entry names the committed polygon; `Scripts/reproduce_regions.py` passes it to the importer.
  Keep the entry's `bbox` equal to the polygon's.
- `Scripts/fetch_dem_tiles.py` takes the polygon as its last argument and fetches only the elevation tiles that touch it, and `Scripts/fetch_overture.py` takes `--bbox S,W,N,E`.
- The importer reads `Data/seattle-city.json` (OSM relation 237385, made with `region_polygon.py` and no buffer) to decide where its
  estimated drive speeds apply; they are stored on segments outside Seattle only (`Docs/STRESS_MODEL.md`, Speed estimates).
- In the app, `Coverage` (`Core/Coverage.swift`) answers "is this point covered": the polygon when the data ships
  `seattle-coverage.json` (the same file format as `Data/king-county-coverage.json`), else the graph's box, which is all the
  bundled Seattle data has. `ExploreView` and `NativeRouter` ask `graph.coverage`, not the box, so a point in the box but outside
  the polygon is outside coverage. `RouteComputing.canSnap(_:mode:)` says whether a covered place has a road node within 400 m
  to leave from and arrive at (false for Vashon, the Kitsap shore, a spot on the water), so the app can say "no road route"
  before a search. The messages that use it are a later step.
- The `king-county` entry in `regions.json` has no pinned files yet, so fetching and reproduction skip it. The data is built and hosted in a later step.

### seattle-all

All of Seattle (47.49, -122.44, 47.74, -122.24), release `data-seattle-all-2026-11d`. The app bundle ships it when it is
fetched and the fixture otherwise: a "Bundle fetched region" build phase (from `Scripts/generate_project.py`) copies
`Data/region/seattle-all/expected/{seattle-graph.bin,seattle-map.pmtiles,seattle-search.sqlite.gz}` into the app,
and `Bundle.dataFile` in Core prefers the app bundle's copy over the package's fixture. `swift test` and CI never see it.
Run `Scripts/fetch_data seattle-all` and rebuild the app to switch.

Its inputs are made, not downloaded as Overpass JSON: `Scripts/pbf_to_snapshot.py` turns one dated Geofabrik Washington
extract into `seattle-osm`, `seattle-parks`, `seattle-search` (and `seattle-coast`) snapshots in the importer's format, in about
15 seconds with the standard library. The extract's URL, SHA-256 and date go into each snapshot and from there into
`provenance.json`. The extract itself (365 MB, SHA-256 `592ff8fd7a682b1f72fb88170968c07ae345d6a523c8dd33e79e6e53777302cf`) is in the bucket as `source/washington-261031.osm.pbf`, outside the manifest; fetch it with `Scripts/fetch_data`'s credentials and any S3 client if it is ever needed again.
Elevation comes from `Scripts/fetch_dem_tiles.py 47.45 -122.45 47.75 -122.20 ...` (a 0.05 degree margin, so no 0 m fringe).
The full import takes about 11 minutes and 3 GB.

## Routing and budget

`NativeRouter` uses an incoming directed edge as its Dijkstra state. This keeps
turn restrictions and turn costs dependent on how a junction was entered. It
prohibits immediate U-turns. The time-only route is the shortest modeled time
within this graph and access policy, not the fastest route in the real city.

Place coordinates snap to nodes on the largest strongly connected component
for the mode, within 400 m and off highway segments. Kosaraju's algorithm finds
that component at router initialization. This prevents an isolated campus loop
from winning merely because it is closest. Turn restrictions are still checked
during search. Snapping can select the wrong side of a physical barrier; endpoint
gaps are not routed, are excluded from ETA, and are disclosed in the UI.

Six additional searches minimize `estimated seconds + weight × stress`,
using weights 0.25, 0.5, 1, 2, 4, and 8. The budget does not bound these searches.
Distinct candidates are compared using their exact seconds. A calmer candidate must
fit `fastest seconds + budget × 60`, reduce stress by at least 5% and 30 equivalent
seconds, and remove more than 15 equivalent seconds of stress per extra minute. The
most stress saved net of that rate wins. When none qualifies, `NoCalmerFinding` records
what the candidates showed, for the preview to say (`Docs/STRESS_MODEL.md`, Choosing
and explaining routes).
This candidate search does not prove the global optimum under a time constraint.
No extra time searches only the fastest route. No suitable candidate is an
ordinary first-class result. Displayed minutes round up; filtering never does.

## Transparent preference costs

Driving costs per km: residential 65, service 100, highway 35, other road 12.
Transitions add 22 per turn, 65 per arterial left, and 180 per highway entry.
Residential penalties discourage routing through neighborhoods as a shortcut.
Turns use a greater-than-35° angle at a change of OSM way. Segmentation and OSM
classification influence these proxies. An arterial left does not mean an
unprotected turn; a highway entry does not establish merge difficulty or a
one-exit detour. Those limitations are visible in the explanation screen.

Cycling costs per km: cycleway/track tags 8, shared path 20, lane 32,
residential 35, arterial 140, other 65. Rough-surface tags add 55/km;
unknown surface adds 8/km. Turns add 6 and arterial lefts add 25. Track tags
are directional; shared paths are kept distinct. Grade tag coverage is reported
but not scored because this slice has no reliable elevation model. No route
is given a safety score or label.

Times use free-flow speeds (the posted limit when mapped, else a class default)
and junction delays for signals, stops, unsigned cross streets and turns; the
tables are in the Time section of `Docs/STRESS_MODEL.md`. Cycling assumes
18 km/h, 14 on shared paths, 11 on tagged rough surfaces. There is no live
traffic. Drive times were checked against one real trip; the constants remain
hypotheses, exposed in code for review, not empirical ETAs.

## UI and lifecycle

`ExploreView` owns places, mode, time budget, selected comparison, and one sheet
enum. `RouteSession` owns mutually exclusive idle/loading/ready/error/cancelled
states. Every start cancels the prior task and advances a generation token.
Only the current generation can publish. The router runs off the main actor;
its Dijkstra loop checks cancellation. There are no background route changes,
location updates, or automatic rerouting.

`SeattleMap` keeps rendering separate from route selection. Its Swift concurrency
bridge marks the MapLibre delegate as a main-actor, preconcurrency conformance
because the Objective-C protocol predates actor annotations. Static OSM sources
load once; route shapes update on comparison changes. Explicit text beneath the
map duplicates the decision information for accessibility. Search uses stable
OSM IDs and a small curated initial set of public places; typed queries go to
`SearchIndex`, an SQLite FTS5 index of OSM places and addresses inflated into
Caches on first launch (see `Docs/SEARCH.md`).

## Next architectural decision

Keep the client and explanations; compare the current router against a local
Valhalla/GraphHopper instance with a Seattle extract. Evaluate route legality,
intersection maneuvers, and sensitivity to the stated time allowance before
calibrating preferences or expanding geography. Keep optional commercial place
enrichment behind a separate place-details interface. It must not influence
route scoring, candidate ordering, or sponsored search placement.
