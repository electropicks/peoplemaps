import unittest
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

if __name__=='__main__':unittest.main()
