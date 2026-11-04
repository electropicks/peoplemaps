import array, collections, gzip, json, pathlib, sqlite3, struct, tempfile, unittest
import build_search, build_tiles
from import_osm import access,directions,facility,clip_ring,sidewalk,crossing_control,control,parked_both_sides,approach_grade,climb,node_blocks,load_dem,compile_restrictions,ring_rows,in_rows,freeway_ref,estimated_mph,road_class

class ImportPolicyTests(unittest.TestCase):
    def test_private_road_excluded(self):
        self.assertFalse(access({'highway':'residential','access':'private'},'drive'))
    def test_modal_override(self):
        self.assertTrue(access({'highway':'path','access':'no','bicycle':'designated'},'bike'))
    def test_footpath_without_bike_permission_excluded(self):
        self.assertFalse(access({'highway':'footway'},'bike'))
    def test_hov_only_way_is_not_drivable_solo(self):
        self.assertFalse(access({'highway':'motorway','hov':'designated'},'drive'))
        self.assertTrue(access({'highway':'motorway','hov':'lane'},'drive'))  # one lane of several: still the road
        self.assertTrue(access({'highway':'motorway','hov:lanes':'|designated'},'drive'))
        self.assertTrue(access({'highway':'cycleway','hov':'designated'},'bike'))  # only drivers are affected
    def test_cycleway_is_not_drivable(self):
        self.assertFalse(access({'highway':'cycleway'},'drive'))
    def test_conditional_access_excluded(self):
        self.assertFalse(access({'highway':'residential','access:conditional':'no @ (Mo-Fr)'},'drive'))
    def test_oneway_reverse(self):
        self.assertEqual(directions({'oneway':'-1'},'drive'),[-1])
    def test_bike_contraflow(self):
        self.assertEqual(directions({'oneway':'yes','oneway:bicycle':'no'},'bike'),[1,-1])
    def test_motorway_defaults_oneway(self):
        self.assertEqual(directions({'highway':'motorway'},'drive'),[1])
    def test_unknown_oneway_excluded(self):
        self.assertEqual(directions({'oneway':'reversible'},'drive'),[])
    def test_directional_facility(self):
        self.assertEqual(facility({'cycleway:right':'track'},1),'track')
        self.assertEqual(facility({'cycleway:right':'track'},-1),'none')
    def test_shared_path_not_separation_claim(self):
        self.assertEqual(facility({'highway':'path','bicycle':'yes'},1),'sharedPath')
    def test_polygon_clipped_to_area(self):
        p=clip_ring([[-123,47],[-122,47],[-122,48],[-123,48],[-123,47]])
        self.assertTrue(all(-122.39<=x<=-122.30 and 47.615<=y<=47.678 for x,y in p))
    def test_walking_network(self):
        self.assertTrue(access({'highway':'footway','footway':'sidewalk'},'walk'))
        self.assertTrue(access({'highway':'steps'},'walk'))
        self.assertFalse(access({'highway':'motorway'},'walk'))
        self.assertFalse(access({'highway':'primary','foot':'use_sidepath'},'walk'))
        self.assertFalse(access({'highway':'cycleway'},'walk'))
        self.assertTrue(access({'highway':'cycleway','foot':'designated'},'walk'))
        self.assertEqual(directions({'oneway':'yes'},'walk'),[1,-1])
        self.assertFalse(access({'highway':'residential','sidewalk:both':'separate'},'walk'))
        self.assertTrue(access({'highway':'residential','sidewalk:both':'separate'},'bike'))
    def test_sidewalk_status(self):
        self.assertEqual(sidewalk({'sidewalk:both':'separate'}),'separate')
        self.assertEqual(sidewalk({'sidewalk:left':'no','sidewalk:right':'separate'}),'separate')
        self.assertEqual(sidewalk({'sidewalk':'both'}),'yes')
        self.assertEqual(sidewalk({'sidewalk':'no'}),'no')
        self.assertIsNone(sidewalk({}))  # unknown stays unknown
    def test_crossing_control(self):
        self.assertEqual(crossing_control({'crossing':'traffic_signals'}),'signal')
        self.assertEqual(crossing_control({'crossing:markings':'zebra:paired'}),'marked')
        self.assertEqual(crossing_control({'crossing':'unmarked'}),'unmarked')
        self.assertIsNone(crossing_control({}))
    def test_traffic_control_direction_and_dark_signals(self):
        self.assertEqual(control({'highway':'stop','direction':'forward'},1),'stop')
        self.assertIsNone(control({'highway':'stop','direction':'forward'},-1))
        self.assertEqual(control({'highway':'stop','stop':'all'},-1),'allstop')
        self.assertIsNone(control({'highway':'traffic_signals','traffic_signals':'emergency'},1))
        self.assertEqual(control({'highway':'traffic_signals'},1),'signal')
    def test_parking_unknown_is_not_false(self):
        self.assertTrue(parked_both_sides({'parking:both':'lane'}))
        self.assertFalse(parked_both_sides({'parking:both':'no'}))
        self.assertIsNone(parked_both_sides({}))
    def test_grades(self):
        self.assertEqual(approach_grade([(0,10),(30,13)]),10.0)
        self.assertIsNone(approach_grade([(0,10),(30,40)]))  # 100% on a road is a DEM artifact
        self.assertAlmostEqual(climb([(0,0),(10,1),(20,0),(30,9)]),1+3)  # last step clipped to 30%
    def test_walkers_pass_bollards_drivers_do_not(self):
        self.assertFalse(node_blocks({'barrier':'bollard'},'walk'))
        self.assertTrue(node_blocks({'barrier':'bollard'},'drive'))

def coast_ways(*lines):
    """OSM-style coastline ways (ids from 1) and nodes from point lists; a list that ends where it starts is a closed way."""
    nodes = {}; ways = []; nid = 1
    for i, pts in enumerate(lines):
        ids = []
        for p in pts:
            nodes[nid] = {'lon': p[0], 'lat': p[1]}; ids.append(nid); nid += 1
        if pts[0] == pts[-1]: ids[-1] = ids[0]
        ways.append({'id': i + 1, 'nodes': ids})
    return ways, nodes

def ring_area(ring):
    return abs(sum(a[0]*b[1] - b[0]*a[1] for a, b in zip(ring, ring[1:])) / 2)

class CoastlineTests(unittest.TestCase):
    BOX = (0.0, 0.0, 10.0, 10.0)  # S,W,N,E
    def water(self, *lines):
        return build_tiles.coast_water(*coast_ways(*lines), self.BOX)
    def test_east_going_coast_puts_water_south(self):
        out = self.water([(-1, 5), (11, 5)])
        self.assertEqual(len(out), 1); self.assertAlmostEqual(ring_area(out[0][0]), 50)
        self.assertTrue(all(y <= 5 for x, y in out[0][0]))
    def test_west_going_coast_puts_water_north(self):
        out = self.water([(11, 5), (-1, 5)])
        self.assertAlmostEqual(ring_area(out[0][0]), 50); self.assertTrue(all(y >= 5 for x, y in out[0][0]))
    def test_coast_split_in_two_ways_joins(self):
        ways = [{'id': 1, 'nodes': [1, 2]}, {'id': 2, 'nodes': [2, 3]}]
        nodes = {1: {'lon': -1, 'lat': 5}, 2: {'lon': 5, 'lat': 5}, 3: {'lon': 11, 'lat': 5}}
        self.assertAlmostEqual(ring_area(build_tiles.coast_water(ways, nodes, self.BOX)[0][0]), 50)
    def test_channel(self):
        out = self.water([(3, -1), (3, 11)], [(7, 11), (7, -1)])
        self.assertEqual(len(out), 1); self.assertAlmostEqual(ring_area(out[0][0]), 40)
    def test_two_shores_make_two_waters(self):
        out = self.water([(7, -1), (7, 11)], [(3, 11), (3, -1)])
        self.assertEqual([round(ring_area(p[0])) for p in out], [30, 30])
    def test_island_is_a_hole(self):
        out = self.water([(-1, 5), (11, 5)], [(2, 2), (4, 2), (4, 4), (2, 4), (2, 2)])
        self.assertEqual([len(p) for p in out], [2]); self.assertAlmostEqual(ring_area(out[0][1]), 4)
    def test_island_alone_floods_the_box(self):
        out = self.water([(2, 2), (4, 2), (4, 4), (2, 4), (2, 2)])
        self.assertEqual(len(out), 1); self.assertEqual(len(out[0]), 2); self.assertAlmostEqual(ring_area(out[0][0]), 100)
    def test_island_crossing_the_edge(self):
        out = self.water([(-2, 2), (2, 2), (2, 8), (-2, 8), (-2, 2)])
        self.assertAlmostEqual(ring_area(out[0][0]), 88)
    def test_corner_to_corner(self):
        self.assertAlmostEqual(ring_area(self.water([(-1, -1), (11, 11)])[0][0]), 50)
    def test_coast_ending_inside_the_box_fails_the_import(self):
        with self.assertRaises(ValueError): self.water([(-1, 5), (5, 5)])
    def test_no_coast_no_water(self):
        self.assertEqual(self.water([(20, 20), (21, 21)]), [])

# A small reader for the archive, independent of the writer's helpers.
def varint(b, p):
    n = s = 0
    while True:
        c = b[p]; p += 1; n |= (c & 0x7F) << s; s += 7
        if c < 0x80: return n, p

def read_directory(b):
    n, p = varint(b, 0); ids = []; last = 0
    for _ in range(n):
        d, p = varint(b, p); last += d; ids.append(last)
    cols = []
    for _ in range(3):
        col = []
        for _ in range(n):
            v, p = varint(b, p); col.append(v)
        cols.append(col)
    runs, lens, raw = cols; offs = []
    for i in range(n): offs.append(offs[-1] + lens[i - 1] if raw[i] == 0 else raw[i] - 1)
    return list(zip(ids, runs, lens, offs))

def read_archive(b):
    """Header fields and {tile id: tile bytes} read back through the root and leaf directories."""
    ro, rl, mo, ml, lo, ll, do, dl, addressed, entries, contents = struct.unpack('<11Q', b[8:96])
    ic, tc, tt, minz, maxz = b[97], b[98], b[99], b[100], b[101]
    head = dict(root=(ro, rl), meta=json.loads(b[mo:mo + ml]), leaf=(lo, ll), addressed=addressed, entries=entries, contents=contents,
                comp=(ic, tc), type=tt, zooms=(minz, maxz), bounds=[v / 1e7 for v in struct.unpack('<4i', b[102:118])])
    found = {}
    def walk(d):
        for tid, run, ln, off in read_directory(d):
            if run == 0: walk(b[lo + off:lo + off + ln])
            else:
                for k in range(run): found[tid + k] = b[do + off:do + off + ln]
    walk(b[ro:ro + rl])
    return head, found

def decode_tile(raw):
    """{layer: (extent, [(geometry type, [rings or lines of (x, y)])])}"""
    out = {}; p = 0
    while p < len(raw):
        key, p = varint(raw, p); n, p = varint(raw, p); layer = raw[p:p + n]; p += n
        q = 0; name = ext = None; feats = []
        while q < len(layer):
            key, q = varint(layer, q)
            if key & 7 == 2:
                n, q = varint(layer, q); v = layer[q:q + n]; q += n
                if key >> 3 == 1: name = v.decode()
                else:
                    r = 0; typ = geom = None
                    while r < len(v):
                        k, r = varint(v, r)
                        if k >> 3 == 3: typ, r = varint(v, r)
                        else:
                            n2, r = varint(v, r); gb = v[r:r + n2]; r += n2; geom = []; s = 0
                            while s < len(gb): u, s = varint(gb, s); geom.append(u)
                    feats.append((typ, shapes(geom)))
            else:
                v, q = varint(layer, q)
                if key >> 3 == 5: ext = v
        out[name] = (ext, feats)
    return out

def shapes(g):
    i = x = y = 0; out = []; unzig = lambda u: (u >> 1) ^ -(u & 1)
    while i < len(g):
        cmd, cnt = g[i] & 7, g[i] >> 3; i += 1
        if cmd == 7: out[-1].append(out[-1][0]); continue
        for _ in range(cnt):
            x += unzig(g[i]); y += unzig(g[i + 1]); i += 2
            if cmd == 1: out.append([(x, y)])
            else: out[-1].append((x, y))
    return out

def zoom_of(tid):
    z = 0
    while tid >= (4 ** (z + 1) - 1) // 3: z += 1
    return z

def tile_at(lon, lat, z):
    wx, wy = build_tiles.world(lon, lat); return int(wx * 2 ** z), int(wy * 2 ** z), wx * 2 ** z, wy * 2 ** z

class TileWriterTests(unittest.TestCase):
    LINE = [(-122.350, 47.620), (-122.340, 47.625), (-122.335, 47.630)]
    SQUARE = [(-122.35, 47.62), (-122.34, 47.62), (-122.34, 47.63), (-122.35, 47.63), (-122.35, 47.62)]
    HOLE = [(-122.347, 47.623), (-122.347, 47.627), (-122.343, 47.627), (-122.343, 47.623), (-122.347, 47.623)]
    def small(self):
        return build_tiles.build({'arterial': [(8, self.LINE)], 'path': [(14, [(-122.3455, 47.6212), (-122.3445, 47.6214)])]},
                                 {'water': [[self.SQUARE, self.HOLE]], 'park': [[[(-122.33, 47.62), (-122.32, 47.62), (-122.32, 47.63), (-122.33, 47.62)]]]})
    def test_hilbert_ids(self):
        keys = [(0,0,0),(1,0,0),(1,0,1),(1,1,1),(1,1,0),(2,0,0)]
        self.assertEqual([build_tiles.zxy_to_id(*k) for k in keys], [0, 1, 2, 3, 4, 5])
    def test_which_ways_the_map_draws(self):
        m = build_tiles.map_line
        self.assertEqual(m({'highway': 'footway'}), ('path', 14))
        self.assertEqual(m({'highway': 'cycleway'}), ('path', 12))
        self.assertIsNone(m({'highway': 'proposed'}))
        self.assertEqual(m({'highway': 'service', 'service': 'alley'}), ('road', 13))
        self.assertEqual(m({'highway': 'service'}), ('road', 13))
        self.assertEqual(m({'highway': 'service', 'service': 'driveway'}), ('road', 14))
        self.assertEqual(m({'highway': 'motorway'}), ('arterial', 8))
        self.assertEqual(m({'highway': 'secondary'}), ('arterial', 11))
    def test_archive_structure(self):
        data, summary = self.small(); head, tiles = read_archive(data)
        self.assertEqual(data[:8], b'PMTiles\x03')
        self.assertEqual((head['comp'], head['type'], head['zooms']), ((1, 1), 1, (8, 14)))
        self.assertLessEqual(127 + head['root'][1], 16384)
        self.assertEqual(head['leaf'][1], 0)
        self.assertEqual((summary['bytes'], summary['addressedTiles']), (len(data), head['addressed']))
        self.assertEqual(summary['tileEntries'], head['entries']); self.assertEqual(summary['distinctTiles'], head['contents'])
        self.assertEqual([l['id'] for l in head['meta']['vector_layers']], ['arterial', 'park', 'path', 'road', 'water'])
        self.assertEqual(head['meta']['attribution'], '© OpenStreetMap contributors')
        W, S, E, N = head['bounds']; self.assertTrue(W <= -122.35 and E >= -122.32 and S <= 47.62 and N >= 47.63)
    def test_layers_appear_at_their_first_zoom(self):
        _, tiles = read_archive(self.small()[0]); zooms = {}
        for tid, raw in tiles.items():
            for name in decode_tile(raw): zooms.setdefault(name, set()).add(zoom_of(tid))
        self.assertEqual((min(zooms['arterial']), max(zooms['arterial'])), (8, 14))
        self.assertEqual(min(zooms['water']), 8); self.assertEqual(min(zooms['park']), 10); self.assertEqual(min(zooms['path']), 14)
        self.assertNotIn('road', zooms)
        self.assertEqual({zoom_of(t) for t in tiles}, set(range(8, 15)))
    def test_z14_line_stays_within_two_units_of_the_source(self):
        _, tiles = read_archive(self.small()[0])
        x, y, fx, fy = tile_at(*self.LINE[0], 14)
        ext, feats = decode_tile(tiles[build_tiles.zxy_to_id(14, x, y)])['arterial']
        self.assertEqual(ext, 8192)
        (typ, parts), = feats; self.assertEqual(typ, 2)
        want = ((fx - x) * ext, (fy - y) * ext)
        self.assertLessEqual(max(abs(parts[0][0][0] - want[0]), abs(parts[0][0][1] - want[1])), 2)
    def test_winding(self):
        _, tiles = read_archive(self.small()[0])
        x, y, _, _ = tile_at(-122.345, 47.625, 14)
        ext, feats = decode_tile(tiles[build_tiles.zxy_to_id(14, x, y)])['water']
        (typ, rings), = feats; self.assertEqual(typ, 3)
        area = lambda r: sum(a[0]*b[1] - b[0]*a[1] for a, b in zip(r, r[1:]))
        self.assertEqual(sorted(area(r) > 0 for r in rings), [False, True])  # a hole (negative) inside its exterior (positive)
    def test_identical_neighbours_share_one_entry(self):
        sea = [[(-122.45, 47.55), (-122.25, 47.55), (-122.25, 47.75), (-122.45, 47.75), (-122.45, 47.55)]]
        data, summary = build_tiles.build({}, {'water': [sea]}); head, tiles = read_archive(data)
        self.assertLess(summary['distinctTiles'], summary['addressedTiles'])
        self.assertLess(summary['tileEntries'], summary['addressedTiles'])
        self.assertEqual(len(tiles), summary['addressedTiles'])
    def test_empty_tiles_are_not_written(self):
        data, summary = build_tiles.build({'road': [(12, [(-122.35, 47.62), (-122.35, 47.62)])]}, {})
        self.assertEqual(summary['addressedTiles'], 0)
    def test_many_tiles_need_leaf_directories(self):
        # 60 x 60 short z14 lines, one per tile with its own bytes: more directory entries than fit in the root.
        lines = {'path': [(14, [(-123.0 + i * 0.03, 47.0 + j * 0.02), (-123.0 + i * 0.03 + 0.0005, 47.0 + j * 0.02 + 0.0004 * (1 + (i + j) % 7))])
                          for i in range(60) for j in range(60)]}
        data, summary = build_tiles.build(lines, {}); head, tiles = read_archive(data)
        self.assertGreater(head['leaf'][1], 0); self.assertLessEqual(127 + head['root'][1], 16384)
        self.assertEqual(len(tiles), summary['addressedTiles'])
        self.assertTrue(all(decode_tile(t) for t in tiles.values()))
    def test_same_input_same_bytes(self):
        self.assertEqual(self.small()[0], self.small()[0])

class SearchIndexTests(unittest.TestCase):
    @staticmethod
    def node(i, lat, lon, **tags): return {'type':'node','id':i,'lat':lat,'lon':lon,'tags':tags}
    @staticmethod
    def inside(n): return 47.6 <= n['lat'] <= 47.7 and -122.4 <= n['lon'] <= -122.3

    def test_fold_and_aliases(self):
        self.assertEqual(build_search.fold("Café Ladro's  Fremont-Ave"), 'cafe ladros fremont ave')
        self.assertEqual(build_search.fold('Bread & Butter'), 'bread and butter')
        self.assertEqual(build_search.aliases('3400 fremont avenue north'), 'ave av n')
    def test_categories_rank_landmarks_and_parks_over_shops(self):
        weight = lambda tags: build_search.category_of(tags)[1]
        self.assertGreater(weight({'tourism':'museum'}), weight({'leisure':'park'}))
        self.assertGreater(weight({'leisure':'park'}), weight({'shop':'bakery'}))
        self.assertGreater(weight({'shop':'bakery'}), weight({'building':'yes'}))
        self.assertGreater(weight({'historic':'memorial'}), weight({'historic':'house'}))
        self.assertIsNone(build_search.category_of({'amenity':'bench'}))
        self.assertIsNone(build_search.category_of({'highway':'bus_stop'}))
    def test_address_needs_number_and_street(self):
        self.assertEqual(build_search.address_of({'addr:housenumber':'2101','addr:street':'North 55th Street','addr:unit':'100'}),
                         ('2101 North 55th Street','100'))
        self.assertEqual(build_search.address_of({'addr:housenumber':'2101'}), (None, None))
        self.assertEqual(build_search.address_of({'addr:housenumber':'1;3','addr:street':'A Street'}), (None, None))
    def test_dedupe_within_50m_and_graph_places_win(self):
        graph = [{'id':'way/1','name':'Gas Works Park','lat':47.6456,'lon':-122.3344,'category':'park'}]
        elements = [
            {'type':'way','id':1,'center':{'lat':47.6460,'lon':-122.3340},'tags':{'name':'Gas Works Park','leisure':'park','wikidata':'Q5526323','addr:housenumber':'2101','addr:street':'North Northlake Way'}},
            self.node(2, 47.6500, -122.3500, name='Cafe Ladro', amenity='cafe'),
            self.node(3, 47.6502, -122.3501, name='Café Ladro', amenity='cafe'),     # ~25 m: same place
            self.node(4, 47.6600, -122.3500, name='Cafe Ladro', amenity='cafe'),     # ~1 km: another branch
            self.node(5, 47.6400, -122.3400, **{'addr:housenumber':'10','addr:street':'A Street'}),
            self.node(6, 47.6401, -122.3400, **{'addr:housenumber':'10','addr:street':'A Street'}),
            self.node(7, 47.6401, -122.3400, **{'addr:housenumber':'10','addr:street':'A Street','addr:unit':'B'}),
            self.node(8, 48.0, -122.35, name='Outside', amenity='cafe'),
        ]
        entries = build_search.entries_from(elements, graph, self.inside)
        places = [(e['osm'], e['name']) for e in entries if e['kind']=='place']
        self.assertEqual(places[0], ('way/1','Gas Works Park'))
        self.assertEqual(entries[0]['address'], '2101 North Northlake Way')
        self.assertEqual(entries[0]['weight'], 95)  # park, plus the notability bonus from the newer extract
        self.assertEqual(sum(n.startswith('Caf') for _, n in places), 2)
        self.assertNotIn('Outside', [n for _, n in places])
        self.assertEqual(sorted(e['name'] for e in entries if e['kind']=='address'),
                         ['10 A Street','10 A Street, Unit B','2101 North Northlake Way'])
    @staticmethod
    def overture(i, lat, lon, name, primary='coffee_shop', hierarchy=('food_and_drink', 'cafe'), dataset='Foursquare', license='Apache-2.0',
                 confidence=0.9, status='open', extra=()):
        return {'id':i,'name':name,'lat':lat,'lon':lon,'taxonomy':{'primary':primary,'hierarchy':list(hierarchy)},'confidence':confidence,
                'operating_status':status,'address':{'freeform':'1  Main St','postcode':'98103'},
                'sources':[{'dataset':dataset,'license':license,'record_id':'r','update_time':'2026-01-01T00:00:00Z'}, *extra]}
    def test_overture_filters_by_source_licence_status_confidence_and_box(self):
        o = self.overture
        records = [
            o('keep', 47.65, -122.35, 'Keep Coffee'),
            o('meta', 47.65, -122.351, 'Meta Place', dataset='meta', license='CDLA-Permissive-2.0'),
            o('wrong-licence', 47.65, -122.352, 'Wrong Licence', license='CDLA-Permissive-2.0'),   # Foursquare is Apache-2.0
            o('no-licence', 47.65, -122.353, 'No Licence', license=None),
            o('unlisted', 47.65, -122.354, 'Unlisted Source', dataset='SomeoneElse', license='CDLA-Permissive-2.0'),
            o('mixed', 47.65, -122.355, 'Mixed Sources', extra=[{'dataset':'SomeoneElse','license':'CDLA-Permissive-2.0'}]),
            o('overture-own', 47.65, -122.356, 'Own Signals', extra=[{'dataset':'Overture','license':'CDLA-Permissive-2.0'}]),
            o('closed', 47.65, -122.357, 'Closed Cafe', status='permanently_closed'),
            o('unknown-status', 47.65, -122.358, 'Unknown Status Cafe', status=None),
            o('low', 47.65, -122.359, 'Low Confidence', confidence=0.59),
            o('threshold', 47.65, -122.36, 'At Threshold', confidence=0.6),
            o('outside', 48.0, -122.35, 'Outside Cafe'),
            o('noname', 47.65, -122.361, ' '),
            o('b2b', 47.65, -122.362, 'Consulting Co', primary='business_consulting', hierarchy=('services_and_business', 'b2b_service')),
        ]
        stats = collections.Counter()
        found = build_search.overture_candidates(records, self.inside, stats)
        ids = sorted(x['osm'] for x in found)
        self.assertEqual(ids, ['overture/keep', 'overture/meta', 'overture/overture-own', 'overture/threshold', 'overture/unknown-status'])
        self.assertEqual({x['osm']: x['source'] for x in found}['overture/meta'], 'Overture · Meta')
        self.assertTrue(all(x['address'] is None for x in found))   # addresses come from OSM only
        self.assertEqual((stats['archive'], stats['inBox'], stats['confident'], stats['categorised']), (14, 13, 6, 5))
    def test_gzip_bytes_has_a_fixed_header_and_round_trips(self):
        raw = b'peoplemaps ' * 1000
        out = build_search.gzip_bytes(raw)
        self.assertEqual(out[:10], b'\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff')
        self.assertEqual(gzip.decompress(out), raw)
        self.assertEqual(out, build_search.gzip_bytes(raw))
    def test_overture_categories_map_to_osm_names_and_weights(self):
        cat = lambda primary, *hierarchy: build_search.overture_category({'primary': primary, 'hierarchy': list(hierarchy)})
        self.assertEqual(cat('coffee_shop', 'food_and_drink', 'cafe'), ('cafe', 50))
        self.assertEqual(cat('hospital', 'health_care'), ('hospital', 70))
        self.assertEqual(cat('art_museum', 'arts_and_entertainment', 'museum'), ('museum', 100))
        self.assertGreater(cat('park', 'sports_and_recreation')[1], cat('coffee_shop', 'food_and_drink')[1])
        # unmapped primaries keep their own name under the group's default weight, or walk up the hierarchy to a mapped parent
        self.assertEqual(cat('thai_restaurant', 'food_and_drink', 'restaurant', 'asian_restaurant'), ('thai_restaurant', 50))
        self.assertEqual(cat('chinese_bakery', 'food_and_drink', 'bakery'), ('bakery', 50))
        self.assertEqual(cat('cardiology', 'health_care', 'specialized_health_care')[1], 40)
        self.assertGreater(cat('dental_clinic', 'health_care')[1], cat('cardiology', 'health_care')[1])
        # business services, delivery-only listings and records with no taxonomy are not places people go to
        self.assertIsNone(cat('business_consulting', 'services_and_business', 'b2b_service'))
        self.assertIsNone(cat('pizza_delivery_service', 'lifestyle_services'))
        self.assertIsNone(build_search.overture_category({'primary': None, 'hierarchy': []}))
        self.assertIsNone(build_search.overture_category(None))
        self.assertEqual(cat('bank', 'services_and_business', 'financial_service'), ('bank', 50))
    def test_overture_duplicates_dropped_osm_wins_and_fills_generic_category(self):
        o = self.overture
        elements = [
            self.node(1, 47.6500, -122.3500, name='Cafe Ladro', amenity='cafe'),
            self.node(2, 47.6600, -122.3500, name='Unnamed Shop Building', building='yes'),
            self.node(3, 47.6700, -122.3500, name='Fremont Dental', office='yes'),
            self.node(4, 47.6610, -122.3500, name='Fancy Diner', amenity='restaurant'),
            self.node(5, 47.6900, -122.3500, name='Green Lake Park', leisure='park'),
            self.node(6, 47.6950, -122.3500, name='Coffee Mind', amenity='cafe'),
        ]
        records = [
            o('same', 47.65015, -122.35005, 'Café Ladro'),                                        # ~17 m, same folded name: dropped
            o('far', 47.6560, -122.3500, 'Cafe Ladro'),                                             # ~670 m: another branch, kept
            o('fills', 47.66003, -122.35003, 'Unnamed Shop Building', 'bakery', ('food_and_drink',)),  # OSM has only a building
            o('fills-office', 47.67003, -122.35, 'Fremont Dental', 'dental_clinic', ('health_care',)),
            o('keeps-category', 47.66103, -122.35, 'Fancy Diner', 'coffee_shop', ('food_and_drink', 'cafe')),  # OSM already says restaurant
            o('big-park', 47.69135, -122.3500, 'Green Lake Park', 'park', ('sports_and_recreation',)),  # ~150 m from OSM's point: same park
            o('shop-nearby', 47.69635, -122.3500, 'Coffee Mind'),                                      # ~150 m from OSM's café: a different shop
            o('spaced', 47.69503, -122.3500, 'Coffeemind'),                                           # ~30 m, same name without the space
            o('twin-a', 47.6800, -122.3500, 'Twin Cafe', confidence=0.8),
            o('twin-b', 47.68002, -122.3500, 'Twin Cafe', confidence=0.95),                        # same place twice: the better record stays
        ]
        stats = collections.Counter()
        entries = build_search.entries_from(elements, [], self.inside, build_search.overture_candidates(records, self.inside), stats)
        places = {e['osm']: e for e in entries if e['kind']=='place'}
        self.assertEqual(sorted(places), ['node/1','node/2','node/3','node/4','node/5','node/6','overture/far','overture/shop-nearby','overture/twin-b'])
        self.assertEqual(places['node/1']['name'], 'Cafe Ladro')            # OSM keeps its name and position
        self.assertEqual((places['node/1']['lat'], places['node/1']['lon']), (47.65, -122.35))
        self.assertEqual((places['node/2']['category'], places['node/2']['weight']), ('bakery', 50))
        self.assertEqual(places['node/3']['category'], 'dentist')
        self.assertEqual(places['node/4']['category'], 'restaurant')
        self.assertEqual(places['overture/far']['source'], 'Overture · Foursquare')
        self.assertIsNone(places['overture/far']['number'])              # a business never outranks the address row for its own number
        self.assertEqual(stats['categoryFilled'], 2)
    def test_snaps_to_largest_component_with_edges_both_ways(self):
        nodes = [{'lat':47.65,'lon':-122.35},{'lat':47.651,'lon':-122.35},{'lat':47.6501,'lon':-122.3501},{'lat':47.65,'lon':-122.351}]
        seg = lambda a, b, hw='residential', **d: {'a':a,'b':b,'hw':hw,**d}
        both = {'f':{'modes':['walk','drive']},'r':{'modes':['walk','drive']}}
        segments = [seg(0,1,**both), seg(2,3,'motorway',f={'modes':['drive']})]
        routable = build_search.routable_nodes(nodes, segments)
        self.assertEqual(routable['drive'], [0,1])   # node 2 is closer but only on a one-way motorway
        entries = [{'lat':47.6501,'lon':-122.3501}]
        build_search.snap(entries, nodes, routable)
        self.assertEqual(entries[0]['drive'], 0); self.assertIsNone(entries[0]['bike'])
    def test_database_is_deterministic_and_searchable(self):
        elements = [self.node(1, 47.65, -122.35, name='Fremont Brewing', amenity='pub', **{'addr:housenumber':'3409','addr:street':'Woodland Park Avenue North'}),
                    self.node(2, 47.651, -122.35, **{'addr:housenumber':'3400','addr:street':'Fremont Avenue North'})]
        nodes = [{'lat':47.65,'lon':-122.35},{'lat':47.651,'lon':-122.35}]
        segments = [{'a':0,'b':1,'hw':'residential','f':{'modes':['walk']},'r':{'modes':['walk']}}]
        snapshot = {'elements':elements,'osm3s':{'timestamp_osm_base':'2026-10-29T05:43:15Z'}}
        with tempfile.TemporaryDirectory() as tmp:
            a, b = pathlib.Path(tmp)/'a.gz', pathlib.Path(tmp)/'b.gz'
            build_search.build(snapshot, [], nodes, segments, self.inside, 'x', a)
            build_search.build(snapshot, [], nodes, segments, self.inside, 'x', b)
            self.assertEqual(a.read_bytes(), b.read_bytes())
            (pathlib.Path(tmp)/'db').write_bytes(gzip.decompress(a.read_bytes()))
            db = sqlite3.connect(pathlib.Path(tmp)/'db')
            q = lambda m: [r[0] for r in db.execute('SELECT name FROM entries WHERE id IN (SELECT rowid FROM fts WHERE fts MATCH ?) ORDER BY id', (m,))]
            self.assertEqual(q('{name alias}: "3400"* AND "fremont"* AND "ave"* AND "n"*'), ['3400 Fremont Avenue North'])
            self.assertEqual(q('"woodland"*'), ['Fremont Brewing', '3409 Woodland Park Avenue North'])  # the pub by its address
            self.assertEqual(dict(db.execute('SELECT key, value FROM meta'))['sourceDate'], '2026-10-29')
            self.assertEqual(db.execute('SELECT DISTINCT source FROM entries').fetchall(), [('OpenStreetMap',)])
            self.assertNotIn('overtureRelease', dict(db.execute('SELECT key, value FROM meta')))
            self.assertEqual(db.execute('SELECT walk FROM entries WHERE number = ?', ('3400',)).fetchone()[0], 1)
            db.close()
    def test_database_with_overture_has_row_sources_and_release(self):
        archive = {'release': '2026-10-21.0', 'fetched': '2026-10-30', 'count': 1, 'bbox': {}, 'source': 's3://x',
                   'places': [self.overture('abc', 47.6505, -122.3505, 'Broadcast Coffee')]}
        nodes = [{'lat':47.65,'lon':-122.35},{'lat':47.651,'lon':-122.35}]
        segments = [{'a':0,'b':1,'hw':'residential','f':{'modes':['walk']},'r':{'modes':['walk']}}]
        snapshot = {'elements':[self.node(2, 47.651, -122.35, **{'addr:housenumber':'3400','addr:street':'Fremont Avenue North'})],
                    'osm3s':{'timestamp_osm_base':'2026-10-29T05:43:15Z'}}
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            (tmp/'o.json.gz').write_bytes(gzip.compress(json.dumps(archive).encode(), mtime=0))
            summary = build_search.build(snapshot, [], nodes, segments, self.inside, 'x', tmp/'a.gz', tmp/'o.json.gz')
            build_search.build(snapshot, [], nodes, segments, self.inside, 'x', tmp/'b.gz', tmp/'o.json.gz')
            self.assertEqual((tmp/'a.gz').read_bytes(), (tmp/'b.gz').read_bytes())
            (tmp/'db').write_bytes(gzip.decompress((tmp/'a.gz').read_bytes()))
            db = sqlite3.connect(tmp/'db')
            self.assertEqual(db.execute('SELECT osm, source, category, walk FROM entries ORDER BY id').fetchall(),
                             [('node/2', 'OpenStreetMap', None, 1), ('overture/abc', 'Overture · Foursquare', 'cafe', 1)])
            meta = dict(db.execute('SELECT key, value FROM meta'))
            self.assertEqual((meta['overtureRelease'], meta['overtureDate'], meta['source']), ('2026-10-21.0', '2026-10-21', 'OpenStreetMap'))
            self.assertEqual(summary['overture']['shipped'], 1)
            self.assertEqual(summary['overture']['shippedBySource'], {'Overture · Foursquare': 1})
            db.close()

def tiled_dem(blocks, tile=2, across=2, down=2):
    """A gzipped uncompressed float32 tiled GeoTIFF; a block given as None is sparse (byte count 0)."""
    w, h = tile * across, tile * down; n = len(blocks); data = b''; offsets = []; counts = []
    ifd_len = 2 + 12 * 14 + 4; arrays_at = 8 + ifd_len; scale_at = arrays_at + 8 * n; tie_at = scale_at + 24; data_at = tie_at + 48
    for b in blocks:
        offsets.append(data_at + len(data)); counts.append(0 if b is None else 4 * tile * tile)
        data += b'' if b is None else array.array('f', b).tobytes()
    entries = [(256,3,1,w),(257,3,1,h),(258,3,1,32),(259,3,1,1),(262,3,1,1),(277,3,1,1),(284,3,1,1),(322,3,1,tile),(323,3,1,tile),
               (324,4,n,8+ifd_len),(325,4,n,8+ifd_len+4*n),(339,3,1,3),(33550,12,3,scale_at),(33922,12,6,tie_at)]
    ifd = struct.pack('<H', len(entries)) + b''.join(struct.pack('<HHII', *e) for e in entries) + struct.pack('<I', 0)
    blob = b'II*\x00' + struct.pack('<I', 8) + ifd + struct.pack(f'<{n}I', *offsets) + struct.pack(f'<{n}I', *counts) \
        + struct.pack('<3d', 1, 1, 0) + struct.pack('<6d', 0, 0, 0, 0, down * tile, 0) + data
    return gzip.compress(blob, mtime=0)

def restriction(id_, kind, members, **tags):
    return {'type': 'relation', 'id': id_, 'tags': {'type': 'restriction', 'restriction': kind, **tags},
            'members': [{'type': t, 'ref': r, 'role': role} for role, t, r in members]}

class RestrictionTests(unittest.TestCase):
    # F (1,2,3) meets V (3,4) at 3; V meets T (4,5,6) at 4.
    WAYS = {1: {'nodes': [1, 2, 3]}, 2: {'nodes': [3, 4]}, 3: {'nodes': [4, 5, 6]}}
    def compile(self, *relations): return compile_restrictions(list(relations), self.WAYS)
    def test_via_node_is_kept(self):
        r, c = self.compile(restriction(10, 'no_left_turn', [('from', 'way', 1), ('via', 'node', 3), ('to', 'way', 2)]))
        self.assertEqual([(x['viaOSM'], x['fromWay'], x['toWay']) for x in r], [(3, 1, 2), (3, 1, 2)])  # drive and bike
        self.assertEqual(c['viaNode'], 2)
    def test_via_way_no_bans_only_the_final_transition(self):
        r, c = self.compile(restriction(11, 'no_right_turn', [('from', 'way', 1), ('via', 'way', 2), ('to', 'way', 3)]))
        self.assertEqual({(x['viaOSM'], x['fromWay'], x['toWay'], x['mode']) for x in r}, {(4, 2, 3, 'drive'), (4, 2, 3, 'bike')})
        self.assertEqual(c['viaWayFinalTransitionBanned'], 2)
    def test_via_way_only_and_u_turn_are_ignored_and_counted(self):
        r, c = self.compile(restriction(12, 'only_straight_on', [('from', 'way', 1), ('via', 'way', 2), ('to', 'way', 3)]),
                            restriction(13, 'no_u_turn', [('from', 'way', 1), ('via', 'way', 2), ('to', 'way', 3)]))
        self.assertEqual(r, [])
        self.assertEqual((c['viaWayOnlyIgnored'], c['viaWayNoUTurnIgnored']), (2, 2))
    def test_conditional_and_malformed_are_ignored_and_counted(self):
        r, c = self.compile(restriction(14, 'no_left_turn', [('from', 'way', 1), ('via', 'node', 3), ('to', 'way', 2)], **{'restriction:conditional': 'no_left_turn @ (Mo-Fr)'}),
                            restriction(15, 'no_left_turn', [('from', 'way', 1), ('to', 'way', 2)]))
        self.assertEqual(r, [])
        self.assertEqual((c['conditionalIgnored'], c['malformedIgnored']), (2, 2))

class BarrierTests(unittest.TestCase):
    def test_lift_gate_blocks_except_on_a_bridge_or_with_access_yes(self):
        gate = {'barrier': 'lift_gate'}
        self.assertTrue(node_blocks(gate, 'drive')); self.assertTrue(node_blocks(gate, 'bike'))
        self.assertFalse(node_blocks(gate, 'drive', bridge_node=True)); self.assertFalse(node_blocks(gate, 'bike', bridge_node=True))
        self.assertFalse(node_blocks({**gate, 'access': 'yes'}, 'drive'))
        self.assertTrue(node_blocks({**gate, 'access': 'no'}, 'drive', bridge_node=True))  # an explicit ban still wins
        self.assertTrue(node_blocks({'barrier': 'gate'}, 'drive', bridge_node=True))  # only lift gates are special

class ElevationTests(unittest.TestCase):
    def sample(self, blocks):
        with tempfile.TemporaryDirectory() as d:
            path = pathlib.Path(d) / 'dem.tif.gz'; path.write_bytes(tiled_dem(blocks))
            z, _ = load_dem(path)
        return lambda x, y: z(4 - (y + 0.5), x + 0.5)  # pixel centres; north is the top row
    def test_blocks_land_where_they_belong(self):
        at = self.sample([[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12], [13, 14, 15, 16]])
        self.assertEqual([at(0, 0), at(1, 0), at(2, 0), at(3, 0), at(0, 1), at(3, 3)], [1, 2, 5, 6, 3, 16])
    def test_sparse_block_does_not_shear_the_blocks_after_it(self):
        # Water tiles have blocks whose byte count is 0. Assigning their empty slice used to shrink the grid.
        at = self.sample([[1, 2, 3, 4], None, [9, 10, 11, 12], [13, 14, 15, 16]])
        self.assertEqual([at(0, 0), at(1, 1), at(2, 0), at(3, 0), at(3, 1)], [1, 4, 0, 0, 0])  # the gap reads as 0 m
        self.assertEqual([at(0, 2), at(1, 3), at(2, 2), at(3, 3)], [9, 12, 13, 16])

class FreewayRefTests(unittest.TestCase):
    def test_refs_as_tagged_in_king_county(self):
        for tags, want in [({'highway': 'motorway', 'ref': 'I 5'}, 'I 5'),
                           ({'highway': 'motorway', 'ref': 'I 90', 'name': 'Lacey V. Murrow Memorial Bridge'}, 'I 90'),
                           ({'highway': 'trunk', 'ref': 'SR 161;SR 512'}, 'SR 161'),
                           ({'highway': 'motorway', 'ref': ' US 2 ;SR 522'}, 'US 2'),
                           ({'highway': 'motorway'}, None), ({'highway': 'motorway_link', 'ref': 'I 5'}, None),
                           ({'highway': 'primary', 'ref': 'SR 99'}, None)]:
            self.assertEqual(freeway_ref(tags), want, tags)

class SpeedEstimateTests(unittest.TestCase):
    SEATTLE = (47.6205, -122.3493)  # the Space Needle
    BELLEVUE = (47.6101, -122.2015)
    def test_estimates_apply_to_untagged_roads_outside_seattle_only(self):
        for tags, where, want in [
            ({'highway': 'residential'}, self.BELLEVUE, 25), ({'highway': 'unclassified'}, self.BELLEVUE, 25),
            ({'highway': 'unclassified', 'surface': 'gravel'}, self.BELLEVUE, 15), ({'highway': 'tertiary'}, self.BELLEVUE, 30),
            ({'highway': 'secondary'}, self.BELLEVUE, 35), ({'highway': 'primary'}, self.BELLEVUE, 35), ({'highway': 'trunk'}, self.BELLEVUE, 55),
            ({'highway': 'primary', 'maxspeed': '45 mph'}, self.BELLEVUE, None), ({'highway': 'primary', 'maxspeed': '50'}, self.BELLEVUE, None),
            ({'highway': 'primary', 'maxspeed': 'signals'}, self.BELLEVUE, 35),
            ({'highway': 'motorway'}, self.BELLEVUE, None), ({'highway': 'primary_link'}, self.BELLEVUE, None), ({'highway': 'service'}, self.BELLEVUE, None),
            ({'highway': 'residential'}, self.SEATTLE, None), ({'highway': 'primary'}, self.SEATTLE, None), ({'highway': 'trunk'}, self.SEATTLE, None)]:
            self.assertEqual(estimated_mph(tags, *where), want, (tags, where))
    def test_an_untagged_arterial_outside_seattle_is_busy_by_its_estimate(self):
        self.assertEqual(road_class({'highway': 'primary'}), 'arterial')
        self.assertEqual(road_class({'highway': 'primary'}, 35), 'busy')
        self.assertEqual(road_class({'highway': 'tertiary'}, 30), 'arterial')
        self.assertEqual(road_class({'highway': 'primary', 'maxspeed': '25 mph'}, None), 'arterial')

class CoveragePolygonTests(unittest.TestCase):
    # An L: the box 0..2 by 0..2 less its top right quarter.
    RING=[[0,0],[2,0],[2,1],[1,1],[1,2],[0,2],[0,0]]
    def test_points_against_a_concave_ring(self):
        rows,step=ring_rows([self.RING])
        for lat,lon,want in [(0.5,0.5,True),(0.5,1.5,True),(1.5,0.5,True),(1.5,1.5,False),(-0.5,0.5,False),(0.5,2.5,False),(1.5,-0.5,False)]:
            self.assertEqual(in_rows(lat,lon,rows,step),want,(lat,lon))

if __name__=='__main__':unittest.main()
