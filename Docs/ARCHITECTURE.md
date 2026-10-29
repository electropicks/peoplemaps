# Why this slice

Peoplemaps is a working name. The product hypothesis is that a person can set a
small time allowance and understand why a different route may ask less of them.
The prototype tests that interaction using real Seattle network data.

The native client is SwiftUI, with a small `UIViewRepresentable` bridge to
MapLibre Native. A local Swift package owns routing, estimates, comfort costs,
place search, and request lifecycle. Both display and routing use bundled OSM
data, so the actual app needs no network, API key, account, or location prompt.

Valhalla and GraphHopper are stronger starting points for production routing.
For this local, inspectable slice, installing a daemon/container, configuring
regional tiles, and bridging custom cost models would have added more operational
surface than the experience needed. The small owned router makes the preference
and budget behavior executable and reviewable now. `RouteComputing` is the
replaceable boundary for a later self-hosted routing service. This choice is not
a claim of parity with mature routing engines.

## Data boundaries

`Scripts/import_osm.py` compiles the preserved Overpass responses into a graph
and display GeoJSON. Routing segments retain full geometry, OSM way IDs, names,
road classes, mode permissions, surfaces, posted speed text, incline text, and
direction-specific cycleway tags. Shared nodes, signals, barriers, endpoints,
and restriction nodes split segments. The app never infers missing attributes
as facts. Places use OSM node coordinates or simple means of feature vertices;
they are not verified entrances.

The compiler applies an explicit conservative policy:

- Mode-specific access overrides general access; unknown access values,
  private/customer/destination access, and conditional access are excluded.
- Driving excludes non-road paths and driveway/parking-aisle service roads.
- Cycling excludes motorway/trunk roads and footways/paths without an explicit
  bicycle permission. This deliberately omits some locally legal paths.
- One-way direction, reverse one-way, roundabouts, bicycle exemptions, and
  opposite-cycleway tags are handled. Reversible/unknown one-way tags are excluded.
- Simple via-node `no_*`/`only_*` restrictions, per-mode variants, and exceptions
  are compiled. Via-way, conditional, and unsupported relevant restrictions
  conservatively remove their involved ways for that mode. They are listed in
  `Data/provenance.json` rather than silently ignored.
- Explicit access barriers are respected under the compiler's documented policy.
  A mapped cycle barrier does not prove that a particular bicycle can pass it.

Routing remains incomplete: lane-specific maneuvers, vehicle dimensions,
conditional schedules, construction, seasonal closures, traffic, ferry routing,
turn-protection phases, complex intersection rules, and many access subtleties
are not modeled. Missing OSM restrictions can still produce infeasible routes.

## Routing and budget

`NativeRouter` uses an incoming directed edge as its Dijkstra state. This keeps
turn restrictions and turn costs dependent on how a junction was entered. It
prohibits immediate U-turns. The time-only route is the shortest modeled time
within this graph and access policy, not the fastest route in the real city.

Place coordinates snap to nodes on the largest strongly connected component
for the mode, within 400 m and off highway segments. Kosaraju's algorithm finds
that component at router initialization. This prevents an isolated campus loop
from winning merely because it is closest. Turn restrictions are still checked
during search. Snapping can select the wrong side of a physical barrier; endpoint
gaps are not routed, are excluded from ETA, and are disclosed in the UI.

Six additional searches minimize `estimated seconds + weight × comfort cost`,
using weights 0.15, 0.4, 1, 2.5, 6, and 15. Distinct candidates are compared using
their exact seconds. A calmer candidate must fit `fastest seconds + budget × 60`
and reduce comfort cost by more than 2%. Lowest cost wins; time breaks ties.
This candidate search does not prove the global optimum under a time constraint.
No extra time searches only the fastest route. No suitable candidate is an
ordinary first-class result. Displayed minutes round up; filtering never does.

## Transparent preference costs

Driving costs per km: residential 65, service 100, highway 35, other road 12.
Transitions add 22 per turn, 65 per arterial left, and 180 per highway entry.
Residential penalties discourage routing through neighborhoods as a shortcut.
Turns use a greater-than-35° angle at a change of OSM way. Segmentation and OSM
classification influence these proxies. An arterial left does not mean an
unprotected turn; a highway entry does not establish merge difficulty or a
one-exit detour. Those limitations are visible in the explanation screen.

Cycling costs per km: cycleway/track tags 8, shared path 20, lane 32,
residential 35, arterial 140, other 65. Rough-surface tags add 55/km;
unknown surface adds 8/km. Turns add 6 and arterial lefts add 25. Track tags
are directional; shared paths are kept distinct. Grade tag coverage is reported
but not scored because this slice has no reliable elevation model. No route
is given a safety score or label.

Times use assumed class speeds and simple junction delays. Driving caps a class
assumption at 80% of a parsed posted speed when available. Cycling assumes
18 km/h, 14 on shared paths, 11 on tagged rough surfaces. There is no calibration
or live traffic. Signals add 12 seconds driving / 8 cycling; turns add 5 / 2.
These constants are hypotheses, exposed in code for review, not empirical ETAs.

## UI and lifecycle

`ExploreView` owns places, mode, time budget, selected comparison, and one sheet
enum. `RouteSession` owns mutually exclusive idle/loading/ready/error/cancelled
states. Every start cancels the prior task and advances a generation token.
Only the current generation can publish. The router runs off the main actor;
its Dijkstra loop checks cancellation. There are no background route changes,
location updates, or automatic rerouting.

`SeattleMap` keeps rendering separate from route selection. Its Swift concurrency
bridge marks the MapLibre delegate as a main-actor, preconcurrency conformance
because the Objective-C protocol predates actor annotations. Static OSM sources
load once; route shapes update on comparison changes. Explicit text beneath the
map duplicates the decision information for accessibility. Search uses stable
OSM IDs and a small curated initial set of public places; typed queries go to
`SearchIndex`, an SQLite FTS5 index of OSM places and addresses inflated into
Caches on first launch (see `Docs/SEARCH.md`).

## Next architectural decision

Keep the client and explanations; compare the current router against a local
Valhalla/GraphHopper instance with a Seattle extract. Evaluate route legality,
intersection maneuvers, and sensitivity to the stated time allowance before
calibrating preferences or expanding geography. Keep optional commercial place
enrichment behind a separate place-details interface. It must not influence
route scoring, candidate ordering, or sponsored search placement.
