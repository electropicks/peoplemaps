# OpenStreetMap data

© OpenStreetMap contributors. OpenStreetMap data is available under the
[Open Database License 1.0 (ODbL)](https://opendatacommons.org/licenses/odbl/1-0/).
See [OSM copyright and attribution](https://www.openstreetmap.org/copyright).

The original snapshots in `Data/*.json.gz` and the derived databases in
`Core/Resources/seattle-graph.bin` (binary graph), `Core/Resources/seattle-map.geojson`
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
downloaded. Search covers named places, Overture Maps businesses (below) and OSM street addresses inside the box.

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

## Overture Maps Places

`Data/seattle-overture-places.json.gz` is a bounded extract of the Overture Maps Foundation
Places theme, release 2026-10-21.0, for 47.49–47.74 N, 122.44–122.24 W, fetched on 2026-10-30
with `Scripts/fetch_overture.py`. It keeps each place's name, position, categories, confidence,
operating status, freeform address and sources (dataset, record ID, licence, update time).
It holds no phone numbers, emails, websites, social links or brands. Its SHA-256 is in
`provenance.json`. The Places theme contains no OpenStreetMap data; each record is licensed by
its source, and the importer keeps a record only if its first source is one of these under the
licence shown:

| Source | Licence | Rows in the shipped index |
|---|---|---|
| Meta | CDLA Permissive 2.0 | 3,034 |
| BrightQuery | CDLA Permissive 2.0 | 2,514 |
| Foursquare | Apache 2.0, "Copyright 2024 Foursquare Labs, Inc. All rights reserved" | 1,424 |
| Microsoft | CDLA Permissive 2.0 | 1,404 |
| AllThePlaces | CC0 1.0 | 243 |
| Uberall | CDLA Permissive 2.0 | 15 |
| Birdeye | CDLA Permissive 2.0 | 13 |
| DAC | CDLA Permissive 2.0 | 8 |

Attribution per source: https://github.com/OvertureMaps/docs/blob/main/docs/_generated_attribution.mdx
(Places section). The licence texts are in `Data/licenses/`: `CDLA-Permissive-2.0.md`,
`Apache-2.0.txt`, and Foursquare's `Foursquare-NOTICE.txt` (from
https://opensource.foursquare.com/places-notice-txt/, with our notice of changes). The Foursquare
data was transformed to the Overture schema by Overture on 2026-03-18; we filtered it further to the
fields above and to Seattle. CC0 data needs no notice. Sources Overture attributes but that have
no rows in the shipped index (PinMeTo, Krick, RenderSEO, OpenTravel) are not listed above.

Merging these places with OpenStreetMap (removing duplicates, taking a missing category from
Overture) makes `Core/Resources/seattle-search.sqlite.gz` a derivative database. The combined
index is distributed under ODbL 1.0, with the attribution above and "© OpenStreetMap
contributors"; every Overture-sourced row is identifiable by its `source` column (for example
`Overture · Foursquare`, entry IDs starting `overture/`), and the OSM rows are marked
`OpenStreetMap`. The data is provided as is, without warranties or conditions of any kind:
records may be out of date, mislocated or wrongly categorised, and a business shown may have
closed. The app shows the release date, not the age of each record.

Rebuild derived data offline with `python3 Scripts/import_osm.py`. The queries
are retained here for provenance, not called by the app. Any future refresh
should be deliberate and respect [Overpass resource guidance](https://dev.overpass-api.de/overpass-doc/en/preface/commons.html).
Do not turn the public Overpass endpoint into an app backend. For production,
use regional extracts and a self-hosted update pipeline.
