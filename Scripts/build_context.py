#!/usr/bin/env python3
"""The context map, for zooming out past the detailed map, as two Mapbox Vector Tile archives in PMTiles v3, stored
uncompressed like the detailed map. MapLibre overzooms each past its last zoom. Stdlib only, deterministic.
Schema: "Context map" in Docs/ARCHITECTURE.md.
- Core/Resources/context-map.pmtiles: the whole world, zoom 0 to 6, from Natural Earth (public domain,
  Data/natural-earth.json.gz from Scripts/fetch_natural_earth.py).
- Core/Resources/puget-sound-map.pmtiles: the middle band around Puget Sound, zoom 7 to 10, from OpenStreetMap
  (Data/puget-sound.json.gz from Scripts/fetch_puget_sound.py).
  python3 Scripts/build_context.py [--out DIR]"""
import argparse, gzip, json, os, pathlib
import build_tiles as bt

ROOT = pathlib.Path(__file__).resolve().parent.parent
SNAPSHOT = ROOT / 'Data/natural-earth.json.gz'
BAND = ROOT / 'Data/puget-sound.json.gz'
BAND_ZOOMS = (7, 10)
BAND_LAYERS = {'water': 7, 'road': 7}
MAXZ = 6
EXT, BUF, TOL, MINSIZE = 4096, 64, 10.0, 8.0
# Source layer, then the snapshot keys that fill it with the zooms each covers. Lakes, urban areas, states and roads
# carry their own first zoom from Natural Earth's min_zoom.
POLYS = {'land': [('land110', 0, 1), ('land50', 2, 3), ('land10', 4, MAXZ)], 'lake': [('lakes', None, MAXZ)], 'urban': [('urban', None, MAXZ)]}
LINES = {'country': [('countries', 0, MAXZ)], 'state': [('states', None, MAXZ)], 'road': [('roads', None, MAXZ)]}
LAYERS = {'land': 0, 'lake': 2, 'urban': 4, 'country': 0, 'state': 3, 'road': 4}
LAT = 85.0511  # Web Mercator's edge

def world(c): return bt.world(c[0], max(-LAT, min(LAT, c[1])))

def features(snap):
    """(layer, polygon?, first zoom, last zoom, geometry in world units) for everything the archive holds."""
    out = []
    for layers, poly in ((POLYS, True), (LINES, False)):
        for layer, parts in layers.items():
            for key, lo, hi in parts:
                for item in snap[key]:
                    z, g = (lo, item) if lo is not None else item
                    out.append((layer, poly, z, hi, [[world(c) for c in r] for r in g] if poly else [world(c) for c in g]))
    return out

def bbox(pts):
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)

def clip_ring(pts, x0, y0, x1, y1):
    for axis, lim, greater in ((0, x0, True), (0, x1, False), (1, y0, True), (1, y1, False)):
        if not pts: return []
        prev, pts = pts, []
        a = prev[-1]; ia = a[axis] >= lim if greater else a[axis] <= lim
        for b in prev:
            ib = b[axis] >= lim if greater else b[axis] <= lim
            if ia != ib:
                f = (lim - a[axis]) / (b[axis] - a[axis])
                pts.append((a[0] + f * (b[0] - a[0]), a[1] + f * (b[1] - a[1])))
            if ib: pts.append(b)
            a, ia = b, ib
    return pts

def clip_line(pts, x0, y0, x1, y1):
    # bt.clip_line takes one range for both axes: shift so the box's corner sits at the origin and scale y to x.
    w, h = x1 - x0, y1 - y0
    runs = bt.clip_line([(x - x0, (y - y0) * w / h) for x, y in pts], 0, w)
    return [[(x + x0, y * h / w + y0) for x, y in r] for r in runs]

def clip(feature, box):
    layer, poly, lo, hi, g = feature
    x0, y0, x1, y1 = box
    bx0, by0, bx1, by1 = bbox(g[0] if poly else g)
    if bx1 < x0 or bx0 > x1 or by1 < y0 or by0 > y1: return []
    if bx0 >= x0 and bx1 <= x1 and by0 >= y0 and by1 <= y1: return [feature]
    if poly:
        rings = []
        for j, r in enumerate(g):
            c = clip_ring(r, x0, y0, x1, y1)
            if len(c) >= 3: rings.append(c)
            elif j == 0: return []
        return [(layer, poly, lo, hi, rings)]
    return [(layer, poly, lo, hi, run) for run in clip_line(g, x0, y0, x1, y1) if len(run) >= 2]

def encode(z, x, y, feats):
    scale = 2 ** z * EXT
    local = lambda pts: bt.dp([(a * scale - x * EXT, b * scale - y * EXT) for a, b in pts], TOL)
    polys, lines = {}, {}
    for layer, poly, lo, hi, g in feats:
        if not lo <= z <= hi: continue
        if poly:
            rings = [local(r) for r in g]
            bx0, by0, bx1, by1 = bbox(rings[0])
            if bx1 - bx0 < MINSIZE and by1 - by0 < MINSIZE: continue
            polys.setdefault(layer, []).append(rings)
        else:
            lines.setdefault(layer, []).append(local(g))
    out = {k: (3, bt.geom_poly(v)) for k, v in polys.items()}
    out.update({k: (2, bt.geom_line(v)) for k, v in lines.items()})
    return bt.tile_bytes(out, EXT)

def band_features(snap):
    lo, hi = BAND_ZOOMS
    return [('water', True, lo, hi, [[world(c) for c in r] for r in g]) for g in snap['water']] + \
           [('road', False, max(lo, z), hi, [world(c) for c in g]) for z, g in snap['roads']]

def tiles_for(feats, maxz):
    tiles = {}
    stack = [(0, 0, 0, feats)]
    while stack:
        z, x, y, feats = stack.pop()
        raw = encode(z, x, y, feats)
        if raw: tiles[(z, x, y)] = raw
        if z == maxz: continue
        deeper = [f for f in feats if f[3] > z]
        n = 2 ** (z + 1); pad = BUF / EXT / n
        for cx in (2 * x, 2 * x + 1):
            for cy in (2 * y, 2 * y + 1):
                box = (cx / n - pad, cy / n - pad, (cx + 1) / n + pad, (cy + 1) / n + pad)
                kids = [c for f in deeper for c in clip(f, box)]
                if kids: stack.append((z + 1, cx, cy, kids))
    return tiles

def build(snap):
    return bt.pmtiles(tiles_for(features(snap), MAXZ), (-180, -LAT, 180, LAT), minz=0, maxz=MAXZ, layers=LAYERS,
                      attribution='Natural Earth', name='peoplemaps-context', centerz=0)

def build_band(snap):
    lo, hi = BAND_ZOOMS
    tiles = {k: v for k, v in tiles_for(band_features(snap), hi).items() if k[0] >= lo}
    S, W, N, E = snap['source']['box']
    return bt.pmtiles(tiles, (W, S, E, N), minz=lo, maxz=hi, layers=BAND_LAYERS,
                      attribution='\u00a9 OpenStreetMap contributors', name='peoplemaps-puget-sound', centerz=lo)

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--out', default=os.environ.get('PEOPLEMAPS_OUT', ROOT / 'Core/Resources'))
    args = ap.parse_args()
    for name, make, src in (('context-map', build, SNAPSHOT), ('puget-sound-map', build_band, BAND)):
        data, summary = make(json.loads(gzip.decompress(src.read_bytes())))
        (pathlib.Path(args.out) / f'{name}.pmtiles').write_bytes(data)
        print(f'{name}.pmtiles', summary)

if __name__ == '__main__':
    main()
