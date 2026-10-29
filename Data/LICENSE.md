# OpenStreetMap data

© OpenStreetMap contributors. OpenStreetMap data is available under the
[Open Database License 1.0 (ODbL)](https://opendatacommons.org/licenses/odbl/1-0/).
See [OSM copyright and attribution](https://www.openstreetmap.org/copyright).

The original snapshots in `Data/*.json.gz` and the derived databases in
`Core/Resources/seattle-graph.json.gz` (gzipped JSON), `Core/Resources/seattle-map.geojson`
and `Core/Resources/seattle-search.sqlite.gz` (gzipped SQLite search index)
are distributed under ODbL 1.0, separately from the source-code MIT license.
This repository supplies the underlying data and deterministic transformation
script. Retain attribution and comply with ODbL when redistributing or adapting
these datasets. App screenshots include attribution on the map.

Two manually requested, bounded Overpass extracts were fetched on 2026-10-11.
The raw response timestamps and SHA-256 hashes appear in `provenance.json`.
Timestamps are recorded exactly as reported by the upstream service. They are
not a guarantee of present-day road conditions.

A third bounded extract for search, `Data/seattle-search.json.gz` (query
`Data/seattle-search.overpassql`: named shops, amenities, parks, landmarks and
buildings, and every object with `addr:housenumber`, as centre points), was
fetched on 2026-10-28 (Pacific; OSM base timestamp 2026-10-29T05:43:15Z). It is
newer than the routing extracts; the app shows it as "OpenStreetMap, Oct 2026".

Coverage: 47.615°–47.678° N, 122.390°–122.300° W. Relations may reference source
geometry outside this box; routing edges are kept only when all their geometry
lies inside it. Water and park polygons are clipped. No public map tiles were
downloaded. Search covers named places and OSM street addresses inside the box.

## Street addresses: OpenStreetMap only

Checked on 2026-10-28 and not used:

- **King County "Addresses in King County"** (ArcGIS item
  5aa0a3c77428491da8d73e9d069c10f6, layer `ADDRESS_POINT_642`). The County's
  GIS terms (https://kingcounty.gov/en/dept/kcit/data-information-services/gis-center/about/terms-conditions-copyrights)
  allow copying and distribution but forbid selling the information without a
  written agreement. That conflicts with ODbL share-alike once the points are
  joined to OSM-derived data (our search index stores OSM graph nodes on every
  entry). The layer also joins USPS ZIP+4 data, which is licensed by USPS, and
  the terms page is undated and may change. Some sibling County address layers
  say outright that they may not be redistributed without written permission.
- **City of Seattle "Addresses (MAF)" / "Active Addresses (MAF)"** (ArcGIS
  items 5ef414c3cf73436a84bff413129e67e7, 932cb993682b4d828c75ab1ab26e21d0).
  The item licence field holds only an accuracy disclaimer, with no grant of
  rights to copy or redistribute.

Neither set of terms clearly allows bundling in this app, so no County or City
snapshot is archived here. OSM covers the area about as well already: 51,803 OSM
objects with `addr:housenumber` against 50,529 County points in the same box
(counts taken 2026-10-28), much of it from the earlier, permitted Seattle import
into OSM.

Rebuild derived data offline with `python3 Scripts/import_osm.py`. The queries
are retained here for provenance, not called by the app. Any future refresh
should be deliberate and respect [Overpass resource guidance](https://dev.overpass-api.de/overpass-doc/en/preface/commons.html).
Do not turn the public Overpass endpoint into an app backend. For production,
use regional extracts and a self-hosted update pipeline.
