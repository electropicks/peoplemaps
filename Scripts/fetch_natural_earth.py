#!/usr/bin/env python3
"""Take a new Natural Earth snapshot for the zoomed-out context map: Data/natural-earth.json.gz.
Natural Earth is public domain. Files come from one tagged release of github.com/nvkelso/natural-earth-vector (the tag
is the pin), and their SHA-256 is recorded in the snapshot. Only the geometry and first zoom the context map needs are
kept, roads only in North America, simplified to TOLERANCE degrees (finer than the context map's last zoom draws) and
rounded to 3 decimals (about 100 m, finer than the 1:10m source).
Deterministic: the same downloads give the same bytes. Not part of the importer; run it only when asked for new data.
  python3 Scripts/fetch_natural_earth.py [--from DIR]    DIR holds the .geojson files already downloaded"""
import argparse, gzip, hashlib, json, math, pathlib, urllib.request
from build_tiles import dp

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'Data/natural-earth.json.gz'
RELEASE = 'v5.1.2'
BASE = f'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/{RELEASE}/geojson/'
FILES = ['ne_110m_land', 'ne_50m_land', 'ne_10m_land', 'ne_10m_lakes', 'ne_10m_urban_areas',
         'ne_10m_admin_0_boundary_lines_land', 'ne_10m_admin_1_states_provinces_lines', 'ne_10m_roads']
TOLERANCE = 0.002
LAST = 6  # the context map's highest zoom: anything Natural Earth shows only past it is left out

def pt(c): return [round(c[0], 3), round(c[1], 3)]

def thin(cs):
    out = []
    for c in dp([tuple(c[:2]) for c in cs], TOLERANCE):
        p = pt(c)
        if not out or out[-1] != p: out.append(p)
    return out

def ring(r):
    out = thin(r)
    return out if len(out) >= 4 else None

def polygons(g):
    polys = [g['coordinates']] if g['type'] == 'Polygon' else g['coordinates']
    for p in polys:
        rings = [ring(r) for r in p]
        if rings[0]: yield [r for r in rings if r]

def lines(g):
    for ln in [g['coordinates']] if g['type'] == 'LineString' else g['coordinates']:
        q = thin(ln)
        if len(q) >= 2: yield q

def first(props, key, floor):
    """Natural Earth's min_zoom as the first whole zoom that shows the feature, or None past LAST."""
    z = max(floor, math.ceil(props.get(key) or 0))
    return z if z <= LAST else None

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--from', dest='src'); args = ap.parse_args()
    raw, sha = {}, {}
    for name in FILES:
        data = (pathlib.Path(args.src) / f'{name}.geojson').read_bytes() if args.src else urllib.request.urlopen(BASE + name + '.geojson').read()
        sha[name] = hashlib.sha256(data).hexdigest(); raw[name] = json.loads(data)['features']
    geom = lambda f: f.get('geometry')
    snap = {'source': {'name': 'Natural Earth', 'licence': 'public domain', 'release': RELEASE, 'url': BASE, 'sha256': sha}}
    for key, name in (('land110', 'ne_110m_land'), ('land50', 'ne_50m_land'), ('land10', 'ne_10m_land')):
        snap[key] = [p for f in raw[name] if geom(f) for p in polygons(f['geometry'])]
    snap['lakes'] = [[z, p] for f in raw['ne_10m_lakes'] if geom(f) and (z := first(f['properties'], 'min_zoom', 2)) is not None for p in polygons(f['geometry'])]
    snap['urban'] = [[z, p] for f in raw['ne_10m_urban_areas'] if geom(f) and (z := first(f['properties'], 'min_zoom', 4)) is not None for p in polygons(f['geometry'])]
    snap['countries'] = [ln for f in raw['ne_10m_admin_0_boundary_lines_land'] if geom(f) for ln in lines(f['geometry'])]
    snap['states'] = [[z, ln] for f in raw['ne_10m_admin_1_states_provinces_lines'] if geom(f) and (z := first(f['properties'], 'MIN_ZOOM', 3)) is not None for ln in lines(f['geometry'])]
    snap['roads'] = [[z, ln] for f in raw['ne_10m_roads'] if geom(f) and f['properties'].get('featurecla') != 'Ferry' and f['properties'].get('continent') == 'North America'
                     and (z := first(f['properties'], 'min_zoom', 4)) is not None for ln in lines(f['geometry'])]
    for k in ('lakes', 'urban', 'states', 'roads'): snap[k].sort(key=json.dumps)
    for k in ('land110', 'land50', 'land10', 'countries'): snap[k].sort(key=json.dumps)
    OUT.write_bytes(gzip.compress(json.dumps(snap, separators=(',', ':'), sort_keys=True).encode(), 9, mtime=0))
    print(f'{OUT.relative_to(ROOT)}: {OUT.stat().st_size / 1e6:.1f} MB', {k: len(v) for k, v in snap.items() if k != 'source'})

if __name__ == '__main__':
    main()
