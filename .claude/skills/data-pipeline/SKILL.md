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
  - `seattle-map.geojson`: map layer.
  - `seattle-search.sqlite.gz`: FTS5 search index.
- Output must be deterministic: no timestamps or dict-order dependence, and gzip uses `mtime=0`.
- When outputs change on purpose, commit the code and the regenerated files together, and say why in the message (sizes before → after).
- Snapshots are archived in `Data/`. Fetch new ones only when asked; record the query, date and source in `Data/provenance.json`.
- `PEOPLEMAPS_BBOX`, `PEOPLEMAPS_DATA` and `PEOPLEMAPS_OUT` (and `--out`) redirect an import for spikes. Never point them at the shipped files.

## Licences (ask before adding any source)

- OpenStreetMap: ODbL 1.0. Attribution "© OpenStreetMap" stays on the map.
- USGS 3DEP elevation: public domain.
- Overture Maps: CDLA-Permissive 2.0. Check each source's attribution.
- King County / City of Seattle address points: **not used**. Their terms don't clearly allow redistribution.
- **Apple Maps / MapKit data must never enter our data or UI.** DPLA Attachment 6, sections 2.2–2.5: no caching, no derived databases, no showing it on a non-Apple map. The only Apple touchpoint is the "Look up in Apple Maps" hand-off. `CLGeocoder` counts too. See `Docs/SEARCH.md`.

## Coverage

The shipped bounds are 47.615–47.678 N, 122.390–122.300 W. All-Seattle is blocked on the costs in `Docs/COVERAGE_SPIKE.md` (memory, router speed). Don't grow the bounds without new measurements.
