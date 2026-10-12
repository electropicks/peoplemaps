import unittest
from import_osm import access,directions,facility,clip_ring

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

if __name__=='__main__':unittest.main()
