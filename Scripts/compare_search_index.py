#!/usr/bin/env python3
"""Says how two search-index files differ: the gzip stream, the SQLite page layout, or the rows themselves.

Called by verify.sh when a fresh import's seattle-search.sqlite.gz is not byte-identical to the shipped
one, to tell a zlib or SQLite build difference from a change in the data.

    python3 Scripts/compare_search_index.py <fresh.sqlite.gz> <shipped.sqlite.gz>"""
import gzip, hashlib, os, sqlite3, sys, tempfile, zlib


def sha(data):
    return hashlib.sha256(data).hexdigest()[:16]


def describe(path):
    gz = open(path, 'rb').read()
    raw = gzip.decompress(gz)
    fd, name = tempfile.mkstemp(suffix='.sqlite')
    with os.fdopen(fd, 'wb') as f:
        f.write(raw)
    try:
        db = sqlite3.connect(name)
        rows = hashlib.sha256()
        for table in ['meta', 'entries']:
            for row in db.execute(f'SELECT * FROM {table} ORDER BY 1'):
                rows.update(repr(row).encode())
        page = lambda pragma: db.execute(f'PRAGMA {pragma}').fetchone()[0]
        layout = {'page_size': page('page_size'), 'page_count': page('page_count'), 'freelist_count': page('freelist_count'),
                  'schema_version': page('schema_version'), 'fts_rows': db.execute('SELECT count(*) FROM fts').fetchone()[0]}
        entries = db.execute('SELECT * FROM entries ORDER BY id').fetchall()
        meta = dict(db.execute('SELECT key, value FROM meta').fetchall())
        db.close()
    finally:
        os.unlink(name)
    return {'gz': (len(gz), sha(gz)), 'raw': (len(raw), sha(raw)), 'rows': rows.hexdigest()[:16], 'layout': layout,
            'entries': entries, 'meta': meta}


def main(fresh_path, shipped_path):
    fresh, shipped = describe(fresh_path), describe(shipped_path)
    print(f'environment: sqlite {sqlite3.sqlite_version}, zlib {zlib.ZLIB_RUNTIME_VERSION}, python {sys.version.split()[0]}')
    for label, d in [('fresh', fresh), ('shipped', shipped)]:
        print(f'{label:8s} gz {d["gz"][0]} bytes {d["gz"][1]}  sqlite {d["raw"][0]} bytes {d["raw"][1]}  rows {d["rows"]}  {d["layout"]}')
    if fresh['gz'] == shipped['gz']:
        print('verdict: identical')
    elif fresh['raw'] == shipped['raw']:
        print('verdict: same SQLite bytes; only the gzip stream differs (zlib build)')
    elif fresh['rows'] == shipped['rows']:
        print('verdict: same rows; the SQLite page layout differs (SQLite build or compile options)')
    else:
        print('verdict: the rows differ')
        for key in sorted(set(fresh['meta']) | set(shipped['meta'])):
            if fresh['meta'].get(key) != shipped['meta'].get(key):
                print(f'  meta {key}: fresh {fresh["meta"].get(key)!r}, shipped {shipped["meta"].get(key)!r}')
        a, b = fresh['entries'], shipped['entries']
        if len(a) != len(b):
            print(f'  entries: fresh {len(a)} rows, shipped {len(b)} rows')
        for x, y in zip(a, b):
            if x != y:
                print(f'  first differing entry: fresh {x}\n                         shipped {y}')
                break
    return 0


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:3]))
