#!/usr/bin/env python3
"""Offline search index (SQLite + FTS5) of named places and street addresses, from OSM only.

Called by import_osm.py once the routing graph is built, so every entry can carry the graph node
it routes from or to. Deterministic for a given input and SQLite version; no network."""
import collections, gzip, hashlib, json, math, os, pathlib, re, sqlite3, tempfile, unicodedata

SCHEMA_VERSION = 1
DEDUPE_METERS = 50
SNAP_METERS = 400  # the router's own snap radius

# Both spellings are indexed, so "ave", "av" and "avenue" all prefix-match a street called "... Avenue".
ALIASES = {
    'north': ['n'], 'south': ['s'], 'east': ['e'], 'west': ['w'],
    'northeast': ['ne'], 'northwest': ['nw'], 'southeast': ['se'], 'southwest': ['sw'],
    'street': ['st'], 'avenue': ['ave', 'av'], 'boulevard': ['blvd'], 'place': ['pl'], 'drive': ['dr'],
    'road': ['rd'], 'lane': ['ln'], 'parkway': ['pkwy'], 'terrace': ['ter'], 'court': ['ct'],
    'highway': ['hwy'], 'mount': ['mt'], 'saint': ['st'],
}
# Weights for the graph's own places, whose category is already a single word.
GRAPH_WEIGHT = {'park': 90, 'museum': 100, 'attraction': 100, 'viewpoint': 100, 'library': 70, 'cafe': 50}

# Landmarks and parks over shops; addresses last. Higher is better.
LANDMARK = {'attraction', 'museum', 'viewpoint', 'gallery', 'zoo', 'aquarium', 'memorial', 'monument', 'castle', 'ship'}
NATURE = {'park', 'garden', 'nature_reserve', 'beach', 'peak', 'wood', 'water', 'dog_park', 'playground'}
CIVIC = {'library', 'station', 'halt', 'university', 'college', 'school', 'hospital', 'community_centre', 'theatre',
         'cinema', 'marina', 'sports_centre', 'stadium', 'place_of_worship', 'townhall', 'arts_centre', 'swimming_pool',
         'ferry_terminal', 'post_office', 'police', 'fire_station', 'events_venue'}
SKIP = {'parking_entrance', 'parking_space', 'bench', 'waste_basket', 'vending_machine', 'grit_bin', 'toilets'}
CATEGORY_KEYS = ['tourism', 'historic', 'leisure', 'natural', 'railway', 'amenity', 'shop', 'office', 'craft', 'building']


def fold(text):
    """Lowercase, accents and apostrophes removed, punctuation to spaces. Swift's SearchIndex.normalize matches this."""
    text = unicodedata.normalize('NFKD', text.casefold())
    text = ''.join(c for c in text if not unicodedata.combining(c))
    text = re.sub(r"['’`]", '', text).replace('&', ' and ')
    return ' '.join(re.sub(r'[^\w]+', ' ', text).replace('_', ' ').split())


def aliases(folded):
    return ' '.join(a for t in folded.split() for a in ALIASES.get(t, []))


def category_of(tags):
    """(category, weight) for a named feature, or None when it isn't something people search for."""
    for key in CATEGORY_KEYS:
        value = tags.get(key)
        if not value or value == 'no':
            continue
        if key == 'historic':
            value = value if value in LANDMARK else 'historic'
        if key == 'building':
            return ('building', 30)
        if key in ('office', 'craft'):
            return (key, 40)
        if value in SKIP:
            return None
        if value in LANDMARK:
            return (value, 100)
        if key == 'historic':  # historic houses and buildings: worth finding, not landmarks
            return (value, 50)
        if value in NATURE:
            return (value, 90)
        if value in CIVIC:
            return (value, 70)
        if key == 'tourism' and value == 'artwork':
            return (value, 50)
        return (value, 50)
    return None


def address_of(tags):
    """'1100 Northeast 45th Street' and the unit, or (None, None) without a house number and street."""
    number, street = tags.get('addr:housenumber', '').strip(), tags.get('addr:street', '').strip()
    if not number or not street or ';' in number:
        return None, None
    return f'{number} {street}', tags.get('addr:unit', '').strip() or None


def meters(a, b):
    x = math.radians(b[1]-a[1]) * math.cos(math.radians((a[0]+b[0])/2))
    return math.hypot(x, math.radians(b[0]-a[0])) * 6371000


def entries_from(elements, graph_places, inside):
    """Graph places first (their IDs are what the app features and tests use), then the search extract.
    Named places dedupe on the same OSM ID or the same folded name within 50 m; addresses on the same
    number, street and unit within 50 m. The first one kept wins."""
    entries = []
    for p in graph_places:
        entries.append({'osm': p['id'], 'kind': 'place', 'name': p['name'], 'category': p['category'],
                        'lat': p['lat'], 'lon': p['lon'], 'weight': GRAPH_WEIGHT.get(p['category'], 50),
                        'address': None, 'unit': None, 'number': None})
    candidates = []
    for e in elements:
        tags = e.get('tags', {})
        c = (e['lat'], e['lon']) if e['type'] == 'node' else (e['center']['lat'], e['center']['lon']) if 'center' in e else None
        if c is None or not inside({'lat': c[0], 'lon': c[1]}):
            continue
        address, unit = address_of(tags)
        name, category = tags.get('name', '').strip(), category_of(tags)
        if name and category:
            candidates.append({'osm': f"{e['type']}/{e['id']}", 'kind': 'place', 'name': name, 'category': category[0],
                               'lat': round(c[0], 7), 'lon': round(c[1], 7), 'weight': category[1],
                               'address': address, 'unit': unit, 'number': tags.get('addr:housenumber') if address else None})
        if address:
            candidates.append({'osm': f"{e['type']}/{e['id']}", 'kind': 'address', 'name': address + (f', Unit {unit}' if unit else ''),
                               'category': None, 'lat': round(c[0], 7), 'lon': round(c[1], 7), 'weight': 10,
                               'address': None, 'unit': unit, 'number': tags['addr:housenumber']})
    candidates.sort(key=lambda x: (-x['weight'], x['kind'], x['osm'].split('/')[0], int(x['osm'].split('/')[1])))
    kept, seen_ids, cell = [], set(), 0.001
    grid = collections.defaultdict(list)
    def key(x): return fold(x['name']) if x['kind'] == 'place' else (fold(x['name']), 'address')
    for x in entries + candidates:
        if (x['osm'], x['kind']) in seen_ids:
            continue
        k, gx, gy = key(x), int(x['lon']/cell), int(x['lat']/cell)
        near = (y for dx in (-1, 0, 1) for dy in (-1, 0, 1) for y in grid[(gx+dx, gy+dy)])
        if any(key(y) == k and meters((x['lat'], x['lon']), (y['lat'], y['lon'])) <= DEDUPE_METERS for y in near):
            continue
        seen_ids.add((x['osm'], x['kind'])); grid[(gx, gy)].append(x); kept.append(x)
    # Graph places come from the older routing extract: fill in their address from the search extract.
    by_id = {x['osm']: x for x in candidates if x['kind'] == 'place'}
    for x in kept[:len(graph_places)]:
        if x['osm'] in by_id and by_id[x['osm']]['address']:
            x['address'], x['unit'], x['number'] = by_id[x['osm']]['address'], by_id[x['osm']]['unit'], by_id[x['osm']]['number']
    return kept


def routable_nodes(nodes, segments):
    """Per mode, the graph nodes the router can snap to both as start and end: in the largest strongly
    connected component for that mode (as NativeRouter computes it) with a non-motorway edge in and out."""
    result = {}
    for mode in ['walk', 'bike', 'drive']:
        out, inc = collections.defaultdict(list), collections.defaultdict(list)
        usable_out, usable_in = set(), set()
        for s in segments:
            highway = s['hw'].startswith('motorway') or s['hw'].startswith('trunk')
            for key, a, b in (('f', s['a'], s['b']), ('r', s['b'], s['a'])):
                if mode in s.get(key, {}).get('modes', []):
                    out[a].append(b); inc[b].append(a)
                    if not highway:
                        usable_out.add(a); usable_in.add(b)
        visited, order = set(), []
        for root in range(len(nodes)):
            if root in visited:
                continue
            stack = [(root, False)]
            while stack:
                n, expanded = stack.pop()
                if expanded:
                    order.append(n); continue
                if n in visited:
                    continue
                visited.add(n); stack.append((n, True))
                stack.extend((m, False) for m in out[n] if m not in visited)
        visited, largest = set(), set()
        for root in reversed(order):
            if root in visited:
                continue
            component, stack = set(), [root]
            while stack:
                n = stack.pop()
                if n in visited:
                    continue
                visited.add(n); component.add(n)
                stack.extend(m for m in inc[n] if m not in visited)
            if len(component) > len(largest):
                largest = component
        result[mode] = sorted(largest & usable_out & usable_in)
    return result


def snap(entries, nodes, routable):
    """Nearest routable node index per mode within SNAP_METERS, or None. Ties go to the lower index."""
    cell = 0.004  # ~300-450 m; three cells either way covers the radius
    for mode, ids in routable.items():
        grid = collections.defaultdict(list)
        for i in ids:
            grid[(int(nodes[i]['lon']/cell), int(nodes[i]['lat']/cell))].append(i)
        for x in entries:
            gx, gy, best = int(x['lon']/cell), int(x['lat']/cell), None
            for dx in (-2, -1, 0, 1, 2):
                for dy in (-2, -1, 0, 1, 2):
                    for i in grid.get((gx+dx, gy+dy), ()):
                        d = meters((x['lat'], x['lon']), (nodes[i]['lat'], nodes[i]['lon']))
                        if d <= SNAP_METERS and (best is None or (d, i) < best):
                            best = (d, i)
            x[mode] = best[1] if best else None


def write_database(path, entries, meta):
    if path.exists():
        path.unlink()
    db = sqlite3.connect(path)
    db.executescript(f'''
        PRAGMA page_size=4096; PRAGMA journal_mode=OFF;
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE entries(id INTEGER PRIMARY KEY, osm TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
            category TEXT, address TEXT, unit TEXT, number TEXT, lat REAL NOT NULL, lon REAL NOT NULL,
            weight INTEGER NOT NULL, walk INTEGER, bike INTEGER, drive INTEGER);
        CREATE INDEX entries_number ON entries(number) WHERE number IS NOT NULL;
        -- Contentless: the text lives in `entries`; the index only answers which rows match.
        CREATE VIRTUAL TABLE fts USING fts5(name, alias, extra, content='',
            tokenize='unicode61 remove_diacritics 2', prefix='1 2 3');
    ''')
    db.executemany('INSERT INTO meta VALUES (?, ?)', sorted(meta.items()))
    for i, x in enumerate(entries, start=1):
        db.execute('INSERT INTO entries VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                   (i, x['osm'], x['kind'], x['name'], x['category'], x['address'], x['unit'], x['number'],
                    x['lat'], x['lon'], x['weight'], x['walk'], x['bike'], x['drive']))
        name = fold(x['name'])
        extra = ' '.join(filter(None, [fold(x['category'] or ''), fold(x['address'] or '')]))
        db.execute('INSERT INTO fts(rowid, name, alias, extra) VALUES (?,?,?,?)',
                   (i, name, aliases(name), extra + (' ' + aliases(fold(x['address'])) if x['address'] else '')))
    db.execute("INSERT INTO fts(fts) VALUES ('optimize')")
    db.commit()
    db.execute('VACUUM')
    db.close()


def build(search_json, graph_places, nodes, segments, inside, graph_sha256, out_path):
    """Writes the gzipped database to out_path and returns a provenance summary."""
    entries = entries_from(search_json['elements'], graph_places, inside)
    snap(entries, nodes, routable_nodes(nodes, segments))
    meta = {'schemaVersion': str(SCHEMA_VERSION), 'graphNodes': str(len(nodes)), 'graphSHA256': graph_sha256,
            'source': 'OpenStreetMap', 'sourceDate': search_json['osm3s']['timestamp_osm_base'][:10]}
    with tempfile.TemporaryDirectory() as tmp:
        db_path = pathlib.Path(tmp) / 'search.sqlite'
        write_database(db_path, entries, meta)
        raw = db_path.read_bytes()
    out_path.write_bytes(gzip.compress(raw, compresslevel=9, mtime=0))
    kinds = collections.Counter(x['kind'] for x in entries)
    return {'places': kinds['place'], 'addresses': kinds['address'], 'inflatedBytes': len(raw),
            'gzippedBytes': out_path.stat().st_size, 'sqlite': sqlite3.sqlite_version,
            'unsnapped': {m: sum(x[m] is None for x in entries) for m in ['walk', 'bike', 'drive']}}
