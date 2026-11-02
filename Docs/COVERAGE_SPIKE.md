# All-Seattle coverage spike

What it costs to grow the bundled data from the current box to all of Seattle. Measured, not built: nothing here ships.

- **Current:** `47.615,-122.390 → 47.678,-122.300` (the shipped data).
- **All-Seattle:** `47.49,-122.44 → 47.74,-122.24`, a plain bounding box. It is not clipped to the city boundary, so it includes the lakes, Mercer Island and slivers of Shoreline, Burien and Tukwila.
- **OSM source:** Overpass API (`overpass-api.de`) with the unchanged queries in `Data/*.overpassql` and the box substituted, plus `maxsize` raised to 512 MB and `timeout` to 180 s. One request at a time. OSM took 47 s and 112 MB, parks 31 s, both with no refusals, so the Geofabrik fallback was not needed. Snapshot 2026-10-29T05:44Z.
- **Elevation:** USGS 3DEP `exportImage`, same ~5 m cell as the shipped DEM. One 3000×3750 request returned 504, so `Scripts/fetch_dem_tiles.py` fetches 20 tiles of 0.05° sequentially (3.5 min) and stitches them into the same uncompressed tiled float32 GeoTIFF that the importer reads.
- **Hardware:** the importer and the benchmark ran on this Mac (release build). Launch numbers are from the iPhone 17 Pro **simulator** (Release), so they run on Mac CPU and are not iPhone numbers.

## Results

| | Current | All-Seattle | × |
|---|---:|---:|---:|
| Nodes | 73,354 | 269,172 | 3.7 |
| Segments | 101,658 | 367,662 | 3.6 |
| Directed edges (router) | 198,963 | 722,663 | 3.6 |
| Places | 519 | 1,460 | 2.8 |
| Graph, gzipped (shipped) | 4.39 MB | 16.52 MB | 3.8 |
| Graph, raw JSON | 38.6 MB | 139.6 MB | 3.6 |
| Map layer, raw GeoJSON (shipped) | 11.6 MB | 43.0 MB | 3.7 |
| Map layer, gzipped (for reference) | 1.55 MB | 6.13 MB | 4.0 |
| Both resources, as installed | 16.0 MB | 59.6 MB | 3.7 |
| Build input: DEM, raw / gz | 7.9 / 5.5 MB | 47.1 / 24.3 MB | 6 / 4.4 |
| Build input: OSM archives, gz | 3.3 MB | 13 MB | 3.9 |
| Release `.app` on disk (sim build) | 49 MB | 92 MB | 1.9 |
| **Import time** (`import_osm.py`) | 5.9 s | 28.6 s | 4.8 |
| Import peak RSS | 632 MB | 2.28 GB | 3.6 |

Launch in the simulator (ms since process start; median of 4 runs current, 3 runs all-Seattle, 2 for the last row because the map-rendered line was missing from one run):

| | Current | All-Seattle |
|---|---:|---:|
| Graph decoded (gunzip + `JSONDecoder` + validate) | 1,020 | 3,250 |
| Router ready (`NativeRouter.init`) | 1,365 | 4,580 |
| Map style loaded | 1,445 | 4,700 |
| **Map fully rendered (interactive)** | **1,795** | **~5,950** (5,751 / 6,137) |
| Footprint after router ready | 112 MB | 366 MB |
| Footprint after map rendered | ~308 MB | 980–1,161 MB |
| **Peak RSS at launch** | **~700 MB** | **1.9–2.1 GB** |
| Peak RSS during graph decode alone | 507 MB | 1.21 GB |

The "interactive" row is the first fully rendered map frame after the router was ready. The `Opening Seattle…` spinner covers 0–1.4 s now and 0–4.6 s all-Seattle.

Router, median of 5 runs (ms, macOS release, `extraMinutes: 5`; `Scripts/coverage_bench`). Route length is the fastest route; the same trip finds the same route in both graphs.

| Trip (fastest route) | walk cur → all | bike cur → all | drive cur → all |
|---|---:|---:|---:|
| Short: Fremont → Gas Works (1.4–1.6 km) | 39 → 49 | 31 → 45 | 18 → 28 |
| Short: Cal Anderson → Volunteer Park (1.7 km) | 77 → 114 | 73 → 159 | 70 → 110 |
| Medium: Ballard → South Lake Union (6.6–7.3 km) | 235 → 269 | 183 → 266 | 355 → 611 |
| Medium: Ballard → Capitol Hill (9.4–10.6 km) | 1,740 → 2,086 | 777 → 1,563 | 685 → 1,628 |
| Long: Ballard → Madrona (10.4–11.7 km) | 2,237 → 3,080 | 988 → 2,013 | 773 → 2,323 |
| Long: Ballard → Columbia City (16.3 / 16.7 / 19.1 km) | n/a, outside current box | n/a | n/a |
| Ballard → Columbia City, all-Seattle only | 4,888 | 3,436 | 2,187 |

Graph decode and router init on macOS: 751 ms + 374 ms now, 2,790 ms + 1,499 ms all-Seattle.

## Bottlenecks and cheapest fixes

1. **Graph decode plus router init: 4.0 of the 5.9 s all-Seattle launch (68%; 1.1 of 1.8 s now).** Gunzip plus `JSONDecoder` of 140 MB takes 2.7 s (0.8 s now) and drives the 1.2 GB transient peak. Of the 140 MB, 121 MB is `segments` and 21 MB of that is `g` geometry (966k points). Router init adds 1.3 s on top.
   **Fix:** a flat binary graph. Use fixed-width little-endian arrays for nodes (Int32 lat/lon ×1e7, Int16 z, flags) and segments (a, b, metres, up, down, class, mode/direction bytes), plus delta-varint geometry. Bundle it uncompressed or mmap it. I estimate ~20 MB raw and ~10–12 MB compressed. That is an estimate, not a build. Decode becomes a memcpy, so seconds drop to well under 0.5 s and the peak is about the file size. Do `NativeRouter.init` cost (strong components, per-mode cost arrays) at import time and store it, or build it on a background queue after the first frame.
2. **GeoJSON map layer: 1.2 s of launch (0.35 s now) and +600–800 MB.** MapLibre parses the whole 43 MB file in process, and the footprint jumps from 372 to 980–1,161 MB on first render. 62% of the bytes are `path` lines (26.5 MB: footways, sidewalks, steps) and 31% are `road` lines (13.4 MB). The map also duplicates geometry the graph already holds.
   **Fix:** PMTiles or vector tiles with zoom-dependent content (arterials and water at z≤13, local roads from z14, footways from z16). Build them at import time (tippecanoe or a small Python writer). Size should be about the gzipped GeoJSON (6 MB) or less, with no whole-file parse at launch. Check that the pinned MapLibre Native version supports `pmtiles://` before committing. A zero-dependency stopgap is to drop `path` features below zoom 15 from the GeoJSON, which removes ~60% of its bytes.
3. **Router cost per search grows beyond route length.** The identical 1.7 km Cal Anderson → Volunteer Park bike trip costs 73 ms now and 159 ms all-Seattle with the same route, which points at per-search work proportional to graph size (full-size cost, visited or parent arrays per weight, six weights per mode). I did not profile this. The cheapest fix is likely sparse or reused visited state, or a bidirectional or landmark heuristic. The long trips (2–5 s on a Mac, probably 2–3× that on a phone) need that anyway; Ballard → Columbia City walk is 4.9 s.
   **Update:** profiled and fixed on the bundled graph; see [PERFORMANCE.md](PERFORMANCE.md) for the method, before and after numbers and budgets. Short trips now cost the same on a graph 4 times larger, and the 10 km trips take 0.2 to 0.7 s on a Linux box. Those figures are not from a phone, and the all-Seattle graph itself has not been re-measured.
4. **Memory and jetsam risk.** At launch the peak RSS is 1.9–2.1 GB, and the post-render footprint is ~1 GB. That is risky on 4 GB iPhones, whose per-app limit is roughly 2 GB. Fixes 1 and 2 are what bring it down: the binary graph removes the 1.2 GB decode peak, and tiles remove the 600+ MB map parse.
5. **Download and storage: 22.7 MB of resources against 6 MB gzipped now.** The DEM (24 MB gz) and OSM (13 MB gz) are build inputs only and are not bundled. That is acceptable. The installed GeoJSON is stored raw (the App Store compresses it in transit), so tiles also shrink installed size by ~35 MB.

## Importer

The importer now takes `PEOPLEMAPS_BBOX="S,W,N,E"`, `PEOPLEMAPS_DATA` (default `Data/`) and `PEOPLEMAPS_OUT` (default `Core/Resources/`). With none of them set, the output is byte-identical to the committed graph (checked with `cmp`). Reproduce:

```
python3 Scripts/fetch_dem_tiles.py 47.49 -122.44 47.74 -122.24 Spikes/all-seattle/data/seattle-dem.tif.gz Spikes/all-seattle/demtiles
# put seattle-osm.json.gz / seattle-parks.json.gz (Overpass output, gzipped) in Spikes/all-seattle/data/
PEOPLEMAPS_BBOX=47.49,-122.44,47.74,-122.24 PEOPLEMAPS_DATA=Spikes/all-seattle/data PEOPLEMAPS_OUT=Spikes/all-seattle/out python3 Scripts/import_osm.py
cd Scripts/coverage_bench && swift build -c release && PEOPLEMAPS_GRAPH=<graph.json.gz> .build/release/bench
```

`StreetGraph.bundled()` gained a `PEOPLEMAPS_GRAPH` environment override, solely so the benchmark can load other graphs. Do not merge it. `Scripts/coverage_bench/launch-logging.patch` is the temporary `NSLog` timing patch used for the simulator numbers; it was never committed to `App/`.

Caveats: single machine, single sample set, simulator rather than device; the all-Seattle `map-fully-rendered` line has 2 samples. Coverage was not checked for correctness (for example, graph connectivity across the larger box or routes across the water crossings), only for cost.
