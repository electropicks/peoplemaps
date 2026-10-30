import collections, gzip, json, pathlib, sqlite3, tempfile, unittest
import build_search
from import_osm import access,directions,facility,clip_ring,sidewalk,crossing_control,control,parked_both_sides,approach_grade,climb,node_blocks,simplify_line,map_geojson

class ImportPolicyTests(unittest.TestCase):
    def test_private_road_excluded(self):
        self.assertFalse(access({'highway':'residential','access':'private'},'drive'))
    def test_modal_override(self):
        self.assertTrue(access({'highway':'path','access':'no','bicycle':'designated'},'bike'))
    def test_footpath_without_bike_permission_excluded(self):
        self.assertFalse(access({'highway':'footway'},'bike'))
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
    def test_map_lines_are_rounded_and_simplified(self):
        self.assertEqual(simplify_line([[-122.12345678,47.1],[-122.12345679,47.1]]),None)  # collapses to a point
        line=simplify_line([[-122.1,47.1],[-122.0999,47.10000001],[-122.0998,47.1]])  # middle point is within 0.3 m
        self.assertEqual(line,[[-122.1,47.1],[-122.0998,47.1]])
        bend=simplify_line([[-122.1,47.1],[-122.0999,47.1005],[-122.0998,47.1]])  # 55 m off the chord stays
        self.assertEqual(len(bend),3)
    def test_map_merges_lines_by_kind_without_names(self):
        out=map_geojson([],{'path':[[[0,0],[1,1]],[[2,2],[3,3]]]})
        self.assertEqual(out['features'],[{'type':'Feature','properties':{'kind':'path'},'geometry':{'type':'MultiLineString','coordinates':[[[0,0],[1,1]],[[2,2],[3,3]]]}}])

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
        self.assertEqual(found[0]['address'], '1 Main St')   # whitespace collapsed
        self.assertEqual((stats['archive'], stats['inBox'], stats['confident'], stats['categorised']), (14, 13, 6, 5))
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

if __name__=='__main__':unittest.main()
