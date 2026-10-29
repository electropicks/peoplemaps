[out:json][timeout:180][maxsize:268435456];
(
  nwr["addr:housenumber"](47.615,-122.390,47.678,-122.300);
  nwr["name"]["shop"](47.615,-122.390,47.678,-122.300);
  nwr["name"]["amenity"](47.615,-122.390,47.678,-122.300);
  nwr["name"]["leisure"](47.615,-122.390,47.678,-122.300);
  nwr["name"]["tourism"](47.615,-122.390,47.678,-122.300);
  nwr["name"]["historic"](47.615,-122.390,47.678,-122.300);
  nwr["name"]["office"](47.615,-122.390,47.678,-122.300);
  nwr["name"]["craft"](47.615,-122.390,47.678,-122.300);
  nwr["name"]["building"](47.615,-122.390,47.678,-122.300);
  nwr["name"]["railway"~"^(station|halt)$"](47.615,-122.390,47.678,-122.300);
  nwr["name"]["natural"~"^(peak|beach|water|wood)$"](47.615,-122.390,47.678,-122.300);
);
out center tags;
