---
name: data-pipeline
description: Rules for PeopleMaps map and routing data. Use whenever touching Scripts/import_osm.py, Scripts/build_search.py, anything in Data/ or Core/Resources/, the bounding box, OSM/Overpass queries, elevation, the search index, or when adding a new data source or licence.
---

# Data pipeline

Everything in `Core/Resources/` is generated. Never edit it by hand; a hook blocks it.

## Regenerate

```bash
python3 Scripts/import_osm.py      # reads Data/*.json.gz snapshots + DEM, writes Core/Resources/* and Data/provenance.json
Scripts/verify.sh                  # "data reproduces byte for byte" must pass
```

- Outputs:
  - `seattle-graph.bin`: binary graph; the format is documented in the importer and read by `Core/GraphBinary.swift`.
  - `seattle-map.pmtiles`: map layer (vector tiles, written by `Scripts/build_tiles.py`; schema in `Docs/ARCHITECTURE.md`).
  - `seattle-search.sqlite.gz`: FTS5 search index.
- Output must be deterministic: no timestamps or dict-order dependence, and gzip uses `mtime=0`.
- When outputs change on purpose, commit the code and the regenerated files together, and say why in the message (sizes before → after).
- Don't run a full import in place on a Mac whose SQLite differs from `Data/provenance.json`'s `search.sqlite`: it rewrites the search index and provenance. For a map-only change run `python3 Scripts/import_osm.py --tiles-only`, which writes just `seattle-map.pmtiles` and the provenance entries it changes; CI's Linux job proves the rest still reproduces.
- Snapshots are archived in `Data/`. `seattle-coast` (OSM `natural=coastline`, query `Data/seattle-coast.overpassql`) feeds the water polygons only, not the graph. Fetch new ones only when asked; record the query, date and source in `Data/provenance.json`.
- `PEOPLEMAPS_BBOX`, `PEOPLEMAPS_DATA` and `PEOPLEMAPS_OUT` (and `--out`) redirect an import for spikes. Never point them at the shipped files.

## Region data

Files in git are the Seattle test fixture. Bigger regions are release assets pinned in `Data/regions.json`: `Scripts/fetch_data`, then `Scripts/verify.sh --region`. See "Region data" in `Docs/ARCHITECTURE.md`. Never commit a big region.

## Licences (ask before adding any source)

- OpenStreetMap: ODbL 1.0. Attribution "© OpenStreetMap" stays on the map.
- USGS 3DEP elevation: public domain.
- Overture Maps Places: licensed per source, not per theme: CDLA-Permissive 2.0 (most), Apache 2.0 (Foursquare, keep its NOTICE), CC0 1.0 (AllThePlaces); no OSM data in this theme. Only the allowlist in `Scripts/build_search.py` is used. The extract is archived in `Data/seattle-overture-places.json.gz` because Overture keeps only two releases online (about 60 days); `Scripts/fetch_overture.py` takes a new one (pyarrow, not part of the importer). Merged into the search index, it stays under ODbL with a per-row `source`. Licence texts: `Data/licenses/`.
- King County / City of Seattle address points: **not used**. Their terms don't clearly allow redistribution.
- **Apple Maps / MapKit data must never enter our data or UI.** DPLA Attachment 6, sections 2.2–2.5: no caching, no derived databases, no showing it on a non-Apple map. The only Apple touchpoint is the "Look up in Apple Maps" hand-off. `CLGeocoder` counts too. See `Docs/SEARCH.md`.

## Coverage

The fixture in git is the box 47.615–47.678 N, 122.390–122.300 W. All Seattle (47.49–47.74 N, 122.44–122.24 W) is the region `seattle-all`, a release asset the app bundles when fetched (`Docs/ARCHITECTURE.md`, Region data). Growing beyond it needs a new region, new measurements (`Docs/COVERAGE_SPIKE.md`) and the owner's decision.
