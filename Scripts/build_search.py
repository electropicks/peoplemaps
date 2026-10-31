#!/usr/bin/env python3
"""Offline search index (SQLite + FTS5) of named places and street addresses: OSM, plus Overture Maps businesses.

Called by import_osm.py once the routing graph is built, so every entry can carry the graph node
it routes from or to. Deterministic for a given input and SQLite version; no network."""
import collections, gzip, hashlib, json, math, os, pathlib, re, sqlite3, struct, tempfile, zlib, unicodedata

SCHEMA_VERSION = 1
DEDUPE_METERS = 50
AREA_DEDUPE_METERS = 250  # same-named parks and civic places (weight 70 and up) from Overture and OSM
AREA_WEIGHT = 70
OVERTURE_PENALTY = 5  # an Overture place ranks just below an OSM place of the same category
SNAP_METERS = 400  # the router's own snap radius
NOTABLE = 5  # weight bonus: ranks well-known places above others of their kind, never above a better category

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

# Overture Maps Places (archived by fetch_overture.py). Only the sources Overture attributes, each under the licence
# it is published under; a record that names any other source, or no licence, is left out.
OVERTURE_SOURCES = {  # root dataset -> (name shown, licence)
    'meta': ('Meta', 'CDLA-Permissive-2.0'), 'Microsoft': ('Microsoft', 'CDLA-Permissive-2.0'),
    'BrightQuery': ('BrightQuery', 'CDLA-Permissive-2.0'), 'PinMeTo': ('PinMeTo', 'CDLA-Permissive-2.0'),
    'Uberall': ('Uberall', 'CDLA-Permissive-2.0'), 'DAC': ('DAC', 'CDLA-Permissive-2.0'),
    'Krick': ('Krick', 'CDLA-Permissive-2.0'), 'RenderSEO': ('RenderSEO', 'CDLA-Permissive-2.0'),
    'Birdeye': ('Birdeye', 'CDLA-Permissive-2.0'), 'OpenTravel': ('OpenTravel', 'CDLA-Permissive-2.0'),
    'Foursquare': ('Foursquare', 'Apache-2.0'), 'AllThePlaces': ('AllThePlaces', 'CC0-1.0'),
}
OVERTURE_OWN = {'Overture', 'Overture-signals'}  # properties Overture derives itself (CDLA-Permissive-2.0)
OVERTURE_LICENSES = {'CDLA-Permissive-2.0', 'Apache-2.0', 'CC0-1.0'}
# Scores run 0 to 1. The archive shows a long tail below 0.6 (mostly Meta records with no operating status) and a
# BrightQuery spike at exactly 0.55 (one-person registrations); every source clusters at 0.8 to 1.0 above that.
MIN_CONFIDENCE = 0.6
# OSM categories too vague to keep when Overture knows what the place is.
GENERIC = {'building', 'office', 'craft'}
# Overture taxonomy -> (weight, category or None to keep Overture's own, taxonomy names). Looked up by the record's
# primary taxonomy, then up its hierarchy. Weights follow category_of: landmarks 100, nature 90, civic 70, shops 50.
OVERTURE_GROUPS = [
    (100, 'museum', ['museum', 'history_museum', 'art_museum', 'science_museum', 'childrens_museum']),
    (100, 'zoo', ['zoo']), (100, 'aquarium', ['aquarium']), (100, 'viewpoint', ['lookout']),
    (100, 'attraction', ['amusement_park', 'planetarium', 'lighthouse', 'observation_deck', 'theme_park']),
    (100, 'monument', ['monument', 'sculpture_statue', 'memorial']),
    (90, 'park', ['park', 'national_park', 'state_park', 'city_park']), (90, 'dog_park', ['dog_park']),
    (90, 'playground', ['playground']), (90, 'beach', ['beach']), (90, 'nature_reserve', ['nature_reserve']),
    (90, 'garden', ['botanical_garden', 'garden', 'community_garden']), (90, 'water', ['lake']),
    (70, 'hospital', ['hospital']), (70, 'library', ['library']), (70, 'marina', ['marina']),
    (70, 'university', ['college_university']),
    (70, 'school', ['elementary_school', 'middle_school', 'high_school', 'school', 'private_school', 'public_school',
                    'preschool', 'montessori_school']),
    (70, 'place_of_worship', [n for n in ['christian_place_of_worship', 'religious_organization', 'baptist_place_of_worship',
        'roman_catholic_place_of_worship', 'buddhist_place_of_worship', 'jewish_place_of_worship', 'muslim_place_of_worship',
        'anglican_or_episcopal_place_of_worship', 'pentecostal_place_of_worship', 'protestant_place_of_worship',
        'lutheran_place_of_worship', 'jehovahs_witness_place_of_worship', 'eastern_orthodox_place_of_worship',
        'methodist_place_of_worship', 'hindu_place_of_worship', 'sikh_place_of_worship', 'place_of_worship']]),
    (70, 'community_centre', ['community_center']), (70, 'townhall', ['town_hall', 'courthouse']),
    (70, 'police', ['police_station']), (70, 'fire_station', ['fire_station']), (70, 'post_office', ['post_office']),
    (70, 'station', ['train_station', 'light_rail_and_subway_station', 'bus_station']),
    (70, 'airport', ['airport', 'airport_terminal']), (70, 'ferry_terminal', ['ferry_service']),
    (70, 'theatre', ['theatre_venue', 'performing_arts_venue']), (70, 'cinema', ['movie_theater']),
    (70, 'stadium', ['stadium_arena']), (70, 'events_venue', ['event_venue', 'music_venue']),
    (70, 'swimming_pool', ['swimming_pool']), (70, 'arts_centre', ['cultural_center']),
    (50, 'cafe', ['coffee_shop', 'cafe']), (50, 'pub', ['pub', 'gastropub']),
    (50, 'bar', ['bar', 'cocktail_bar', 'wine_bar', 'sports_bar', 'dive_bar', 'beer_bar', 'lounge']),
    (50, 'fast_food', ['fast_food_restaurant']), (50, 'bakery', ['bakery']), (50, 'gallery', ['art_gallery']),
    (50, 'supermarket', ['grocery_store']), (50, 'convenience', ['convenience_store']),
    (50, 'pharmacy', ['pharmacy']), (50, 'fuel', ['gas_station']), (50, 'hotel', ['hotel', 'lodging']),
    (50, 'bank', ['bank', 'bank_or_credit_union']), (50, 'historic', ['historic_site']),
    (50, 'hairdresser', ['hair_salon', 'barber']), (50, 'fitness_centre', ['gym']),
    (50, 'dentist', ['dental_clinic', 'general_dentistry']), (50, 'doctors', ['doctors_office']),
    (50, 'veterinary', ['veterinarian', 'animal_hospital']),
    (40, 'atm', ['atm']), (40, 'storage', ['self_storage_facility']), (40, 'retirement_home', ['retirement_home']),
    (30, 'parking', ['parking', 'parking_lot', 'parking_garage']), (30, 'apartment', ['apartment']),
]
OVERTURE_TAXONOMY = {name: (weight, category) for weight, category, names in OVERTURE_GROUPS for name in names}
# Default weight for a top-level Overture group when nothing above matches; the category stays Overture's own
# ("thai_restaurant"). Business services and delivery-only or utility listings are not places people go to.
OVERTURE_ROOT = {
    'food_and_drink': 50, 'shopping': 50, 'lodging': 50, 'arts_and_entertainment': 50, 'sports_and_recreation': 50,
    'education': 50, 'cultural_and_historic': 50, 'geographic_entities': 50, 'lifestyle_services': 45,
    'health_care': 40, 'community_and_government': 40, 'travel_and_transportation': 40,
}
OVERTURE_DROP = {'food_delivery_service', 'pizza_delivery_service', 'garbage_collection_service', 'electric_utility_provider',
                 'water_utility_provider', 'public_utility', 'labor_union', 'political_organization', 'political_party_office',
                 'psychic_advising', 'spiritual_advising', 'astrological_advising', 'jail_or_prison', 'military_base',
                 'public_restroom', 'towing_service', 'hiking_trail', 'mountain_bike_trail', 'river', 'canyon', 'island'}
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


def overture_category(taxonomy):
    """(category, weight) for an Overture record's taxonomy, or None when it isn't something people search for."""
    primary, hierarchy = (taxonomy or {}).get('primary'), (taxonomy or {}).get('hierarchy') or []
    if not primary or primary in OVERTURE_DROP:
        return None
    for name in [primary] + hierarchy[::-1]:
        if name in OVERTURE_TAXONOMY:
            weight, category = OVERTURE_TAXONOMY[name]
            return (category or primary, weight)
    weight = OVERTURE_ROOT.get(hierarchy[0] if hierarchy else None)
    return (primary, weight) if weight else None


def overture_source(record):
    """The root dataset's display name, or None when the record isn't one we may use: its root dataset must be an
    attributed one, under the licence it is published under, and every other source must be one of those or Overture's own."""
    sources = record.get('sources') or []
    root = OVERTURE_SOURCES.get(sources[0].get('dataset')) if sources else None
    if not root or sources[0].get('license') != root[1]:
        return None
    for s in sources[1:]:
        known = OVERTURE_SOURCES.get(s.get('dataset'))
        if not (known and s.get('license') == known[1]) and not (s.get('dataset') in OVERTURE_OWN and s.get('license') in OVERTURE_LICENSES):
            return None
    return root[0]


def overture_candidates(records, inside, stats=None):
    """Searchable entries from the archived Overture records, in the importer's box. `stats` counts what each filter drops."""
    stats = collections.Counter() if stats is None else stats
    found = []
    for r in records:
        stats['archive'] += 1
        if not inside({'lat': r['lat'], 'lon': r['lon']}):
            continue
        stats['inBox'] += 1
        source, name = overture_source(r), (r.get('name') or '').strip()
        if not source or not name or not fold(name):
            continue
        stats['allowedSource'] += 1
        if r.get('operating_status') == 'permanently_closed':
            continue
        stats['notClosed'] += 1
        if (r.get('confidence') or 0) < MIN_CONFIDENCE:
            continue
        stats['confident'] += 1
        category = overture_category(r.get('taxonomy'))
        if not category:
            continue
        stats['categorised'] += 1
        # Addresses come from OSM only; the app shows the nearest OSM address for a business instead.
        found.append({'osm': f"overture/{r['id']}", 'kind': 'place', 'name': name, 'category': category[0],
                      'lat': round(r['lat'], 7), 'lon': round(r['lon'], 7), 'weight': category[1], 'address': None,
                      'unit': None, 'number': None, 'source': f'Overture · {source}', 'confidence': r['confidence']})
    found.sort(key=lambda x: (-x['weight'], -x['confidence'], x['osm']))
    return found


def address_of(tags):
    """'1100 Northeast 45th Street' and the unit, or (None, None) without a house number and street."""
    number, street = tags.get('addr:housenumber', '').strip(), tags.get('addr:street', '').strip()
    if not number or not street or ';' in number:
        return None, None
    return f'{number} {street}', tags.get('addr:unit', '').strip() or None


def meters(a, b):
    x = math.radians(b[1]-a[1]) * math.cos(math.radians((a[0]+b[0])/2))
    return math.hypot(x, math.radians(b[0]-a[0])) * 6371000


def entries_from(elements, graph_places, inside, overture=(), stats=None):
    """Graph places first (their IDs are what the app features and tests use), then the search extract, then
    Overture places. Named places dedupe on the same OSM ID or the same folded name within 50 m; addresses on the
    same number, street and unit within 50 m. The first one kept wins, so OSM keeps its name and position; an
    Overture duplicate only fills in the category of an OSM place that has none worth showing (a bare building or office)."""
    stats = collections.Counter() if stats is None else stats
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
            # A Wikidata or Wikipedia link marks a place people know by name: a small, open signal, never paid.
            notable = NOTABLE if 'wikidata' in tags or 'wikipedia' in tags else 0
            candidates.append({'osm': f"{e['type']}/{e['id']}", 'kind': 'place', 'name': name, 'category': category[0],
                               'lat': round(c[0], 7), 'lon': round(c[1], 7), 'weight': category[1] + notable,
                               'address': address, 'unit': unit, 'number': tags.get('addr:housenumber') if address else None})
        if address:
            candidates.append({'osm': f"{e['type']}/{e['id']}", 'kind': 'address', 'name': address + (f', Unit {unit}' if unit else ''),
                               'category': None, 'lat': round(c[0], 7), 'lon': round(c[1], 7), 'weight': 10,
                               'address': None, 'unit': unit, 'number': tags['addr:housenumber']})
    candidates.sort(key=lambda x: (-x['weight'], x['kind'], x['osm'].split('/')[0], int(x['osm'].split('/')[1])))
    kept, seen_ids, cell = [], set(), 0.001
    grid = collections.defaultdict(list)
    # Names compare without spaces too ("Coffeemind" is "Coffee Mind").
    def key(x): return ''.join(fold(x['name']).split()) if x['kind'] == 'place' else (fold(x['name']), 'address')
    for x in entries + candidates + list(overture):
        if (x['osm'], x['kind']) in seen_ids:
            continue
        k, gx, gy = key(x), int(x['lon']/cell), int(x['lat']/cell)
        # Overture puts a park or campus at a point that can be far from OSM's centre of the same area.
        big = x['osm'].startswith('overture/') and x['weight'] >= AREA_WEIGHT
        reach = range(-3, 4) if big else range(-1, 2)
        near = (y for dx in reach for dy in reach for y in grid[(gx+dx, gy+dy)])
        match = next((y for y in near if key(y) == k and meters((x['lat'], x['lon']), (y['lat'], y['lon']))
                      <= (AREA_DEDUPE_METERS if big and y['weight'] >= AREA_WEIGHT else DEDUPE_METERS)), None)
        if match:
            if x['osm'].startswith('overture/'):
                if match['osm'].startswith('overture/'):
                    stats['duplicateOfOverture'] += 1
                else:
                    stats['duplicateOfOSM'] += 1
                    if match['category'] in GENERIC:
                        match['category'], match['weight'] = x['category'], max(match['weight'], x['weight'])
                        stats['categoryFilled'] += 1
            continue
        seen_ids.add((x['osm'], x['kind'])); grid[(gx, gy)].append(x); kept.append(x)
    for x in kept:
        if x['osm'].startswith('overture/'):
            x['weight'] -= OVERTURE_PENALTY
    # Graph places come from the older routing extract: fill in their address from the search extract.
    by_id = {x['osm']: x for x in candidates if x['kind'] == 'place'}
    for x in kept[:len(graph_places)]:
        newer = by_id.get(x['osm'])
        if newer and newer['address']:
            x['address'], x['unit'], x['number'] = newer['address'], newer['unit'], newer['number']
        if newer:
            x['weight'] = max(x['weight'], newer['weight'])
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
            weight INTEGER NOT NULL, walk INTEGER, bike INTEGER, drive INTEGER, source TEXT);
        CREATE INDEX entries_number ON entries(number) WHERE number IS NOT NULL;
        -- Contentless: the text lives in `entries`; the index only answers which rows match.
        CREATE VIRTUAL TABLE fts USING fts5(name, alias, extra, content='',
            tokenize='unicode61 remove_diacritics 2', prefix='1 2 3');
    ''')
    db.executemany('INSERT INTO meta VALUES (?, ?)', sorted(meta.items()))
    for i, x in enumerate(entries, start=1):
        db.execute('INSERT INTO entries VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                   (i, x['osm'], x['kind'], x['name'], x['category'], x['address'], x['unit'], x['number'],
                    x['lat'], x['lon'], x['weight'], x['walk'], x['bike'], x['drive'], x.get('source', 'OpenStreetMap')))
        name = fold(x['name'])
        extra = ' '.join(filter(None, [fold(x['category'] or ''), fold(x['address'] or '')]))
        db.execute('INSERT INTO fts(rowid, name, alias, extra) VALUES (?,?,?,?)',
                   (i, name, aliases(name), extra + (' ' + aliases(fold(x['address'])) if x['address'] else '')))
    db.execute("INSERT INTO fts(fts) VALUES ('optimize')")
    db.commit()
    db.execute('VACUUM')
    db.close()


def gzip_bytes(raw):
    """A gzip file with a fixed header (no name, mtime 0, unknown OS), so the bytes depend only on zlib.
    gzip.compress writes its header differently between Python versions, which broke byte-for-byte reproduction."""
    deflate = zlib.compressobj(9, zlib.DEFLATED, -zlib.MAX_WBITS)
    body = deflate.compress(raw) + deflate.flush()
    return b'\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff' + body + struct.pack('<II', zlib.crc32(raw), len(raw) & 0xffffffff)


def read_overture(path):
    """(header, records) of the archive from fetch_overture.py."""
    archive = json.loads(gzip.decompress(path.read_bytes()))
    return {k: v for k, v in archive.items() if k != 'places'}, archive['places']


def build(search_json, graph_places, nodes, segments, inside, graph_sha256, out_path, overture_path=None):
    """Writes the gzipped database to out_path and returns a provenance summary. Overture places are added when
    the archive at overture_path exists."""
    overture, stats, header = [], collections.Counter(), None
    if overture_path and overture_path.exists():
        header, records = read_overture(overture_path)
        overture = overture_candidates(records, inside, stats)
    entries = entries_from(search_json['elements'], graph_places, inside, overture, stats)
    snap(entries, nodes, routable_nodes(nodes, segments))
    meta = {'schemaVersion': str(SCHEMA_VERSION), 'graphNodes': str(len(nodes)), 'graphSHA256': graph_sha256,
            'source': 'OpenStreetMap', 'sourceDate': search_json['osm3s']['timestamp_osm_base'][:10]}
    if header:  # the release is a date, not the age of each record
        meta.update({'overtureRelease': header['release'], 'overtureDate': header['release'].split('.')[0]})
    with tempfile.TemporaryDirectory() as tmp:
        db_path = pathlib.Path(tmp) / 'search.sqlite'
        write_database(db_path, entries, meta)
        raw = db_path.read_bytes()
    out_path.write_bytes(gzip_bytes(raw))
    kinds = collections.Counter(x['kind'] for x in entries)
    summary = {'places': kinds['place'], 'addresses': kinds['address'], 'inflatedBytes': len(raw),
               'gzippedBytes': out_path.stat().st_size, 'sqlite': sqlite3.sqlite_version,
               'unsnapped': {m: sum(x[m] is None for x in entries) for m in ['walk', 'bike', 'drive']}}
    if header:
        shipped = [x for x in entries if x['osm'].startswith('overture/')]
        summary['overture'] = {
            'release': header['release'], 'fetched': header['fetched'], 'bbox': header['bbox'], 'source': header['source'],
            'archive': {'file': 'Data/seattle-overture-places.json.gz', 'sha256': hashlib.sha256(overture_path.read_bytes()).hexdigest(),
                        'records': header['count']},
            'minConfidence': MIN_CONFIDENCE, 'stages': dict(stats), 'shipped': len(shipped),
            'shippedBySource': dict(sorted(collections.Counter(x['source'] for x in shipped).items()))}
    return summary
