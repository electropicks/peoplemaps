[out:json][timeout:300];
(
  way["natural"="coastline"](46.4,-124.0,48.9,-121.2);
  way["highway"~"^(motorway|trunk|primary)$"](46.6,-123.8,48.7,-121.4);
  way["natural"="water"]["name"](46.6,-123.8,48.7,-121.4);
  relation["natural"="water"]["name"](46.6,-123.8,48.7,-121.4);
);
(._;>;);
out body;
