#!/usr/bin/env python3
"""Tests for drive_log_report.py on a made-up track: nothing here comes from a real log or a real home."""
import io
import json
import math
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import drive_log_report as report

# A made-up street grid far from anywhere anyone lives: north along "Alder St", then left (west) onto "Birch Ave".
ORIGIN = (47.40000, -121.90000)
M_LAT = 111_195.0
M_LON = 111_195.0 * math.cos(math.radians(47.4))
T0 = 1_800_000_000.0


def at(north, west=0.0):
    return [round(ORIGIN[0] + north / M_LAT, 6), round(ORIGIN[1] - west / M_LON, 6)]


def route_record():
    coords = [at(0), at(400), at(800), at(800, 400)]
    maneuvers = [
        {"index": 0, "kind": "depart", "instruction": "Head north on Alder St", "street": "Alder St", "meters": 800, "seconds": 80, "lat": coords[0][0], "lon": coords[0][1]},
        {"index": 1, "kind": "left", "instruction": "Turn left onto Birch Ave", "street": "Birch Ave", "meters": 400, "seconds": 40, "lat": coords[2][0], "lon": coords[2][1]},
        {"index": 2, "kind": "arrive", "instruction": "Arrive at destination", "street": "", "meters": 0, "seconds": 0, "lat": coords[3][0], "lon": coords[3][1]},
    ]
    return {"label": "calmer", "meters": 1200, "seconds": 120, "edgeIDs": [1, 2, 3], "wayIDs": [10, 10, 11],
            "edgeNames": ["Alder Street", "Alder Street", "Birch Avenue"], "edgeMeters": [400, 400, 400], "edgeSeconds": [40, 40, 40],
            "edgeStart": [0, 1, 2], "junctionSeconds": 0, "coordinates": coords, "maneuvers": maneuvers}


def position(d):
    """[lat, lon] at d metres along the route: 800 north, then 400 west."""
    return at(d) if d <= 800 else at(800, d - 800)


def write_trip(folder, name, stops=(), end=True, torn=False, start=T0):
    """1 Hz fixes at 10 m/s with a stand at each (metres along, seconds) in `stops`."""
    rows = [{"kind": "header", "schema": 1, "start": start, "mode": "drive", "startedWith": "calmer", "calmerOffered": True,
             "request": {"destinationName": "Test Cafe"}, "routes": [route_record()]}]
    t, d, stops = start, 0.0, sorted(stops)
    rows.append({"kind": "event", "t": t, "name": "maneuver", "data": {"stepIndex": 0, "upcoming": 0, "route": 0}})
    while d < 1200:
        stand = next((s for s in stops if abs(s[0] - d) <= 5 and s[1] > 0), None)
        if stand:
            seconds = stand[1]
            stops = [s for s in stops if s is not stand]
            for _ in range(int(seconds)):
                rows.append({"kind": "fix", "t": t, "lat": position(d)[0], "lon": position(d)[1], "accuracy": 5, "speed": 0.0})
                t += 1
        rows.append({"kind": "fix", "t": t, "lat": position(d)[0], "lon": position(d)[1], "accuracy": 5, "speed": 10.0})
        t, d = t + 1, d + 10
        if d >= 800 and not any(r["name"] == "maneuver" and r["data"]["stepIndex"] == 1 for r in rows if r["kind"] == "event"):
            rows.append({"kind": "event", "t": t, "name": "maneuver", "data": {"stepIndex": 1, "upcoming": 2, "route": 0}})
    if end:
        rows.append({"kind": "event", "t": t, "name": "end", "data": {"reason": "arrived", "seconds": t - start}})
    with open(os.path.join(folder, name), "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
        if torn:
            f.write('{"kind":"fix","t":1800')   # a crash mid-line


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        d = self.dir.name
        write_trip(d, "trip-20270101T000000Z-drive.jsonl", stops=[(785, 45)], start=T0)
        write_trip(d, "trip-20270102T000000Z-drive.jsonl", stops=[(790, 30), (400, 10)], start=T0 + 86400)
        write_trip(d, "trip-20270103T000000Z-drive.jsonl", stops=[(200, 25)], end=False, torn=True, start=T0 + 2 * 86400)
        with open(os.path.join(d, "use-2027-01-01.jsonl"), "w") as f:
            f.write(json.dumps({"kind": "event", "t": T0, "name": "search_pick", "data": {"query": "cafe"}}) + "\n")
        self.trips = [report.analyse(p, 20) for p in sorted(__import__("glob").glob(os.path.join(d, "trip-*.jsonl")))]

    def tearDown(self):
        self.dir.cleanup()

    def test_stop_of_20_seconds_or_more_is_found_with_its_maneuver(self):
        stop = self.trips[0]["stops"][0]
        self.assertAlmostEqual(stop["seconds"], 45, delta=1.5)
        self.assertEqual(stop["road"], "Alder Street")
        self.assertEqual(stop["next_kind"], "left")
        self.assertTrue(stop["next_is_left"])
        self.assertEqual(stop["onto"], "Birch Ave")
        self.assertAlmostEqual(stop["meters_to_maneuver"], 15, delta=12)

    def test_stops_under_the_minimum_are_left_out(self):
        self.assertEqual([round(s["seconds"]) for s in self.trips[1]["stops"]], [30])

    def test_time_on_each_edge_is_compared_with_the_estimate(self):
        edges = {e["edge"]: e for e in self.trips[0]["edges"]}
        self.assertEqual(edges[0]["estimate_seconds"], 40)
        self.assertAlmostEqual(edges[0]["actual_seconds"], 40, delta=2)
        self.assertAlmostEqual(edges[1]["actual_seconds"], 85, delta=3)   # 40 s driving plus the 45 s stand
        self.assertAlmostEqual(edges[1]["excess_seconds"], 45, delta=3)

    def test_trip_totals(self):
        t = self.trips[0]
        self.assertAlmostEqual(t["stopped_seconds"], 45, delta=2)
        self.assertAlmostEqual(t["average_moving_mps"], 10, delta=0.6)
        self.assertEqual(t["estimated_mps"], 10)
        self.assertTrue(t["complete"])

    def test_a_torn_unfinished_trip_still_reads(self):
        t = self.trips[2]
        self.assertFalse(t["complete"])
        self.assertEqual(len(t["stops"]), 1)

    def test_the_stop_at_the_end_is_marked_as_the_destination(self):
        folder = tempfile.TemporaryDirectory()
        write_trip(folder.name, "trip-1.jsonl", stops=[(1190, 60)])
        stops = report.analyse(os.path.join(folder.name, "trip-1.jsonl"), 20)["stops"]
        folder.cleanup()
        self.assertTrue(stops and all(s["at_destination"] for s in stops))

    def test_junctions_group_across_trips_longest_first(self):
        groups = report.group_stops([t for t in self.trips if t], 40)
        self.assertEqual([g["stops"] for g in groups], [2, 1])
        self.assertAlmostEqual(groups[0]["total_seconds"], 75, delta=3)
        self.assertEqual(groups[0]["trips"], 2)
        self.assertEqual(groups[0]["next_left"], 2)
        self.assertEqual(groups[0]["road"], "Alder Street")
        self.assertGreater(groups[0]["total_seconds"], groups[1]["total_seconds"])

    def test_command_line_prints_a_summary_and_json(self):
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(report.main([self.dir.name]), 0)
        text = out.getvalue()
        self.assertIn("grouped by junction", text)
        self.assertIn("(LEFT)", text)
        self.assertIn("INCOMPLETE", text)
        self.assertIn("search_pick 1", text)
        out = io.StringIO()
        with redirect_stdout(out):
            report.main([self.dir.name, "--json", "--min-stop", "40"])
        data = json.loads(out.getvalue())
        self.assertEqual(len(data["junctions"]), 1)
        self.assertEqual(report.main(["/no/such/folder"]), 2)


if __name__ == "__main__":
    unittest.main()
