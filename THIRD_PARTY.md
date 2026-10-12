# Third-party components

**MapLibre Native for iOS 6.31.0** — BSD 2-Clause.

- Source: https://github.com/maplibre/maplibre-native
- Swift package: https://github.com/maplibre/maplibre-gl-native-distribution
- Pinned binary SHA-256 (from the package manifest):
  `de3aaa435dd86768b06d90245e630d068dd7eef1491afae7217d1654c52c462a`
- Upstream license: https://github.com/maplibre/maplibre-native/blob/ios-v6.31.0/LICENSE.md
- The upstream distribution license is retained in `Data/MapLibre-LICENSE.md`
  and bundled in the app. No SDK source is copied here.

**OpenStreetMap** — © OpenStreetMap contributors, ODbL 1.0.

See `Data/LICENSE.md`. App code, raw OSM archives, and derived OSM databases
are kept as distinct licensing scopes. The map uses the local GeoJSON data;
there is no remote tile, font, sprite, geocoder, or routing endpoint at runtime.

**Apple frameworks and SF Symbols** are used through the native iOS SDK.
No Apple or Google routing, place-ranking, or location API is called.
