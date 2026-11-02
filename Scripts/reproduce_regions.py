#!/usr/bin/env python3
"""Reproduce each full region in Data/regions.json from its fetched files (see Scripts/fetch_data) and compare the
importer's outputs byte for byte with the fetched expected outputs. Regions not fetched are skipped, and it says so.
Run from the repository root; Scripts/verify.sh --region calls it."""
import json, os, pathlib, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
m = json.loads((root / 'Data/regions.json').read_text())
bad = ran = 0
for name, r in sorted(m['regions'].items()):
    d = root / 'Data/region' / name
    missing = [f for f in r['files'] if not (d / f).is_file()]
    if missing:
        print(f'SKIPPED region {name}: {len(missing)} files not fetched; run Scripts/fetch_data {name}')
        continue
    ran += 1
    out = pathlib.Path(tempfile.mkdtemp())
    env = dict(os.environ, PEOPLEMAPS_DATA=str(d), PEOPLEMAPS_BBOX=','.join(map(str, r['bbox'])), PEOPLEMAPS_OUT=str(out))
    p = subprocess.run([sys.executable, str(root / 'Scripts/import_osm.py'), '--out', str(out)], env=env, capture_output=True, text=True)
    if p.returncode:
        print(p.stdout[-2000:], p.stderr[-2000:]); bad += 1; continue
    # The search index's bytes (and so provenance.json's size line) depend on the SQLite version, as in verify.sh.
    built = __import__('sqlite3').sqlite_version; shipped = json.loads((d / 'expected/provenance.json').read_text())['search']['sqlite'] if (d / 'expected/provenance.json').is_file() else built
    for f in r['outputs']:
        if built != shipped and (f.endswith('.sqlite.gz') or f == 'provenance.json'):
            print(f'region {name}: SQLite {built} here, {shipped} shipped: {f} not compared'); continue
        if (out / f).read_bytes() != (d / 'expected' / f).read_bytes():
            print(f'region {name}: differs from a fresh import: {f}'); bad += 1
if not m['regions']: print('SKIPPED regions: none listed in Data/regions.json')
elif not ran: print('SKIPPED regions: no region data fetched')
sys.exit(1 if bad else 0)
