# Third-party components

The app shows the same credits under About › Acknowledgements, with the full
MapLibre and Ferrostar licence texts bundled (`App/MapLibre-LICENSE.md`,
`App/Ferrostar-LICENSE.md`).

## Software in the app

**MapLibre Native for iOS 6.31.0** — BSD 2-Clause.

- Source: https://github.com/maplibre/maplibre-native
- Swift package: https://github.com/maplibre/maplibre-gl-native-distribution
- Pinned binary SHA-256 (from the package manifest):
  `de3aaa435dd86768b06d90245e630d068dd7eef1491afae7217d1654c52c462a`
- Upstream license: https://github.com/maplibre/maplibre-native/blob/ios-v6.31.0/LICENSE.md
- The upstream distribution license is retained in `Data/MapLibre-LICENSE.md`
  and bundled in the app. No SDK source is copied here.
- Ships its own privacy manifest inside `MapLibre.framework`.

**Ferrostar 0.59.0** (`FerrostarCore` only) — BSD 3-Clause, © 2023 Stadia Maps, Inc.

- Source: https://github.com/stadiamaps/ferrostar
- Redistribution in binary form must reproduce the copyright notice, the
  conditions and the disclaimer; the full text is bundled as
  `App/Ferrostar-LICENSE.md` and shown in the app.
- Ferrostar's navigation core is a Rust static library (`libferrostar`) linked
  into our binary. Its direct Rust dependencies are chrono, geo, polyline,
  rand, serde, serde_json, serde_with, thiserror, uuid and log (MIT or
  Apache-2.0) and uniffi (MPL-2.0; its source is public at
  https://github.com/mozilla/uniffi-rs). Transitive crates are not yet listed
  individually; generate the full list from `common/Cargo.lock` with
  `cargo about` before a public release.
- Ferrostar itself credits Mapbox Directions Icons (Public Domain / CC0).

**Build-time only, not shipped:** `swift-syntax` 602.0.0 (Apache-2.0) and
`swiftui-dsl` 0.26.1 (BSD 3-Clause) are resolved as Ferrostar package
dependencies but not linked into the app, which uses only `FerrostarCore`.

**Apple frameworks and SF Symbols** are used through the native iOS SDK.
No Apple or Google routing, place-ranking, or location API is called.

## Data in the app

**OpenStreetMap** — © OpenStreetMap contributors, ODbL 1.0.

See `Data/LICENSE.md`. App code, raw OSM archives, and derived OSM databases
are kept as distinct licensing scopes. The map uses the local GeoJSON data;
there is no remote tile, font, sprite, geocoder, or routing endpoint at runtime.
The map shows a visible "© OpenStreetMap" attribution link.

Search (`Core/Resources/seattle-search.sqlite.gz`) is built from a separate OSM
extract fetched on 2026-10-28 and also uses OSM for street addresses. King County
and City of Seattle address points were reviewed and not used: their terms
do not clearly allow redistribution in this app (details in `Data/LICENSE.md`).
Results are labelled with their source and date ("OpenStreetMap, Oct 2026").

**USGS 3D Elevation Program (3DEP)** — public domain; credit requested.

Elevation comes from the 3DEP ground model (~5 m, exported from the
3DEPElevation ImageServer; see `Data/provenance.json`), sampled into the street
graph by `Scripts/import_osm.py`. Credit: U.S. Geological Survey, 3D Elevation
Program, https://www.usgs.gov/3d-elevation-program.
