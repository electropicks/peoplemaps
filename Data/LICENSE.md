# OpenStreetMap data

© OpenStreetMap contributors. OpenStreetMap data is available under the
[Open Database License 1.0 (ODbL)](https://opendatacommons.org/licenses/odbl/1-0/).
See [OSM copyright and attribution](https://www.openstreetmap.org/copyright).

The original snapshots in `Data/*.json.gz` and the derived databases in
`Core/Resources/seattle-graph.json.gz` (gzipped JSON) and `Core/Resources/seattle-map.geojson`
are distributed under ODbL 1.0, separately from the source-code MIT license.
This repository supplies the underlying data and deterministic transformation
script. Retain attribution and comply with ODbL when redistributing or adapting
these datasets. App screenshots include attribution on the map.

Two manually requested, bounded Overpass extracts were fetched on 2026-10-11.
The raw response timestamps and SHA-256 hashes appear in `provenance.json`.
Timestamps are recorded exactly as reported by the upstream service. They are
not a guarantee of present-day road conditions.

Coverage: 47.615°–47.678° N, 122.390°–122.300° W. Relations may reference source
geometry outside this box; routing edges are kept only when all their geometry
lies inside it. Water and park polygons are clipped. No public map tiles were
downloaded. Search is limited to named parks, cafés, libraries, museums,
attractions, and viewpoints captured by the queries.

Rebuild derived data offline with `python3 Scripts/import_osm.py`. The queries
are retained here for provenance, not called by the app. Any future refresh
should be deliberate and respect [Overpass resource guidance](https://dev.overpass-api.de/overpass-doc/en/preface/commons.html).
Do not turn the public Overpass endpoint into an app backend. For production,
use regional extracts and a self-hosted update pipeline.
