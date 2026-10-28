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
7. **Off-route thresholds:** 50 m driving, 30 m cycling and walking, using
   Ferrostar's built-in reroute throttling (5 s, 50 m). A reroute keeps the
   destination, mode, extra-time budget and calmer/fastest choice.
8. **Testing:** Debug builds can replay a route with Ferrostar's simulated
   location provider (`--simulate-route`), which the UI tests use. Real-road
   feel needs the user's iPhone.

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
