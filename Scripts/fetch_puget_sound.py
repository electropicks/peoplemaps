#!/usr/bin/env python3
"""Take a new Puget Sound snapshot for the context map's middle band: Data/puget-sound.json.gz.
OpenStreetMap (ODbL) from Overpass, query Data/puget-sound.overpassql: coastline, named water and main roads. The raw
response is about 64 MB, so what is archived is the shapes the band draws, already assembled: water polygons inside BOX
(the sea from the coastline, as the detailed map does, plus named lakes) and motorway, trunk and primary lines. They are
simplified to TOLERANCE degrees (finer than the band's last zoom draws) and rounded to 5 decimals. The response's
timestamp and SHA-256 are recorded. Deterministic: the same response gives the same bytes. Not part of the importer;
run it only when asked for new data.
  python3 Scripts/fetch_puget_sound.py [--from FILE]    FILE is a response already downloaded"""
import argparse, gzip, hashlib, json, pathlib, urllib.parse, urllib.request
import build_tiles
from build_tiles import dp
from import_osm import clip_ring, point_in_ring, stitch

ROOT = pathlib.Path(__file__).resolve().parent.parent
QUERY = ROOT / 'Data/puget-sound.overpassql'
OUT = ROOT / 'Data/puget-sound.json.gz'
BOX = (46.8, -123.4, 48.5, -121.6)  # S,W,N,E; the query reaches past it so every coastline leaves it
TOLERANCE = 0.0002
MIN_SPAN = 0.003  # degrees: smaller lakes are dropped
ROADS = {'motorway': 7, 'trunk': 7, 'primary': 9}

def thin(cs):
    out = []
    for c in dp([tuple(c) for c in cs], TOLERANCE):
        p = [round(c[0], 5), round(c[1], 5)]
        if not out or out[-1] != p: out.append(p)
    return out

def big(ring):
    xs = [c[0] for c in ring]; ys = [c[1] for c in ring]
    return max(xs) - min(xs) >= MIN_SPAN or max(ys) - min(ys) >= MIN_SPAN

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--from', dest='src'); args = ap.parse_args()
    if args.src: data = pathlib.Path(args.src).read_bytes()
    else:
        req = urllib.request.Request('https://overpass-api.de/api/interpreter', urllib.parse.urlencode({'data': QUERY.read_text()}).encode(),
                                     headers={'User-Agent': 'peoplemaps-data/1.0'})
        data = urllib.request.urlopen(req, timeout=600).read()
    p = json.loads(data)
    if p.get('remark'): raise SystemExit(p['remark'])
    nodes = {e['id']: e for e in p['elements'] if e['type'] == 'node'}
    ways = {e['id']: e for e in p['elements'] if e['type'] == 'way'}
    coords = lambda ns: [(nodes[n]['lon'], nodes[n]['lat']) for n in ns if n in nodes]
    water = build_tiles.coast_water([w for w in ways.values() if w.get('tags', {}).get('natural') == 'coastline'], nodes, BOX)
    lakes = []
    for w in sorted(ways.values(), key=lambda w: w['id']):
        if w.get('tags', {}).get('natural') == 'water' and w['nodes'][0] == w['nodes'][-1]:
            ring = clip_ring([list(c) for c in coords(w['nodes'])], BOX)
            if ring: lakes.append([ring])
    for r in sorted((e for e in p['elements'] if e['type'] == 'relation'), key=lambda r: r['id']):
        groups = {role: stitch([ways[m['ref']]['nodes'][:] for m in r['members'] if m['type'] == 'way' and m['ref'] in ways and m['role'] == role]) for role in ('outer', 'inner')}
        inners = [clip_ring([list(c) for c in coords(ns)], BOX) for ns in groups['inner']]
        for ns in groups['outer']:
            ring = clip_ring([list(c) for c in coords(ns)], BOX)
            if ring: lakes.append([ring] + [h for h in inners if h and point_in_ring(h[0], ring)])
    polys = []
    for poly in water + [l for l in lakes if big(l[0])]:
        rings = [thin(r) for r in poly]
        if len(rings[0]) >= 4: polys.append([r for r in rings if len(r) >= 4])
    S, W, N, E = BOX
    roads = []
    for w in sorted(ways.values(), key=lambda w: w['id']):
        z = ROADS.get(w.get('tags', {}).get('highway'))
        if z is None: continue
        for run in build_tiles.clip_runs(coords(w['nodes']), BOX):
            q = thin(run)
            if len(q) >= 2: roads.append([z, q])
    snap = {'source': {'name': 'OpenStreetMap', 'licence': 'ODbL 1.0', 'query': QUERY.name, 'box': list(BOX),
                       'osmBaseTimestamp': p['osm3s']['timestamp_osm_base'], 'sha256': hashlib.sha256(data).hexdigest()},
            'water': polys, 'roads': roads}
    OUT.write_bytes(gzip.compress(json.dumps(snap, separators=(',', ':'), sort_keys=True).encode(), 9, mtime=0))
    print(f'{OUT.relative_to(ROOT)}: {OUT.stat().st_size / 1e6:.1f} MB', {'water': len(polys), 'roads': len(roads)})

if __name__ == '__main__':
    main()
