import gzip, pathlib, sqlite3, tempfile, unittest
import build_search
from import_osm import access,directions,facility,clip_ring,sidewalk,crossing_control,control,parked_both_sides,approach_grade,climb,node_blocks

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
            self.assertEqual(db.execute('SELECT walk FROM entries WHERE number = ?', ('3400',)).fetchone()[0], 1)
            db.close()

if __name__=='__main__':unittest.main()
