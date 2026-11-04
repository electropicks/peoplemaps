#!/usr/bin/env python3
"""A region's coverage polygon: one OSM boundary relation from a Geofabrik .osm.pbf, grown by a buffer, simplified.

    uv run --python 3.13 --with shapely Scripts/region_polygon.py washington-261031.osm.pbf 1153346 4828 out.json

Writes {"osmRelation", "bufferMeters", "bbox": [S,W,N,E], "rings": [[[lon,lat], ...], ...]}: exterior rings only. Not part
of the importer, which reads the result and stays stdlib-only, as fetch_overture.py does with pyarrow. Buffering is in a
flat projection at the region's mean latitude: the error across King County is under 0.5% of the buffer. Rounded to 1e-5
degrees (about 1 m)."""
import json, math, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import pbf_to_snapshot as pbf
from shapely.geometry import LineString
from shapely.ops import polygonize, unary_union

def relation_members(blobs, rid):
    for job in blobs:
        strings, gran, lat_off, lon_off, groups = pbf.block(job)
        for g in groups:
            for f, v in pbf.fields(g):
                if f != 4: continue
                d = {}
                for ff, vv in pbf.fields(v): d[ff] = vv
                if d.get(1) != rid: continue
                types = pbf.unpack_uint(d[10]); mems = pbf.unpack_delta(d[9]); roles = pbf.unpack_uint(d[8])
                return [m for t, m, r in zip(types, mems, roles) if t == 1 and strings[r].decode() == 'outer']
    sys.exit(f'relation {rid} is not in the extract')

def main(path, rid, buffer_m, out):
    pbf.PATH = path; pbf.BOX = [0.0, 0.0, 0.0, 0.0]  # unused: only ids are asked for
    blobs, _ = pbf.index_blobs(path)
    want = set(relation_members(blobs, int(rid)))
    pbf.WANT_WAYS = want
    ways = {i: r for i, r, t in pbf.run(pbf.scan_ways, blobs, 8)}
    pbf.WANT_WAYS = set()
    if want - set(ways): sys.exit(f'{len(want - set(ways))} boundary ways missing from the extract')
    pbf.WANT_NODES = {n for r in ways.values() for n in r}
    nodes = {i: (la, lo) for i, la, lo, t in pbf.run(pbf.scan_nodes, blobs, 8)}
    lat0 = sum(p[0] for p in nodes.values()) / len(nodes)
    k = math.cos(math.radians(lat0)) * 111_320; m = 110_574  # metres per degree here
    lines = [LineString([(nodes[n][1] * k, nodes[n][0] * m) for n in r]) for r in ways.values()]
    county = unary_union(list(polygonize(unary_union(lines))))
    grown = county.buffer(float(buffer_m), quad_segs=8).simplify(25)
    polys = list(grown.geoms) if grown.geom_type == 'MultiPolygon' else [grown]
    rings = [[[round(x / k, 5), round(y / m, 5)] for x, y in p.exterior.coords] for p in sorted(polys, key=lambda p: -p.area)]
    lons = [c[0] for r in rings for c in r]; lats = [c[1] for r in rings for c in r]
    doc = {'osmRelation': int(rid), 'bufferMeters': float(buffer_m), 'bbox': [min(lats), min(lons), max(lats), max(lons)], 'rings': rings}
    pathlib.Path(out).write_text(json.dumps(doc, separators=(',', ':')) + '\n')
    print(f'county {county.area/1e6:.0f} km2, grown {grown.area/1e6:.0f} km2, {len(rings)} rings, {sum(map(len, rings))} points, bbox {doc["bbox"]}')

if __name__ == '__main__':
    main(*sys.argv[1:5])
