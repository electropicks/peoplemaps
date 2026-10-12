[out:json][timeout:90][maxsize:134217728];
(
  way["highway"](47.615,-122.390,47.678,-122.300);
  relation["type"="restriction"](47.615,-122.390,47.678,-122.300);
  way["leisure"~"^(park|garden|pitch)$"](47.615,-122.390,47.678,-122.300);
  way["natural"="water"](47.615,-122.390,47.678,-122.300);
  relation["natural"="water"](47.615,-122.390,47.678,-122.300);
  nwr["name"]["tourism"~"^(attraction|museum|viewpoint)$"](47.615,-122.390,47.678,-122.300);
  nwr["name"]["amenity"~"^(library|cafe)$"](47.615,-122.390,47.678,-122.300);
);
(._;>;);
out body;
