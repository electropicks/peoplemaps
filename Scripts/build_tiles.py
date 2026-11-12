#!/usr/bin/env python3
"""Map tiles for the app: OSM lines and polygons to Mapbox Vector Tiles in a PMTiles v3 archive, plus coastline-to-water assembly.
Stdlib only and deterministic. Tiles and directories are stored uncompressed, so the bytes depend on no zlib build.
Schema and rules: "Map tiles" in Docs/ARCHITECTURE.md."""
import collections, json, math, struct

MINZ, MAXZ = 8, 14
# (tile extent, buffer units, Douglas-Peucker tolerance units) by zoom.
def params(z, ext14=8192, tol14=1.5):
    if z >= 14: return ext14, ext14 // 64, tol14
    return 4096, 64, 6.0 if z >= 12 else 10.0

# Which features a source layer holds from which zoom. Anything not listed is not drawn.
HIGHWAY = {
    'motorway': ('arterial', 8), 'trunk': ('arterial', 8), 'primary': ('arterial', 10), 'secondary': ('arterial', 11),
    'motorway_link': ('road', 11), 'trunk_link': ('road', 11), 'primary_link': ('road', 11), 'tertiary': ('road', 11),
    'secondary_link': ('road', 12), 'tertiary_link': ('road', 12), 'residential': ('road', 12), 'unclassified': ('road', 12),
    'living_street': ('road', 12), 'busway': ('road', 12), 'pedestrian': ('road', 13),
    'cycleway': ('path', 12), 'footway': ('path', 14), 'path': ('path', 14), 'steps': ('path', 14), 'track': ('path', 14),
}
def map_line(tags):
    """(source layer, first zoom) for a highway way, or None when the map doesn't draw it."""
    h = tags.get('highway')
    if h == 'service':
        return ('road', 13) if tags.get('service') in (None, 'alley') else ('road', 14)
    return HIGHWAY.get(h)

POLY_START = {'water': 8, 'park': 10}
LAYER_MINZOOM = {'arterial': 8, 'park': 10, 'path': 12, 'road': 11, 'water': 8}

def world(lon, lat):
    s = math.sin(math.radians(lat))
    return (lon + 180) / 360, 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)

def varint(n):
    out = bytearray()
    while n > 0x7F: out.append((n & 0x7F) | 0x80); n >>= 7
    out.append(n); return bytes(out)
def zig(n): return (n << 1) ^ (n >> 31)
def field(num, wire): return varint((num << 3) | wire)
def ld(num, b): return field(num, 2) + varint(len(b)) + b

def dp(pts, tol):
    if len(pts) < 3: return pts
    keep = [False] * len(pts); keep[0] = keep[-1] = True; stack = [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        (x1, y1), (x2, y2) = pts[i], pts[j]; dx, dy = x2 - x1, y2 - y1; L = math.sqrt(dx*dx + dy*dy)  # not hypot: sqrt is correctly rounded everywhere, hypot is not
        far, fd = -1, tol
        for k in range(i + 1, j):
            x, y = pts[k]
            d = abs(dx * (y1 - y) - (x1 - x) * dy) / L if L else math.sqrt((x - x1) ** 2 + (y - y1) ** 2)
            if d > fd: far, fd = k, d
        if far >= 0: keep[far] = True; stack += [(i, far), (far, j)]
    return [p for p, k in zip(pts, keep) if k]

def clip_line(pts, lo, hi):
    runs, cur = [], []
    for a, b in zip(pts, pts[1:]):
        x0, y0 = a; x1, y1 = b; t0, t1 = 0.0, 1.0; dx, dy = x1 - x0, y1 - y0; ok = True
        for p, q in ((-dx, x0 - lo), (dx, hi - x0), (-dy, y0 - lo), (dy, hi - y0)):
            if p == 0:
                if q < 0: ok = False; break
            else:
                r = q / p
                if p < 0:
                    if r > t1: ok = False; break
                    t0 = max(t0, r)
                else:
                    if r < t0: ok = False; break
                    t1 = min(t1, r)
        if not ok:
            if cur: runs.append(cur); cur = []
            continue
        s = (x0 + t0 * dx, y0 + t0 * dy); e = (x0 + t1 * dx, y0 + t1 * dy)
        if not cur: cur = [s, e]
        elif cur[-1] == s: cur.append(e)
        else: runs.append(cur); cur = [s, e]
        if t1 < 1.0: runs.append(cur); cur = []
    if cur: runs.append(cur)
    return runs

def clip_ring(pts, lo, hi):
    for axis, lim, greater in ((0, lo, True), (0, hi, False), (1, lo, True), (1, hi, False)):
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

def geom_line(lines):
    g = []; cx = cy = 0
    for ln in lines:
        q = []
        for x, y in ln:
            x, y = int(round(x)), int(round(y))
            if not q or q[-1] != (x, y): q.append((x, y))
        if len(q) < 2: continue
        g += [(1 << 3) | 1, zig(q[0][0] - cx), zig(q[0][1] - cy)]; cx, cy = q[0]
        g.append(((len(q) - 1) << 3) | 2)
        for x, y in q[1:]:
            g += [zig(x - cx), zig(y - cy)]; cx, cy = x, y
    return g

def area(r): return sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(r, r[1:] + r[:1]))

def geom_poly(polys):
    g = []; cx = cy = 0
    for rings in polys:
        drawn = 0
        for i, ring in enumerate(rings):
            q = []
            for x, y in ring:
                x, y = int(round(x)), int(round(y))
                if not q or q[-1] != (x, y): q.append((x, y))
            if len(q) > 1 and q[0] == q[-1]: q.pop()
            if len(q) < 3: continue
            a = area(q)
            if a == 0: continue
            if i > 0 and not drawn: continue  # a hole never survives its exterior
            if (a > 0) != (i == 0): q.reverse()  # MVT 2: exterior positive area in y-down tile coordinates, holes negative
            g += [(1 << 3) | 1, zig(q[0][0] - cx), zig(q[0][1] - cy)]; cx, cy = q[0]
            g.append(((len(q) - 1) << 3) | 2)
            for x, y in q[1:]:
                g += [zig(x - cx), zig(y - cy)]; cx, cy = x, y
            g.append((1 << 3) | 7)
            drawn += 1
    return g

def tile_bytes(layers, ext):
    out = bytearray()
    for name in sorted(layers):
        kind, geom = layers[name]
        if not geom: continue
        feat = field(3, 0) + varint(kind) + ld(4, b''.join(varint(v) for v in geom))
        out += ld(3, field(15, 0) + varint(2) + ld(1, name.encode()) + ld(2, feat) + field(5, 0) + varint(ext))
    return bytes(out)

def zxy_to_id(z, x, y):
    acc = (4 ** z - 1) // 3
    n = 2 ** z; d = 0; s = n // 2
    while s > 0:
        rx = 1 if x & s else 0; ry = 1 if y & s else 0
        d += s * s * ((3 * rx) ^ ry)
        if ry == 0:
            if rx == 1: x, y = n - 1 - x, n - 1 - y
            x, y = y, x
        s //= 2
    return acc + d

def dir_bytes(es):
    out = bytearray(varint(len(es))); last = 0
    for e in es: out += varint(e[0] - last); last = e[0]
    for e in es: out += varint(e[3])
    for e in es: out += varint(e[2])
    for i, e in enumerate(es):
        out += varint(0 if i > 0 and e[1] == es[i-1][1] + es[i-1][2] else e[1] + 1)
    return bytes(out)

def pmtiles(tiles, bounds, minz=MINZ, maxz=MAXZ, layers=None, attribution='\u00a9 OpenStreetMap contributors', name='peoplemaps', centerz=12):
    """tiles {(z,x,y): bytes}; bounds (W,S,E,N); layers {source layer: first zoom}, LAYER_MINZOOM when None.
    Returns the archive and its counts."""
    blob = bytearray(); seen = {}; entries = []
    for tid, k in sorted((zxy_to_id(*k), k) for k in tiles):
        c = tiles[k]
        if entries and entries[-1][0] + entries[-1][3] == tid and bytes(blob[entries[-1][1]:entries[-1][1] + entries[-1][2]]) == c:
            entries[-1][3] += 1; continue  # the next tile is the same bytes: one run-length entry
        if c in seen: off = seen[c]
        else: off = len(blob); blob += c; seen[c] = off
        entries.append([tid, off, len(c), 1])
    root = dir_bytes(entries); leaf = b''; leafsize = 2048
    while len(root) > 16257:  # header + root must fit the first 16 KiB
        leaves = bytearray(); rootentries = []
        for i in range(0, len(entries), leafsize):
            d = dir_bytes(entries[i:i + leafsize])
            rootentries.append([entries[i][0], len(leaves), len(d), 0]); leaves += d
        root = dir_bytes(rootentries); leaf = bytes(leaves); leafsize *= 2
    W, S, E, N = bounds
    vl = [{'id': k, 'fields': {}, 'minzoom': m, 'maxzoom': maxz} for k, m in sorted((LAYER_MINZOOM if layers is None else layers).items())]
    meta = json.dumps({'attribution': attribution, 'format': 'pbf', 'name': name, 'vector_layers': vl},
                      separators=(',', ':'), sort_keys=True, ensure_ascii=False).encode()
    rootoff = 127; metaoff = rootoff + len(root); leafoff = metaoff + len(meta); dataoff = leafoff + len(leaf)
    e7 = lambda v: int(round(v * 1e7))
    hdr = b'PMTiles\x03' + struct.pack('<QQQQQQQQ', rootoff, len(root), metaoff, len(meta), leafoff, len(leaf), dataoff, len(blob)) + \
        struct.pack('<QQQ', len(tiles), len(entries), len(seen)) + bytes([1, 1, 1, 1, minz, maxz]) + \
        struct.pack('<iiii', e7(W), e7(S), e7(E), e7(N)) + bytes([centerz]) + struct.pack('<ii', e7((W + E) / 2), e7((S + N) / 2))
    assert len(hdr) == 127
    data = hdr + root + meta + leaf + bytes(blob)
    return data, {'addressedTiles': len(tiles), 'tileEntries': len(entries), 'distinctTiles': len(seen), 'bytes': len(data)}

def build(lines, polys, ext14=8192, tol14=1.5):
    """lines: {layer: [(first zoom, [(lon,lat),...])]}; polys: {layer: [[ring, hole, ...]]} with closed (lon,lat) rings.
    Returns the PMTiles bytes and a summary of ints."""
    wl = {k: [(m, [world(*c) for c in ln]) for m, ln in v] for k, v in sorted(lines.items())}
    wp = {k: [[[world(*c) for c in r] for r in p] for p in v] for k, v in sorted(polys.items())}
    tiles = {}
    for z in range(MAXZ, MINZ - 1, -1):
        ext, buf, tol = params(z, ext14, tol14)
        scale = 2 ** z * ext
        bucket = collections.defaultdict(lambda: collections.defaultdict(list))
        for kind, ls in wl.items():
            for m, ln in ls:
                if z < m: continue
                pts = dp([(x * scale, y * scale) for x, y in ln], tol)
                xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
                x0, x1 = int((min(xs) - buf) // ext), int((max(xs) + buf) // ext); y0, y1 = int((min(ys) - buf) // ext), int((max(ys) + buf) // ext)
                for tx in range(x0, x1 + 1):
                    for ty in range(y0, y1 + 1):
                        loc = [(a - tx * ext, b - ty * ext) for a, b in pts]
                        for run in clip_line(loc, -buf, ext + buf): bucket[(tx, ty)][kind].append(run)
        for kind, ps in wp.items():
            if z < POLY_START[kind]: continue
            minsize = 1.0 if z >= 14 else 8.0
            for rings in ps:
                sr = [dp([(x * scale, y * scale) for x, y in r], tol) for r in rings]
                xs = [p[0] for p in sr[0]]; ys = [p[1] for p in sr[0]]
                if max(xs) - min(xs) < minsize and max(ys) - min(ys) < minsize: continue
                x0, x1 = int((min(xs) - buf) // ext), int((max(xs) + buf) // ext); y0, y1 = int((min(ys) - buf) // ext), int((max(ys) + buf) // ext)
                for tx in range(x0, x1 + 1):
                    for ty in range(y0, y1 + 1):
                        cl = []
                        for j, r in enumerate(sr):
                            c = clip_ring([(a - tx * ext, b - ty * ext) for a, b in r], -buf, ext + buf)
                            if len(c) >= 3: cl.append(c)
                            elif j == 0: break
                        if cl: bucket[(tx, ty)]['P' + kind].append(cl)
        for key in sorted(bucket):
            layers = bucket[key]; out = {}
            for kind, v in layers.items():
                if kind.startswith('P'): out[kind[1:]] = (3, geom_poly(v))
                else: out[kind] = (2, geom_line(v))
            raw = tile_bytes(out, ext)
            if raw:
                tiles[(z, *key)] = raw
    allpts = [c for v in lines.values() for _, ln in v for c in ln] + [c for v in polys.values() for p in v for r in p for c in r]
    lons = [c[0] for c in allpts]; lats = [c[1] for c in allpts]
    return pmtiles(tiles, (min(lons), min(lats), max(lons), max(lats)) if allpts else (0, 0, 0, 0))

# ---- coastline ----

def signed_area(r):
    return sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(r, r[1:])) / 2

def point_in_ring(p, ring):
    hit = False
    for a, b in zip(ring, ring[1:]):
        if (a[1] > p[1]) != (b[1] > p[1]) and p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0]: hit = not hit
    return hit

def chains(ways):
    """Join coastline ways end to start, never reversing (OSM: land on the left). Returns (open chains, closed rings) of node ids."""
    by_start = {w['nodes'][0]: w for w in sorted(ways, key=lambda w: w['id'])}
    ends = {w['nodes'][-1] for w in ways}
    used = set(); opens = []; rings = []
    def walk(w):
        ns = list(w['nodes']); used.add(w['id'])
        while ns[0] != ns[-1]:
            nxt = by_start.get(ns[-1])
            if nxt is None or nxt['id'] in used: break
            used.add(nxt['id']); ns += nxt['nodes'][1:]
        return ns
    for w in sorted(ways, key=lambda w: w['id']):
        if w['nodes'][0] not in ends and w['id'] not in used: opens.append(walk(w))
    for w in sorted(ways, key=lambda w: w['id']):
        if w['id'] in used: continue
        ns = walk(w)
        (rings if ns[0] == ns[-1] else opens).append(ns)
    return opens, rings

def clip_runs(pts, box):
    """Pieces of a polyline (lon,lat) inside box S,W,N,E, in travel order. A piece that starts or ends strictly inside is left that way."""
    S, W, N, E = box
    runs = []; cur = []
    for a, b in zip(pts, pts[1:]):
        t0, t1 = 0.0, 1.0; dx, dy = b[0] - a[0], b[1] - a[1]; ok = True
        for p, q in ((-dx, a[0] - W), (dx, E - a[0]), (-dy, a[1] - S), (dy, N - a[1])):
            if p == 0:
                if q < 0: ok = False; break
            else:
                r = q / p
                if p < 0:
                    if r > t1: ok = False; break
                    t0 = max(t0, r)
                else:
                    if r < t0: ok = False; break
                    t1 = min(t1, r)
        if not ok or t0 > t1:
            if cur: runs.append(cur); cur = []
            continue
        # Intersections land on the edge exactly, so `perimeter` can place them without a tolerance.
        snap = lambda p: (W if abs(p[0] - W) < 1e-9 else E if abs(p[0] - E) < 1e-9 else p[0], S if abs(p[1] - S) < 1e-9 else N if abs(p[1] - N) < 1e-9 else p[1])
        s = snap((a[0] + t0 * dx, a[1] + t0 * dy)) if t0 > 0 else a
        e = snap((a[0] + t1 * dx, a[1] + t1 * dy)) if t1 < 1 else b
        if not cur: cur = [s, e]
        else: cur.append(e)
        if t1 < 1: runs.append(cur); cur = []
    if cur: runs.append(cur)
    return runs

def perimeter(p, box):
    """Clockwise distance along the box from its north-west corner."""
    S, W, N, E = box; w, h = E - W, N - S
    x, y = p
    if y == N: return x - W
    if x == E: return w + (N - y)
    if y == S: return w + h + (E - x)
    if x == W: return 2 * w + h + (y - S)
    raise ValueError(f'{p} not on the box edge')

def coast_water(ways, nodes, box):
    """Water polygons inside box from natural=coastline ways. Rings are closed (lon,lat); first ring exterior, rest holes."""
    S, W, N, E = box
    coord = lambda n: (nodes[n]['lon'], nodes[n]['lat'])
    inside = lambda p: S < p[1] < N and W < p[0] < E
    opens, rings = chains(ways)
    for ns in opens:
        for end in (ns[0], ns[-1]):
            if inside(coord(end)): raise ValueError(f'coastline ends inside the map at node {end}: refetch with a wider box or fix the data')
    runs = []; islands = []; lakes = []
    for ns in opens: runs += clip_runs([coord(n) for n in ns], box)
    for ns in rings:
        pts = [coord(n) for n in ns]
        if all(inside(p) for p in pts):
            (islands if signed_area(pts) > 0 else lakes).append(pts)
            continue
        if not any(S <= p[1] <= N and W <= p[0] <= E for p in pts) and not any(True for _ in clip_runs(pts, box)): continue
        # A ring crossing the edge: start it outside the box so its pieces are all edge to edge.
        i = next(k for k, p in enumerate(pts) if not inside(p))
        runs += clip_runs(pts[i:-1] + pts[:i + 1], box)
    runs = [r for r in runs if len(r) >= 2]
    out = []
    corners = [(0.0, (W, N))] + [(E - W, (E, N)), (E - W + N - S, (E, S)), (2 * (E - W) + N - S, (W, S))]
    total = 2 * (E - W + N - S)
    if not runs:
        if islands: out.append([[(W, S), (W, N), (E, N), (E, S), (W, S)]])
    else:
        starts = sorted((perimeter(r[0], box), i) for i, r in enumerate(runs))
        left = set(range(len(runs)))
        for first in sorted(left):
            if first not in left: continue
            ring = []; i = first
            while True:
                left.discard(i); ring += runs[i]
                exit_t = perimeter(runs[i][-1], box)
                # Water lies to the right of travel, so the polygon goes on clockwise along the box edge.
                nxt = min(starts, key=lambda s: ((s[0] - exit_t) % total, s[1]))
                gap = (nxt[0] - exit_t) % total
                for t, c in sorted(((t - exit_t) % total, c) for t, c in corners):
                    if 0 < t < gap: ring.append(c)
                i = nxt[1]
                if i == first: break
                if i not in left: raise ValueError('coastline runs do not close')
            ring.append(ring[0])
            out.append([ring])
    for island in islands:
        host = next((p for p in out if point_in_ring(island[0], p[0])), None)
        if host is not None: host.append(island)
    for lake in lakes: out.append([lake])
    return out
