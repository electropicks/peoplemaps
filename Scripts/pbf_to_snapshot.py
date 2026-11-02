#!/usr/bin/env python3
"""Turn a Geofabrik .osm.pbf extract into the importer's three input snapshots, in the Overpass JSON shape that
import_osm.py and build_search.py read. Pure Python (stdlib only), parallel over PBF blobs. No network.

  Scripts/pbf_to_snapshot.py washington-261031.osm.pbf OUTDIR --bbox S,W,N,E --source-url URL

Writes OUTDIR/seattle-osm.json.gz, seattle-parks.json.gz and seattle-search.json.gz: the same selections as
Data/seattle.overpassql, seattle-parks.overpassql and seattle-search.overpassql, with the nodes (and member ways)
those elements need, even outside the box. The PBF's replication timestamp becomes osm3s.timestamp_osm_base and
its URL and SHA-256 are recorded in osm3s for provenance. Selection is by node-in-box (Overpass also keeps ways
that cross the box without a node inside it) and a relation's centre is the middle of its members' bounding box.
Output is deterministic: sorted elements and tags, gzip mtime 0."""
import argparse, gzip, hashlib, json, multiprocessing, os, pathlib, sys, time, zlib

# ---- protobuf reading -------------------------------------------------------------------------------------

def varint(buf, i):
    b = buf[i]; i += 1
    if b < 128: return b, i
    v = b & 127; s = 7
    while True:
        b = buf[i]; i += 1
        v |= (b & 127) << s
        if b < 128: return v, i
        s += 7

def fields(buf):
    i = 0; n = len(buf)
    while i < n:
        key, i = varint(buf, i); wt = key & 7
        if wt == 0: v, i = varint(buf, i)
        elif wt == 2:
            l, i = varint(buf, i); v = buf[i:i+l]; i += l
        elif wt == 1: v = buf[i:i+8]; i += 8
        elif wt == 5: v = buf[i:i+4]; i += 4
        else: raise ValueError(f'unsupported wire type {wt}')
        yield key >> 3, v

def unpack_uint(buf):
    out = []; i = 0; n = len(buf)
    while i < n:
        b = buf[i]; i += 1
        if b >= 128:
            v = b & 127; s = 7
            while True:
                b = buf[i]; i += 1
                v |= (b & 127) << s
                if b < 128: break
                s += 7
            b = v
        out.append(b)
    return out

def unpack_delta(buf):
    """Packed sint64 values that are deltas of the previous one: returns the running totals."""
    out = []; i = 0; n = len(buf); acc = 0
    while i < n:
        b = buf[i]; i += 1
        if b >= 128:
            v = b & 127; s = 7
            while True:
                b = buf[i]; i += 1
                v |= (b & 127) << s
                if b < 128: break
                s += 7
            b = v
        acc += (b >> 1) ^ -(b & 1)
        out.append(acc)
    return out

def index_blobs(path):
    """[(data offset, data size)] of every OSMData blob, and the OSMHeader fields."""
    blobs = []; header = {}
    with open(path, 'rb') as f:
        pos = 0; size = os.fstat(f.fileno()).st_size
        while pos < size:
            f.seek(pos); hl = int.from_bytes(f.read(4), 'big'); bh = dict(fields(f.read(hl)))
            kind = bh[1].decode(); datasize = bh[3]; start = pos + 4 + hl
            if kind == 'OSMHeader':
                blob = dict(fields(os.pread(f.fileno(), datasize, start)))
                data = zlib.decompress(blob[3]) if 3 in blob else blob[1]
                header = dict(fields(data))
            elif kind == 'OSMData': blobs.append((start, datasize))
            pos = start + datasize
    return blobs, header

_fd = None
def block(job):
    """(strings, granularity, lat_offset, lon_offset, [primitive groups]) of one blob."""
    global _fd
    if _fd is None: _fd = os.open(PATH, os.O_RDONLY)
    off, size = job
    blob = dict(fields(os.pread(_fd, size, off)))
    data = zlib.decompress(blob[3]) if 3 in blob else blob[1]
    strings = []; groups = []; gran = 100; lat_off = lon_off = 0
    for f, v in fields(data):
        if f == 1: strings = [s for _, s in fields(v)]
        elif f == 2: groups.append(v)
        elif f == 17: gran = v
        elif f == 19: lat_off = v
        elif f == 20: lon_off = v
    return strings, gran, lat_off, lon_off, groups

def tags_of(strings, keys, vals):
    return {strings[k].decode(): strings[v].decode() for k, v in zip(keys, vals)}

# ---- selections (mirror Data/*.overpassql) ----------------------------------------------------------------

POI_TOURISM = {'attraction', 'museum', 'viewpoint'}
def is_poi(t): return 'name' in t and (t.get('tourism') in POI_TOURISM or t.get('amenity') in {'library', 'cafe'})
def is_osm_way(t): return 'highway' in t or t.get('leisure') in {'park', 'garden', 'pitch'} or t.get('natural') == 'water'
def is_osm_rel(t): return t.get('type') == 'restriction' or t.get('natural') == 'water'
def is_park_rel(t): return t.get('leisure') == 'park'
SEARCH_KEYS = ('shop', 'amenity', 'leisure', 'tourism', 'historic', 'office', 'craft', 'building')
def is_search(t):
    if 'addr:housenumber' in t: return True
    return 'name' in t and (any(k in t for k in SEARCH_KEYS) or t.get('railway') in {'station', 'halt'}
                            or t.get('natural') in {'peak', 'beach', 'water', 'wood'})
def wanted_rel(t): return is_osm_rel(t) or is_poi(t) or is_park_rel(t) or is_search(t)

# ---- workers (fork-shared globals are set before each pool starts) -----------------------------------------

PATH = None; BOX = None; INBOX = {}; BOXWAYS = {}; WANT_WAYS = set(); WANT_NODES = set()

def scan_nodes(job):
    """Nodes inside BOX (or, when WANT_NODES is set, with those ids): (id, lat, lon, tags or None)."""
    strings, gran, lat_off, lon_off, groups = block(job)
    s, w, n, e = (round(x * 1e9) for x in BOX); out = []
    for g in groups:
        for f, v in fields(g):
            if f != 2: continue
            d = dict(fields(v)); ids = unpack_delta(d[1]); lats = unpack_delta(d[8]); lons = unpack_delta(d[9])
            kv = unpack_uint(d[10]) if 10 in d else []
            j = 0
            for i in range(len(ids)):
                latn = lat_off + gran * lats[i]; lonn = lon_off + gran * lons[i]
                tagged = kv and kv[j] != 0
                keep = (ids[i] in WANT_NODES) if WANT_NODES else (s <= latn <= n and w <= lonn <= e)
                if keep:
                    t = None
                    if tagged:
                        k = j; t = {}
                        while kv[k] != 0: t[strings[kv[k]].decode()] = strings[kv[k+1]].decode(); k += 2
                    out.append((ids[i], round(latn / 1e9, 7), round(lonn / 1e9, 7), t))
                if kv:
                    while kv[j] != 0: j += 2
                    j += 1
    return out

def scan_ways(job):
    """Ways with a node in INBOX (or, when WANT_WAYS is set, with those ids): (id, refs, tags)."""
    strings, gran, lat_off, lon_off, groups = block(job); out = []
    for g in groups:
        for f, v in fields(g):
            if f != 3: continue
            id_ = 0; keys = vals = refs = b''
            for ff, vv in fields(v):
                if ff == 1: id_ = vv
                elif ff == 2: keys = vv
                elif ff == 3: vals = vv
                elif ff == 8: refs = vv
            if WANT_WAYS:
                if id_ not in WANT_WAYS: continue
                r = unpack_delta(refs)
            else:
                r = unpack_delta(refs)
                if not any(x in INBOX for x in r): continue
            out.append((id_, r, tags_of(strings, unpack_uint(keys), unpack_uint(vals))))
    return out

def scan_rels(job):
    strings, gran, lat_off, lon_off, groups = block(job); out = []
    for g in groups:
        for f, v in fields(g):
            if f != 4: continue
            id_ = 0; keys = vals = roles = mems = types = b''
            for ff, vv in fields(v):
                if ff == 1: id_ = vv
                elif ff == 2: keys = vv
                elif ff == 3: vals = vv
                elif ff == 8: roles = vv
                elif ff == 9: mems = vv
                elif ff == 10: types = vv
            t = tags_of(strings, unpack_uint(keys), unpack_uint(vals))
            if not wanted_rel(t): continue
            kinds = ('node', 'way', 'relation')
            members = [{'type': kinds[ty], 'ref': m, 'role': strings[r].decode()}
                       for ty, m, r in zip(unpack_uint(types), unpack_delta(mems), unpack_uint(roles))]
            if any((m['type'] == 'way' and m['ref'] in BOXWAYS) or (m['type'] == 'node' and m['ref'] in INBOX) for m in members):
                out.append((id_, members, t))
    return out

def run(fn, blobs, procs):
    ctx = multiprocessing.get_context('fork'); result = []
    with ctx.Pool(procs) as pool:
        for part in pool.imap_unordered(fn, blobs, chunksize=4): result.extend(part)
    return result

# ---- assembly ----------------------------------------------------------------------------------------------

def center(points):
    lats = [p[0] for p in points]; lons = [p[1] for p in points]
    return {'lat': round((min(lats) + max(lats)) / 2, 7), 'lon': round((min(lons) + max(lons)) / 2, 7)}

def main():
    global PATH, BOX, INBOX, BOXWAYS, WANT_WAYS, WANT_NODES
    ap = argparse.ArgumentParser()
    ap.add_argument('pbf'); ap.add_argument('outdir')
    ap.add_argument('--bbox', required=True, help='S,W,N,E')
    ap.add_argument('--source-url', required=True)
    ap.add_argument('--coast-bbox', help='S,W,N,E: also write seattle-coast.json.gz, the natural=coastline ways touching this box (Data/seattle-coast.overpassql)')
    ap.add_argument('--procs', type=int, default=max(1, (os.cpu_count() or 2) - 2))
    a = ap.parse_args()
    PATH = a.pbf; BOX = [float(x) for x in a.bbox.split(',')]; outdir = pathlib.Path(a.outdir); outdir.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    def log(m): print(f'[{time.time()-t0:6.0f}s] {m}', file=sys.stderr, flush=True)
    sha = hashlib.sha256()
    with open(PATH, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 22), b''): sha.update(chunk)
    blobs, header = index_blobs(PATH)
    stamp = header.get(32)
    if stamp is None: sys.exit('the PBF header has no replication timestamp')
    base = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(stamp))
    log(f'{len(blobs)} blobs, extract dated {base}')

    INBOX = {i: (la, lo, t) for i, la, lo, t in run(scan_nodes, blobs, a.procs)}; log(f'{len(INBOX)} nodes in the box')
    BOXWAYS = {i: (r, t) for i, r, t in run(scan_ways, blobs, a.procs)}; log(f'{len(BOXWAYS)} ways touching the box')
    rels = {i: (m, t) for i, m, t in run(scan_rels, blobs, a.procs)}; log(f'{len(rels)} relations selected')

    osm_ways = {i for i, (r, t) in BOXWAYS.items() if is_osm_way(t) or is_poi(t)}
    osm_rels = {i for i, (m, t) in rels.items() if is_osm_rel(t) or is_poi(t)}
    park_rels = {i for i, (m, t) in rels.items() if is_park_rel(t)}
    search_rels = {i for i, (m, t) in rels.items() if is_search(t)}
    def member_ways(ids): return {m['ref'] for i in ids for m in rels[i][0] if m['type'] == 'way'}
    def member_nodes(ids): return {m['ref'] for i in ids for m in rels[i][0] if m['type'] == 'node'}
    need_ways = (member_ways(osm_rels | park_rels | search_rels)) - set(BOXWAYS)
    WANT_WAYS = need_ways; WANT_NODES = set()
    allways = dict(BOXWAYS)
    if need_ways: allways.update({i: (r, t) for i, r, t in run(scan_ways, blobs, a.procs)})
    WANT_WAYS = set(); log(f'{len(need_ways)} member ways outside the box fetched')

    osm_ways |= member_ways(osm_rels)
    park_ways = member_ways(park_rels)
    search_ways = {i for i, (r, t) in BOXWAYS.items() if is_search(t)}
    osm_nodes = {n for i in osm_ways for n in allways[i][0] if i in allways} | member_nodes(osm_rels)
    park_nodes = {n for i in park_ways if i in allways for n in allways[i][0]} | member_nodes(park_rels)
    centre_ways = search_ways | member_ways(search_rels)
    centre_nodes = {n for i in centre_ways if i in allways for n in allways[i][0]} | member_nodes(search_rels)
    nodes = dict(INBOX)
    need = (osm_nodes | park_nodes | centre_nodes) - set(nodes)
    if need:
        WANT_NODES = need
        nodes.update({i: (la, lo, t) for i, la, lo, t in run(scan_nodes, blobs, a.procs)})
        WANT_NODES = set()
    log(f'{len(need)} nodes outside the box fetched')
    # Nodes that are POIs themselves (named, in the box) belong to the osm and search selections.
    poi_nodes = {i for i, (la, lo, t) in INBOX.items() if t and is_poi(t)}
    search_nodes = {i for i, (la, lo, t) in INBOX.items() if t and is_search(t)}

    def node_el(i):
        la, lo, t = nodes[i]; e = {'type': 'node', 'id': i, 'lat': la, 'lon': lo}
        if t: e['tags'] = dict(sorted(t.items()))
        return e
    def way_el(i):
        r, t = allways[i]; e = {'type': 'way', 'id': i, 'nodes': [n for n in r]}
        if t: e['tags'] = dict(sorted(t.items()))
        return e
    def rel_el(i):
        m, t = rels[i]; e = {'type': 'relation', 'id': i, 'members': [x for x in m if x['type'] != 'relation']}
        if t: e['tags'] = dict(sorted(t.items()))
        return e
    def meta(): return {'version': 0.6, 'generator': 'Scripts/pbf_to_snapshot.py', 'osm3s': {
        'timestamp_osm_base': base, 'copyright': 'The data included in this document is from www.openstreetmap.org. The data is made available under ODbL.',
        'source_url': a.source_url, 'source_file': pathlib.Path(PATH).name, 'source_sha256': sha.hexdigest(), 'bbox': BOX}}
    def write(name, elements):
        doc = meta(); doc['elements'] = elements
        data = json.dumps(doc, separators=(',', ':')).encode()
        (outdir / name).write_bytes(gzip.compress(data, mtime=0)); log(f'{name}: {len(elements)} elements, {len(data)/1e6:.1f} MB json')

    write('seattle-osm.json.gz',
          [node_el(i) for i in sorted(osm_nodes | poi_nodes) if i in nodes] + [way_el(i) for i in sorted(osm_ways) if i in allways] + [rel_el(i) for i in sorted(osm_rels)])
    write('seattle-parks.json.gz',
          [node_el(i) for i in sorted(park_nodes) if i in nodes] + [way_el(i) for i in sorted(park_ways) if i in allways] + [rel_el(i) for i in sorted(park_rels)])
    def centred(el, pts):
        if not pts: return None
        el['center'] = center(pts); return el
    search = []
    for i in sorted(search_nodes):
        el = node_el(i); search.append(el)
    for i in sorted(search_ways):
        r, t = allways[i]; el = centred({'type': 'way', 'id': i, 'tags': dict(sorted(t.items()))}, [nodes[n][:2] for n in r if n in nodes])
        if el: search.append(el)
    for i in sorted(search_rels):
        m, t = rels[i]; pts = [nodes[x['ref']][:2] for x in m if x['type'] == 'node' and x['ref'] in nodes]
        for x in m:
            if x['type'] == 'way' and x['ref'] in allways: pts += [nodes[n][:2] for n in allways[x['ref']][0] if n in nodes]
        el = centred({'type': 'relation', 'id': i, 'tags': dict(sorted(t.items()))}, pts)
        if el: search.append(el)
    write('seattle-search.json.gz', search)

    if a.coast_bbox:
        BOX = [float(x) for x in a.coast_bbox.split(',')]; WANT_NODES = set(); WANT_WAYS = set()
        INBOX = {i: (la, lo, t) for i, la, lo, t in run(scan_nodes, blobs, a.procs)}
        coast = {i: (r, t) for i, r, t in run(scan_ways, blobs, a.procs) if t.get('natural') == 'coastline'}
        need = {n for r, t in coast.values() for n in r} - set(INBOX); nodes = dict(INBOX)
        if need:
            WANT_NODES = need; nodes.update({i: (la, lo, t) for i, la, lo, t in run(scan_nodes, blobs, a.procs)}); WANT_NODES = set()
        allways = coast
        keep = {n for r, t in coast.values() for n in r if n in nodes}
        doc_nodes = sorted(keep)
        write('seattle-coast.json.gz', [node_el(i) for i in doc_nodes] + [way_el(i) for i in sorted(coast)])

if __name__ == '__main__':
    main()
