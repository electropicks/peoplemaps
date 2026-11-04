#!/usr/bin/env python3
"""Report on the detailed drive log shared from the phone (Docs/REPORTS.md section 11).

    python3 Scripts/drive_log_report.py FOLDER [--min-stop 20] [--radius 40] [--mode drive] [--json]

FOLDER holds the `trip-*.jsonl` files (and, optionally, `use-*.jsonl`) from "Share detailed log". For each trip it
compares the time spent on each edge with the router's estimate, and lists every stop of at least --min-stop seconds
with where it was, how long, the next maneuver (and whether it is a left) and the road names. Then it groups stops
across trips by junction (within --radius metres), longest total first.

Standard library only. Real logs hold exact places: keep them out of the repository, Evidence and tests.
"""
import argparse
import glob
import json
import math
import os
import sys
from collections import Counter

MAX_GAP = 30.0       # seconds between fixes counted toward an edge; longer gaps (background, tunnels) are not
STOP_SPEED = 0.5     # m/s under which a fix counts as stopped
EDGE_SEARCH = 80     # segments ahead of the last match tried before searching the whole route
MATCH_LIMIT = 60.0   # metres from the route beyond which a fix is not on it


def load(path):
    """Header, fixes, events of one trip file. A torn last line (a crash) is skipped."""
    header, fixes, events = None, [], []
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            kind = row.get("kind")
            if kind == "header":
                header = row
            elif kind == "fix":
                fixes.append(row)
            elif kind == "event":
                events.append(row)
    fixes.sort(key=lambda r: r["t"])
    events.sort(key=lambda r: r["t"])
    return header, fixes, events


def metres(lat1, lon1, lat2, lon2):
    p = math.pi / 180
    dy = (lat2 - lat1) * 111_195
    dx = (lon2 - lon1) * 111_195 * math.cos((lat1 + lat2) * p / 2)
    return math.hypot(dx, dy)


def project(lat, lon, a, b):
    """Distance in metres from (lat, lon) to the segment a-b, in a local flat frame."""
    cos = math.cos(math.radians(lat))
    px, py = (lon - a[1]) * 111_195 * cos, (lat - a[0]) * 111_195
    bx, by = (b[1] - a[1]) * 111_195 * cos, (b[0] - a[0]) * 111_195
    n = bx * bx + by * by
    u = 0.0 if n == 0 else max(0.0, min(1.0, (px * bx + py * by) / n))
    return math.hypot(px - u * bx, py - u * by)


class Route:
    """One route record: coordinates, per-edge data, maneuvers."""

    def __init__(self, record, since):
        self.r = record
        self.since = since  # time this route took over
        self.coords = record.get("coordinates") or []
        starts = record.get("edgeStart") or []
        # segment i (coords[i] -> coords[i+1]) belongs to edge k
        self.segment_edge = []
        for k, s in enumerate(starts):
            end = starts[k + 1] if k + 1 < len(starts) else len(self.coords) - 1
            self.segment_edge += [k] * max(0, end - s)
        self.last = 0

    @property
    def has_edges(self):
        return bool(self.segment_edge)

    def edge_name(self, k):
        names = self.r.get("edgeNames") or []
        return names[k] if 0 <= k < len(names) else ""

    def match(self, lat, lon):
        """(segment index, distance) of the best segment, searching ahead of the last match first."""
        n = len(self.segment_edge)
        if n == 0:
            return None, None
        lo, hi = max(0, self.last - 3), min(n, self.last + EDGE_SEARCH)
        best = min(range(lo, hi), key=lambda i: project(lat, lon, self.coords[i], self.coords[i + 1]), default=None)
        dist = project(lat, lon, self.coords[best], self.coords[best + 1]) if best is not None else None
        if dist is None or dist > MATCH_LIMIT:
            best = min(range(n), key=lambda i: project(lat, lon, self.coords[i], self.coords[i + 1]))
            dist = project(lat, lon, self.coords[best], self.coords[best + 1])
        if dist > MATCH_LIMIT:
            return None, dist
        self.last = best
        return best, dist


def routes_of(header, events):
    """The route in force over time: the one the trip started with, then each reroute's."""
    chosen = [r for r in header.get("routes", []) if r.get("label") == header.get("startedWith")] or header.get("routes", [])
    routes = [Route(chosen[0], header["start"])] if chosen else []
    for e in events:
        if e["name"] == "reroute":
            rec = (e.get("data") or {}).get("route")
            if isinstance(rec, dict):
                routes.append(Route(rec, e["t"]))
    return routes


def route_at(routes, t):
    current = routes[0] if routes else None
    for r in routes:
        if r.since <= t:
            current = r
    return current


def maneuver_at(events, routes, t):
    """The maneuver ahead at time t: the step after the one being driven, from the latest maneuver event."""
    last = None
    for e in events:
        if e["name"] == "maneuver" and e["t"] <= t:
            last = e
    if last is None or not routes:
        return None
    data = last["data"]
    route = routes[min(int(data.get("route", 0)), len(routes) - 1)]
    steps = route.r.get("maneuvers") or []
    i = int(data["stepIndex"]) + 1
    return steps[i] if i < len(steps) else None


def analyse(path, min_stop):
    header, fixes, events = load(path)
    if header is None or len(fixes) < 2:
        return None
    routes = routes_of(header, events)
    end = next((e for e in reversed(events) if e["name"] == "end"), None)
    first_route = routes[0].r if routes else {}
    out = {
        "file": os.path.basename(path),
        "mode": header.get("mode"),
        "start": header["start"],
        "destination": header["request"].get("destinationName"),
        "started_with": header.get("startedWith"),
        "complete": end is not None,
        "end_reason": (end or {}).get("data", {}).get("reason"),
        "estimate_seconds": first_route.get("seconds"),
        "estimate_meters": first_route.get("meters"),
        "reroutes": sum(1 for e in events if e["name"] == "reroute"),
        "edges": [],
        "stops": [],
    }
    # Per fix: stopped or moving, and the edge it is on.
    n = len(fixes)
    stopped = []
    for i, f in enumerate(fixes):
        s = f.get("speed")
        if s is not None and s >= 0:
            stopped.append(s < STOP_SPEED)
        elif i > 0:
            p = fixes[i - 1]
            dt = f["t"] - p["t"]
            stopped.append(dt > 0 and metres(p["lat"], p["lon"], f["lat"], f["lon"]) / dt < STOP_SPEED)
        else:
            stopped.append(False)
    placed = []
    for f in fixes:
        route = route_at(routes, f["t"])
        seg, _ = route.match(f["lat"], f["lon"]) if route else (None, None)
        placed.append((route, route.segment_edge[seg] if seg is not None else None))

    meters = sum(metres(fixes[i]["lat"], fixes[i]["lon"], fixes[i + 1]["lat"], fixes[i + 1]["lon"]) for i in range(n - 1))
    moving = stopped_time = 0.0
    actual_on = {}
    for i in range(n - 1):
        dt = min(fixes[i + 1]["t"] - fixes[i]["t"], MAX_GAP)
        if stopped[i]:
            stopped_time += dt
        else:
            moving += dt
        route, k = placed[i]
        if route is not None and k is not None:
            key = (id(route), k)
            actual_on[key] = (actual_on[key][0] + dt if key in actual_on else dt, route, k)
    out["actual_seconds"] = round(fixes[-1]["t"] - fixes[0]["t"], 1)
    out["moving_seconds"] = round(moving, 1)
    out["stopped_seconds"] = round(stopped_time, 1)
    out["gps_meters"] = round(meters, 1)
    out["average_moving_mps"] = round(meters / moving, 2) if moving else None
    out["estimated_mps"] = round(out["estimate_meters"] / out["estimate_seconds"], 2) if out["estimate_seconds"] else None

    # Time on each edge against the estimate. Edges the trip only touched in part are marked.
    for _, (seconds, route, k) in sorted(actual_on.items(), key=lambda kv: (kv[1][1].since, kv[1][2])):
        est = (route.r.get("edgeSeconds") or [None] * (k + 1))[k]
        meters_k = (route.r.get("edgeMeters") or [None] * (k + 1))[k]
        out["edges"].append({"route": routes.index(route), "edge": k, "name": route.edge_name(k), "meters": meters_k,
                             "actual_seconds": round(seconds, 1), "estimate_seconds": est,
                             "excess_seconds": round(seconds - est, 1) if est is not None else None})
    out["junction_estimate_seconds"] = first_route.get("junctionSeconds")

    # Stops.
    i = 0
    while i < n:
        if not stopped[i]:
            i += 1
            continue
        j = i
        while j + 1 < n and stopped[j + 1]:
            j += 1
        # It lasts until the next moving fix (or the last fix); a long gap in the fixes is not counted as standing.
        t0 = fixes[i]["t"]
        t1 = fixes[j + 1]["t"] if j + 1 < n else fixes[j]["t"]
        t1 = min(t1, fixes[j]["t"] + MAX_GAP)
        duration = t1 - t0
        if duration >= min_stop:
            group = fixes[i:j + 1]
            lat = sum(g["lat"] for g in group) / len(group)
            lon = sum(g["lon"] for g in group) / len(group)
            route, k = placed[i]
            nxt = maneuver_at(events, routes, t0)
            at_destination = bool(routes) and (j + 1 >= n or (nxt is not None and nxt.get("kind") == "arrive" and metres(
                lat, lon, nxt.get("lat") or lat, nxt.get("lon") or lon) < 40))
            out["stops"].append({
                "t": t0, "lat": round(lat, 6), "lon": round(lon, 6), "seconds": round(duration, 1),
                "road": route.edge_name(k) if route is not None and k is not None else "",
                "next_maneuver": nxt.get("instruction") if nxt else None,
                "next_kind": nxt.get("kind") if nxt else None,
                "next_is_left": bool(nxt) and "left" in (nxt.get("kind") or ""),
                "onto": nxt.get("street") if nxt else None,
                "meters_to_maneuver": round(metres(lat, lon, nxt["lat"], nxt["lon"])) if nxt and nxt.get("lat") is not None else None,
                "at_destination": at_destination,
            })
        i = j + 1
    return out


def group_stops(trips, radius):
    """Greedy grouping of stops within `radius` metres of a group's centre, across trips."""
    groups = []
    for trip in trips:
        for s in trip["stops"]:
            if s["at_destination"]:
                continue
            for g in groups:
                if metres(g["lat"], g["lon"], s["lat"], s["lon"]) <= radius:
                    g["stops"].append((trip["file"], s))
                    n = len(g["stops"])
                    g["lat"] += (s["lat"] - g["lat"]) / n
                    g["lon"] += (s["lon"] - g["lon"]) / n
                    break
            else:
                groups.append({"lat": s["lat"], "lon": s["lon"], "stops": [(trip["file"], s)]})
    result = []
    for g in groups:
        secs = [s["seconds"] for _, s in g["stops"]]
        lefts = sum(1 for _, s in g["stops"] if s["next_is_left"])
        road = Counter(s["road"] for _, s in g["stops"] if s["road"]).most_common(1)
        onto = Counter(s["onto"] for _, s in g["stops"] if s["onto"]).most_common(1)
        kinds = Counter(s["next_kind"] for _, s in g["stops"] if s["next_kind"]).most_common(1)
        result.append({
            "lat": round(g["lat"], 6), "lon": round(g["lon"], 6), "stops": len(secs), "trips": len({f for f, _ in g["stops"]}),
            "total_seconds": round(sum(secs), 1), "mean_seconds": round(sum(secs) / len(secs), 1), "max_seconds": max(secs),
            "next_left": lefts, "road": road[0][0] if road else "", "onto": onto[0][0] if onto else "",
            "usual_next": kinds[0][0] if kinds else None,
        })
    result.sort(key=lambda g: -g["total_seconds"])
    return result


def use_summary(folder):
    counts = Counter()
    for path in sorted(glob.glob(os.path.join(folder, "use-*.jsonl"))):
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    counts[json.loads(line).get("name", "?")] += 1
                except ValueError:
                    pass
    return dict(counts)


def fmt_time(seconds):
    seconds = int(round(seconds))
    return f"{seconds // 60}:{seconds % 60:02d}"


def render(trips, groups, uses, min_stop):
    lines = []
    for t in trips:
        lines.append(f"== {t['file']}  {t['mode']} to {t['destination']}  (started with {t['started_with']}"
                     f"{'' if t['complete'] else ', INCOMPLETE: no end line'}{', ' + t['end_reason'] if t['end_reason'] else ''})")
        est = t["estimate_seconds"]
        lines.append(f"   actual {fmt_time(t['actual_seconds'])} (moving {fmt_time(t['moving_seconds'])}, stopped {fmt_time(t['stopped_seconds'])})"
                     f" vs estimate {fmt_time(est) if est else '?'};  GPS distance {t['gps_meters']:.0f} m vs {t['estimate_meters'] or 0:.0f} m;"
                     f" moving speed {t['average_moving_mps']} m/s vs estimated {t['estimated_mps']} m/s;  reroutes {t['reroutes']}")
        slow = [e for e in t["edges"] if e["excess_seconds"] is not None and e["excess_seconds"] >= 5]
        slow.sort(key=lambda e: -e["excess_seconds"])
        if slow:
            lines.append("   edges that took 5 s or more over the estimate:")
            for e in slow[:12]:
                lines.append(f"     {e['name'] or '(unnamed)':32s} actual {e['actual_seconds']:6.1f} s  est {e['estimate_seconds']:6.1f} s  +{e['excess_seconds']:.1f}")
        for s in t["stops"]:
            where = f"{s['road'] or 'unknown road'}"
            nxt = f"next: {s['next_maneuver']}" + (" (LEFT)" if s["next_is_left"] else "") if s["next_maneuver"] else "next maneuver unknown"
            far = f", {s['meters_to_maneuver']} m before it" if s["meters_to_maneuver"] is not None else ""
            tag = "  [destination]" if s["at_destination"] else ""
            lines.append(f"   stop {s['seconds']:5.0f} s at {s['lat']:.5f},{s['lon']:.5f}  on {where};  {nxt}{far}{tag}")
        if not t["stops"]:
            lines.append(f"   no stops of {min_stop:g} s or more")
    lines.append("")
    lines.append(f"== Stops of {min_stop:g} s or more, grouped by junction, longest total first")
    if not groups:
        lines.append("   none")
    for i, g in enumerate(groups, 1):
        left = f"next maneuver a left in {g['next_left']} of {g['stops']}"
        lines.append(f"{i:3d}. {fmt_time(g['total_seconds'])} total over {g['stops']} stops in {g['trips']} trips "
                     f"(mean {g['mean_seconds']:.0f} s, longest {g['max_seconds']:.0f} s)  {g['lat']:.5f},{g['lon']:.5f}")
        lines.append(f"      {g['road'] or 'unknown road'}" + (f" -> {g['onto']}" if g["onto"] else "") + f";  {left}")
    if uses:
        lines.append("")
        lines.append("== App use: " + ", ".join(f"{k} {v}" for k, v in sorted(uses.items(), key=lambda kv: -kv[1])))
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("folder")
    ap.add_argument("--min-stop", type=float, default=20.0, help="shortest stop to report, seconds (20)")
    ap.add_argument("--radius", type=float, default=40.0, help="stops this close, metres, are one junction (40)")
    ap.add_argument("--mode", choices=["drive", "bike", "walk"], help="only trips in this mode")
    ap.add_argument("--json", action="store_true", help="print JSON instead of text")
    args = ap.parse_args(argv)
    if not os.path.isdir(args.folder):
        print(f"not a folder: {args.folder}", file=sys.stderr)
        return 2
    trips = []
    for path in sorted(glob.glob(os.path.join(args.folder, "trip-*.jsonl"))):
        trip = analyse(path, args.min_stop)
        if trip and (not args.mode or trip["mode"] == args.mode):
            trips.append(trip)
    groups = group_stops(trips, args.radius)
    uses = use_summary(args.folder)
    if args.json:
        print(json.dumps({"trips": trips, "junctions": groups, "use": uses}, indent=1))
    else:
        print(render(trips, groups, uses, args.min_stop))
    return 0


if __name__ == "__main__":
    sys.exit(main())
