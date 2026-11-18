# Navigation plan

Decided 27 October 2026, after the Ferrostar spike (`Spikes/ferrostar/`).
Screens: the "navigation" rows of the design canvas
(https://claude.ai/artifact/HW5tDWwDFUmweSopZpuroE).

## Decisions

1. **Our route, always.** Guidance follows the exact geometry our router chose
   (calmer or fastest, whichever the user picked) and reroutes with our own
   `NativeRouter`. No third-party routing service.
2. **Ferrostar's engine, our screens.** We use `FerrostarCore` (step progress,
   snapping to the route, off-route detection, reroute throttling, spoken
   instruction timing). We do not use its prebuilt map views: guidance draws on
   our own `SeattleMap` and our own SwiftUI banner, chips and trip bar. Skipping
   `FerrostarMapLibreUI` also avoids its macro dependency.
3. **Ferrostar stays out of `Core`.** `Core` produces a plain-Swift
   `NavigationPlan` (steps, maneuvers, instruction text, calm notes) that is unit
   tested with `swift test`. A small adapter in `App/` turns it into Ferrostar's
   `Route`. Swapping the engine later means replacing only the adapter.
4. **Calm notes are the differentiator.** Each maneuver carries the stress facts
   at its junction from the route's breakdown ("Signalled left", "Signalled
   crossing", "Stop sign"), shown as the chip near the turn. Facts only, never
   "safe".
5. **Location, minimal.** "When in use" permission, requested only when the user
   taps Start, with a plain usage string. Version 1 guides in the foreground
   only (screen kept awake); background guidance comes later. The app works fully
   without the permission: browsing and comparing never ask.
6. **Units follow the device locale** (feet/miles in the US) in both the
   banner and the voice.
7. **Off-route thresholds:** the engine flags a fix off-route at 50 m driving
   and 30 m cycling and walking, measured from the current step. `RerouteGate`
   (`Core/RerouteGate.swift`) decides which flagged fixes start a reroute: the
   fix must be off by more than that base plus its own accuracy radius plus one
   second of travel, for three fixes in a row; at least 10 s must have passed
   since the route was installed; and while the user has not yet been on a
   route (its first coordinate is a snapped node, up to 400 m off) only moving
   away from it, or travelling past where it starts, counts. Ferrostar's own
   throttling (5 s, 50 m) still applies underneath. A reroute keeps the
   destination, mode, extra-time budget and calmer/fastest choice. The map
   replaces the line in place when a reroute lands, and draws a dashed leader
   from the device's own fix to the route's first coordinate while they are more
   than 25 m apart and the gate has not seen the user on the route. The gate
   and the leader both read Ferrostar's raw `userLocation`, not the snapped one,
   so "on the route" means a fix with accuracy of 25 m or better within 25 m of
   the line; a poor fix keeps the leader.
8. **Testing:** Debug builds can replay a route with Ferrostar's simulated
   location provider (`--simulate-route`), which the UI tests use. Real-road
   feel needs the user's iPhone.

## Camera and heading while guiding

Added 1 November 2026, after a drive where a north-up map and a plain dot gave no
sense of direction.

- **The puck shows its heading** as an arrow once the course is known, and as a plain dot
  before that (`DESIGN.md` 4.7). The first version used a wedge: a translucent wedge behind the blue dot pointed
  along the course Ferrostar snapped to the route, smoothed halfway towards each
  new fix along the shorter arc (changes under 2° are ignored). It fades out below
  1 m/s or when the course is unknown; an unknown speed with a known course (the
  simulated provider) counts as moving.
- **Three states on one button** (`GuidanceCamera` in `App/SeattleMap.swift`, button
  `guidance-camera`). A tap cycles travel direction, compass direction, whole route, and
  round again. *Travel direction* (`followCourseUp`, the default) turns the map to the
  heading below and puts the puck a third of the way up the free map area, zoomed.
  *Compass direction* (`followCompass`) turns the map to the phone's compass
  (`CLHeading.trueHeading`) at the same zoom and puck position, whatever the speed.
  *Whole route* (`overview`) fits the route, north-up. `free` begins when the user pans,
  pinches or double-taps: following stops and the map stays where they left it. A tap on
  the button, or on the "Re-centre" pill (`guidance-recenter`), returns to the state before
  the pan. North-up following no longer exists. Camera turns animate with `Motion.camera`:
  a cut under Reduce Motion and `--ui-testing`.
- **Heading when stopped.** GPS course says nothing at a light or before the first metre,
  so the marker's point and the travel-direction camera use `HeadingBlender`
  (`Core/HeadingBlender.swift`): the compass when speed is under 2 m/s (hand-over back
  below 1.5, so it does not flicker at the edge) or the course is invalid, the course
  above that. A change of source fades over 0.6 s along the shorter arc, then the usual
  halfway smoothing applies (changes under 2 degrees are ignored). With no compass the
  course is used only while moving; with neither the last heading stays. Walking and
  cycling are mostly under 2 m/s, so they follow the compass. `NavigationController`
  holds the blended `heading`; `ExploreView` feeds it from the existing heading flow
  (`LocationPermission.compass`), which asks for a 2 degree filter while guiding and 8
  otherwise. Not verified on a real device yet: the compass calibration prompt and
  magnetic interference in a car.
- **Controls.** Mute and the report flag are one glass capsule; the camera button stands
  alone in a bottom corner (`DESIGN.md` 4.7).

## Handing a route to another app

Added 18 November 2026, after testing whether Google Maps, Apple Maps and the open-source apps can carry a calmer route
(write-up: https://claude.ai/artifact/UqViVa4BHpqDpdGVEf7JBd). Our own guidance stays; this is a second way to start.

- **The menu.** A button beside Start (`HandoffMenu` in `App/RoutePreview.swift`, `handoff-menu`) offers Google Maps,
  Apple Maps and Share as GPX for the route the preview has chosen. Each app item says what the app keeps.
- **Stops, not a line.** Google Maps and Apple Maps take stops and route between them themselves. `RouteHandoff`
  (`Core/RouteHandoff.swift`) places them on our line, 4 for drives and 9 otherwise, each splitting the longest gap left
  between the ends and the stops so far: at the middle of a street where the calmer route leaves our fastest route when one
  lies in that gap, else at the gap's middle. Gaps of 500 m or less are left alone. Stops only on the streets that differ
  were not enough: Apple Maps then swapped a stretch both of our routes share for its own. In tests on the web this kept our
  calmer drives in both apps and about 80% of the calmer bike streets in Google Maps. The fastest route, or a trip with no
  calmer route, goes with no stops. Every stop shows in the other app as an errand with a nearby address.
- **Apple Maps, drive only.** Apple Maps gives no walking or cycling directions with any stop, so those get the
  destination only, and the menu says it picks its own route.
- **Links.** Google: the universal link `https://www.google.com/maps/dir/?api=1` (`comgooglemaps://` drops waypoints).
  Apple: unified Maps URLs, `https://maps.apple.com/directions` with repeated `waypoint`. The start is left out when it is
  the current location, so the other app starts from its own fix.
- **GPX.** `Route.gpx(name:mode:)` writes the whole line as a GPX 1.1 track. OsmAnd follows it with Navigate by track;
  bike apps build cues from it.
- **Nothing comes back.** We never ask Apple or Google for their route, ETA or stop names (no `MKDirections`), so no Apple
  Maps data reaches the app (`Docs/SEARCH.md`). Fidelity is checked by testing, not at runtime.

## Stages

Each stage builds, passes `Scripts/verify.sh`, and is reviewed before the next.

1. **Core plan.** `NavigationPlan` from a `Route`: depart; a step at each
   decision (name change with a turn above 35°, ramps, forks, U-turns); arrive.
   Plus instruction text ("Turn left onto 1st Ave N", "Cross at the signal"),
   distances, and per-maneuver calm notes. `Route` records which junction
   factors happened at each edge so notes come from real data. Unit tests cover
   short edges, unnamed paths, merged steps and walking crossings.
2. **Engine wiring.** Add `FerrostarCore` (exact pin) to the Xcode project via
   `Scripts/generate_project.py`; the adapter `NavigationPlan` → Ferrostar
   `Route`; `CustomRouteProvider` backed by `NativeRouter`; a simulated run in the
   app on our map.
3. **Screens.** Start button on the preview, guidance banner, calm chip, trip
   bar, rerouting state, arrival summary, landscape, all per the canvas.
4. **Voice and permission.** Spoken instructions, the location permission flow,
   the screen kept awake, and end/arrival handling.
5. **On a real phone.** The user tests drives, rides and walks; we tune the
   thresholds and the wording.
