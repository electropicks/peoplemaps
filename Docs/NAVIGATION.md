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
   from the puck to the route's first coordinate while they are more than 25 m
   apart and the user has not been on the route.
8. **Testing:** Debug builds can replay a route with Ferrostar's simulated
   location provider (`--simulate-route`), which the UI tests use. Real-road
   feel needs the user's iPhone.

## Camera and heading while guiding

Added 1 November 2026, after a drive where a north-up map and a plain dot gave no
sense of direction.

- **The puck shows its heading.** A translucent wedge behind the blue dot points
  along the course Ferrostar snapped to the route, smoothed halfway towards each
  new fix along the shorter arc (changes under 2° are ignored). It fades out below
  1 m/s or when the course is unknown; an unknown speed with a known course (the
  simulated provider) counts as moving.
- **Four camera modes** (`GuidanceCamera` in `App/SeattleMap.swift`):
  `followCourseUp` is the default: the map turns to the heading and the puck sits
  a third of the way up the free map area. `followNorthUp` keeps north at the top
  with the puck centred. `overview` fits the whole route, north-up. `free` begins
  when the user pans, pinches or double-taps: following stops and the map stays
  where they left it. The map keeps the last heading while the user is stopped,
  so it never swings back north at a light.
- **Controls.** The compass button (`guidance-compass`) flips heading-up and
  north-up and resumes following; its glyph points north on screen. The overview
  button toggles the fitted view. In `free`, a "Re-centre" pill
  (`guidance-recenter`) returns to the follow mode the user left, as Apple Maps
  does. Camera turns animate with `Motion.camera`: a cut under Reduce Motion and
  `--ui-testing`.

## Stages

Each stage builds, passes `./Scripts/test.sh`, and is reviewed before the next.

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
