# Stress model: walk, bike, drive

Implemented 27 October 2026 in `Core/StressModel.swift`, with data from
`Scripts/import_osm.py`. Differences from the first draft: walking has no
per-turn cost (sidewalk geometry makes turn counts noise), and the whole-route
factors (stop-and-go clusters, short freeway hops, side-street shortcuts) are
scored on each candidate but are not visible to the search itself. Drive times
were recalibrated on 31 October 2026 against a real trip (see Time).

## What we are optimizing

PeopleMaps picks the route a local would pick: the one that asks the fewest
hard decisions of you, not the one that saves the most seconds. The origin is
an r/SeattleWA thread ("the fastest route and the least annoying route are two
completely different things"), whose author put it best: choose the route that
"requires the fewest decisions."

Stress means something different in each mode, so each mode has its own model:

| Mode | What makes a trip stressful |
| --- | --- |
| Drive | Stop-and-go, and gaps you have to judge: unsignalled lefts and crossings of busy roads, merges, weaving, confusing junctions, hill starts |
| Bike | Sharing space with fast or heavy traffic, crossing busy roads, climbing, stopping and restarting |
| Walk | Crossing busy roads without a signal, walking beside traffic or with no sidewalk, hills and stairs |

## Rules that apply to every mode

1. **Stress is not safety.** We never call a route safe, dangerous or risky.
   We say what the route asks of you ("2 unsignalled crossings of Aurora").
2. **Unknown is not zero.** A missing tag gets a moderate default cost, and the
   explanation says the value was estimated. A missing tag never becomes a fact.
3. **Costs are hypotheses.** Every weight below is a starting guess, written
   down so it can be argued with and later fitted to what locals actually choose.
4. **One unit.** Every cost is in *equivalent seconds*: roughly how many seconds
   of extra travel a typical local would accept to avoid it. A 120 s cost on an
   unsignalled left means "most people would rather drive 2 minutes longer than
   make this turn." This keeps the weights readable and lets us explain them.
5. **Two kinds of cost.** *Events* happen at a point (a turn, a crossing, a
   stop). *Exposure* accrues per kilometre (riding beside traffic, walking with
   no sidewalk). Route stress = sum of events + sum of exposure.
6. **Time stays honest.** Stress never changes the time estimate. Time has its
   own model (speeds, signal delay, and grade for bike and walk).

## Time

Time has its own model, `seconds(_:mode:)` and `transitionSeconds` in
`Core/StressModel.swift`. Stress never changes it. Every number here is an
estimate: there is no live traffic, signal timing, bridge schedule or time of
day, and the UI says so.

### Drive

Each edge is driven at a free-flow speed, and every junction charges its
slowdown once. The speed carries no urban factor; signals, stops and turns are
what slow a Seattle driver down, and they are counted where they happen.

| Road | Free-flow speed (mph) | Note |
| --- | --- | --- |
| Any road with a posted limit | the posted limit | 99.5% of non-service drive edges (89% of all drive edges) have `maxspeed`; Seattle posts 25 on arterials and 20 on residential streets |
| motorway | 60 | the cap, see below |
| motorway_link | 35 | any ramp (`*_link`) is capped at 40, even where tagged with the freeway's limit |
| trunk | 40 | Aurora |
| trunk_link | 30 | |
| primary, secondary, tertiary and their links | 25 | the citywide arterial limit |
| residential, unclassified | 20 | the citywide residential limit |
| living_street, service | 10 | alleys, parking aisles |
| anything else drivable | 15 | |

| Junction | Delay (s) | Reasoning |
| --- | --- | --- |
| Signal | 15 | Expected value: red about half the time, for an average wait near 30 s |
| All-way stop | 10 | Stop, then take turns |
| Stop sign | 8 | A full stop and restart |
| Yield | 3 | |
| Unsigned cross street when leaving a local street (4 or more legs) | 3 | The residential grid mostly has no signs; you slow to look, and to yield to the right |
| Turn (over 35° onto another way) | 5 | Slowing through the corner |

**Why this table.** The first model had the same shape but double-counted.
Its class table (motorway 70, trunk 50, primary 35, secondary 32, tertiary 28,
residential 22, service 12) read like mph but was divided by 3.6, so it was
km/h; posted limits were multiplied by 0.8 and then capped by that table; and
the junction delays were added on top. Aurora (40 mph posted) came out at
31 mph, a 25 mph arterial at 20 mph and a 20 mph residential street at 14 mph.
A real trip on 31 October 2026, 3rd Ave NW and NW 43rd St to Bell St in
Belltown, took 10 minutes door to door; the old model estimated 12 minutes for
its fastest route (19 mph average) and 14 for the calmer one. The new table
gives 10.5 minutes (21 mph average, 9 signals, 11 turns) without any trip
being special-cased. Across the four audited drive trips, estimates fell by 9
to 17 percent and three of the four fastest routes changed: with speeds at the
posted limit and junctions dearer, the search now prefers through roads with
fewer stops, which is also what a local does. Kerry Park to Gas Works now
runs over the Fremont Bridge instead of Aurora, and no other route the search
finds gains enough to offer.

**The top speed.** No drive edge is timed faster than `StressModel.driveTopMph`, 60, and `NativeRouter`'s A* heuristic reads
its bound from the same constant, so the search stays exact if it changes. It was 43 mph (70 km/h) while the heuristic
was hard-coded. 60 is the posted limit on I-5 and most of the county's freeways; rural 55 mph highways are no longer
capped. 70 mph was tried on the county sample and changed no more routes. Ramps are capped at 40 (`driveRampMph`): tagged
links inherit the freeway's limit (65% of tagged Eastside links say 60), which is wrong for a ramp. Free flow only:
I-405 at rush hour is slower than this says.

Measured on a Mac (shared, load about 7), 200 seeded random trips each from the all-Seattle and King County graphs
(`peoplemaps-bench --sample`). Walk and bike are untouched (0 routes change).

| Drive, fastest route | Before (43.5) | After (60) |
|---|---:|---:|
| Seattle sample, routes whose fastest route changes | | 34 of 196 |
| Seattle sample, time change | | p50 -2.9%, p5 -16.1% |
| County sample, routes whose fastest route changes | | 72 of 191 |
| County sample, time change | | p50 -11.9%, p5 -20.4% |
| Issaquah to Renton | 28.5 min, stress 668, 26.6 km | 23.6 min, stress 168, 29.7 km |
| Kirkland to Renton | 27.8 min, stress 874 | 23.1 min, stress 374 |
| Federal Way to Bothell | 53.7 min | 42.7 min |
| Ballard to North Bend | 59.0 min | 48.4 min |
| Ballard to Bellevue | 28.2 min | 26.6 min |

Issaquah to Renton: the freeway route that was the "calmer" alternative is now the fastest, so no calmer route is offered
there. The golden fixture changed for two drive entries only (the long trip, both budgets: 790.9 s to 757.2 s); every walk
and bike entry and the other 35 drive entries are unchanged.

**A worse calmer route on one golden trip.** In the long fixture trip at the 5 minute budget the calmer route went from
811.7 s, stress 441.6 to 975.2 s, stress 519.2. The old route is still there and, re-timed under the new speeds, is
unchanged (it is all surface streets: 811.7 s, stress 441.6), so it beats the new one on both. The search
doesn't return it because it can't see the whole-route factors (`pathFactors`: stop-and-go clusters, short freeway hops,
side-street shortcuts): the new calmer route carries 15 stop-and-go stops (150 s) that only show once the route is
finished, so for weights 4 and 8 it looks cheaper to the search (975 + 369w) than the old one (812 + 431w). The 60 mph cap
didn't cause the gap, it moved which routes the six weights land on. It is the limit described under "Whole-route factors
steer only the final choice" below, not a selection bug, and it isn't fixed here. Across the 200 sampled trips, 8 of 183
Seattle and 15 of 167 county drive trips (offered a calmer route both before and after) show a higher calmer-route stress
than before; only 1 and 3 of them also take more extra time. These are upper bounds, since the fastest route changed too.

**Not in the estimate.** Traffic queues, signal coordination, waiting for a
gap on an unsignalled left (charged as stress, not time), bridge openings and
finding parking. Each would need data the app does not have offline; the first
is the one most worth adding when real arrival times are recorded.

### Bike

18 km/h on streets, 14 on shared paths, 11 on tagged rough surfaces, plus
about 3 s per metre climbed and a little back on descents, never faster than
32 km/h. Signals add 8 s, stop signs 3, yields 1, turns 2. Checked on
31 October 2026: these are km/h as intended, so bike times were left alone.

### Walk

1.4 m/s on the flat plus 2.5 s per metre climbed, close to Tobler's hiking
function for city grades; 0.6 m/s on steps. A signalled crossing of anything
busier than a side street waits 25 s. Unchanged.

## Drive

Built from the complaints in the thread. "Arterial" means OSM
`primary`/`secondary`/`tertiary`, which in Seattle tracks SDOT's arterial map.
"Busy arterial" means 4 or more lanes or a posted speed of 35 mph or more.

### Events

| Factor | Cost (s) | Evidence in the Seattle data | Source of the idea |
| --- | --- | --- | --- |
| Left turn onto or across an arterial, no signal | 120 (busy: 180) | Signals are on junction nodes (516) | "technically legal but spiritually forbidden" |
| Straight across an arterial from a side street, no signal | 90 (busy: 150) | Same | "cut straight across Rainier, MLK, Denny" |
| Right turn onto an arterial, no signal | 15 | Same | Merging into a gap, but a smaller one |
| Left at a signal without a left-turn lane | 30 (with lane: 10, unknown: 20) | `turn:lanes` on 32% of arterial ways | Turn protection itself is not in OSM |
| Any turn or change of road (a "decision") | 8 | Geometry and way names | "fewest decisions" |
| Junction with 5 or more legs | +40 | 44 in the extract | "weird five-way intersections" |
| Stop or signal on a grade over 8% | 30 (over 12%: 60) | **Needs elevation data** | Hill starts in a manual or a weak car |
| Freeway entry | 30 | Road class | |
| Freeway exit less than 2 km after entering | +90 | Road class and distance | On at Mercer, weave across, off at James |
| Movable bridge | 30 | 10 bascule ways: Fremont, Ballard, University, Montlake | Openings are unpredictable; no schedule data |

### Exposure

| Factor | Cost (s/km) | Evidence | Note |
| --- | --- | --- | --- |
| Residential street when a through road exists | 30 | Road class | Narrow streets, driveways, parked cars |
| Leaving a road and rejoining it soon after | +60 per detour | Way names along the route | The thread's "save four minutes" shortcut |
| Narrow two-way street with parking both sides | +40 | `lanes` 99%, parking tags on about 35% of arterials | "two lanes into 1.3 lanes" |

Freeways and arterials carry no per-km stress. Driving on a big road isn't
the problem; getting on, off and across it is. That's the opposite of the
current model, which charges 35/km for highways and 65/km for residential.

### Whole-route factors steer only the final choice

Stop-and-go clusters, short freeway hops and side-street shortcuts (`StressModel.pathFactors`) are counted once a route
is finished, because they depend on the stretch of road before them. The A* search only sees per-edge exposure and
per-junction events, so these can't steer it. They do count in the totals that `selectCalmer` and the "nothing calmer"
finding compare, and in the rating. The effect is that a route can look cheaper to the search than it turns out to be,
and a better route may not be among the seven it finds. Don't read any of these factors as something the router
avoids; it only prefers a candidate that has less of them.

### Stop-and-go

A core factor, not an option. Several commenters would take a slower route
that keeps moving over a faster one that stops and starts: 99 or 4th Ave
instead of I-5, Juanita Drive instead of 520, "70, 0, 20, 0, 50 for an hour."
Every stop is a small decision and a small irritation, and they add up.

What we can see offline is *control* stops: signals, stop signs and yields.
Traffic queues are not in the data, so congestion stop-and-go stays an
admitted unknown.

| Factor | Cost (s) | Evidence | Note |
| --- | --- | --- | --- |
| Stop sign facing you | 15 | 896 stop nodes, 780 with direction | You always stop |
| All-way stop | 20 | 132 marked `stop=all` | Stop, then negotiate who goes |
| Signal | 10 | 516 signal nodes | Expected cost: you stop at some, not all |
| Yield onto a busier road | 8 | 28 `give_way` nodes; also implied at unsignalled junctions | |
| Clustered stops: 3 or more within 400 m | +10 for each beyond the second | Node spacing along the route | The "stop, go, stop" stretch is worse than the same stops spread out |

The time model already adds a signal delay. These costs are on top of that:
they price the irritation of stopping, not just the seconds lost.

Applied together, a route with no stops for 3 km beats one with 8 stops in the
same distance by about 100 equivalent seconds, even at equal time.

### Optional preferences (later)

- **Hill starts matter to me** (manual or weak car): now the Hills preference
  (see [Preferences](#preferences)), which scales hill stops x3.
- **Steady over fast**: stop-and-go costs x2, for people who strongly prefer
  never stopping. Not built yet: stop-and-go is scored only on finished routes.

## Bike

Built on Level of Traffic Stress (LTS), the standard method from Mekuria,
Furth and Nixon (2012). It rates each street 1 to 4 from lanes, speed, bike
facility and parking. Seattle's OSM data has the inputs: lanes (99%), maxspeed
(99.5% of non-service drive edges), cycleway tags (54% of arterials) and parking (about 35% of arterials).

### Exposure

| Segment | Cost (s/km) | Examples |
| --- | --- | --- |
| LTS 1: trail, protected track, cycleway | 0 | Burke-Gilman, Westlake cycle track |
| LTS 2: quiet residential street, greenway, bike lane on a slow 2-lane street | 60 | Neighbourhood greenways |
| LTS 3: bike lane on a busier arterial, mixed traffic on a 2-lane arterial | 240 | |
| LTS 4: mixed traffic on a 4-lane or fast arterial | 600 | Aurora, Mercer |
| Rough surface | +60 | `surface` on 70% of roads |
| Unknown surface | +5 | Flagged in the explanation |

### Events

| Factor | Cost (s) | Note |
| --- | --- | --- |
| Crossing an arterial without a signal | 60 (busy: 150) | LTS crossing rules |
| Left turn on an arterial without a signal | 90 | At a signal: 15 |
| Leaving a bike facility onto a street with no facility | 20 | Network gaps |
| Stop sign | 10 | Stopping costs a cyclist momentum, more than it costs a driver |
| Signal | 14 | Waiting at a red beside traffic, then pulling away from it. Dearer than a stop sign (10), which is a quick stop and go. Stress only: the time estimate still adds 8 s |
| Stop or signal on an uphill grade over 6% | +20 | **Needs elevation data**; restarting uphill is the worst kind of stop |
| Turn (a decision) | 4 | |
| Movable bridge | 15 | |

### Hills

| Factor | Cost | Note |
| --- | --- | --- |
| Climbing | 4 s per metre of ascent | **Needs elevation data** |
| Steep descent (over 8%) in mixed traffic | 20 s per 100 m | Speed and braking near cars |

Hills also slow the time estimate, using a grade-aware speed. This is what
fixes Kerry Park → Gas Works, where the current "fastest" bike route goes over
the top of Queen Anne hill.

## Walk

Walking is new: today's importer drops the pedestrian network. Seattle's OSM
walking data is unusually complete: 23,006 mapped sidewalks, 10,086 crossing
ways, 14,647 crossing nodes (1,740 signalled, 1,193 marked, 8,280 unmarked)
and 1,281 stairways.

Routing on the real sidewalk-and-crossing network makes the router weigh
"walk half a block to the signal" against "cross here" by itself.

### Events

| Factor | Cost (s) | Note |
| --- | --- | --- |
| Unmarked crossing of an arterial | 90 (busy: 180) | |
| Marked crossing of an arterial with no signal | 45 | |
| Signalled crossing | 10 | Wait time goes into the time estimate, not stress |
| Crossing a residential street | 3 | |
| Turn (a decision) | 2 | |

### Exposure

| Factor | Cost (s/km) | Note |
| --- | --- | --- |
| Sidewalk beside an arterial | 60 | Noise and traffic |
| Sidewalk beside a residential street, path or trail | 0 | |
| Road with no sidewalk: residential | 30 | |
| Road with no sidewalk: arterial | 400 | |
| Sidewalk status unknown | 20 | Flagged in the explanation |
| Climbing | 2 s per metre of ascent | **Needs elevation data**; time uses Tobler's hiking function |
| Stairs | 1 s per step (estimated from length if not tagged) | Impassable under a step-free preference |

### Optional preferences (later)

- **Step-free** (stroller, wheelchair, luggage): no stairs, penalise steep grades.
- **Pleasant**: favour parks, trails and waterfront. Applied as a lower cost
  on those segments, never negative.

## Preferences

Implemented in `Core/RoutePreferences.swift`. What "calmer" means differs
between people: after riding the first routes, cyclists and walkers said they
barely mind stop signs but do mind traffic lights (long waits), drivers hate
lefts across traffic, and some people want the fewest stops of any kind, or no
hills, or no busy streets. Preferences let each person turn a few groups of
factors up or down, per mode, on top of the weights above.

### Options and the factors they scale

Each option has three levels. **Avoid** multiplies its factors' costs by 3,
**Don't mind** by 0.3, and **Normal** leaves them as they are. An option is
offered only in a mode that has at least one of its factors.

| Option | Drive | Bike | Walk |
| --- | --- | --- | --- |
| Traffic lights | `signal` | `signal` | `signalCrossing` |
| Stop signs | `stopSign`, `allWayStop` | `stopSign`, `allWayStop` | not offered |
| Left turns across traffic | `unsignalledLeft`, `leftAtSignal` | `unsignalledLeft`, `leftAtSignal` | not offered |
| Busy streets | not offered | `arterialRiding`, `busyArterialRiding`, `bikeRouteGap` | `besideTraffic` |
| Busy crossings without a signal | `unsignalledCrossing` | `unsignalledCrossing` | `unmarkedCrossing`, `markedCrossing` |
| Hills | `hillStop` | `climb`, `steepDescent`, `hillStop` | `climb`, `stairs` |
| Turns | `turn` | `turn` | not offered |

Choices behind the mapping:

- **Lefts at signals count as lefts across traffic.** The map doesn't record
  arrow phases, so a left at a signal may well be a permissive green. They
  keep their smaller base cost (10 to 30 s), so Avoid still mostly removes
  the unsignalled ones.
- **Driving has no Busy streets option.** The drive model charges nothing for
  being on an arterial (getting on, off and across them is what it prices), so
  there is nothing to scale. Avoiding unsignalled crossings and lefts is how a
  driver steers away from busy roads.
- **Walking has no Stop signs, Lefts or Turns.** Walkers don't stop at stop
  signs, and walking has no per-turn cost.
- **Stairs are a hill for walkers**: the people who avoid hills (strollers,
  sore knees, luggage) avoid steps too. A strict step-free mode is still later.
- **Not scaled:** stop-and-go clusters, freeway hops and side-street shortcuts
  (scored only on finished routes), yields, rights into traffic, five-way
  junctions, freeway entries, drawbridges, residential and narrow streets,
  rough surfaces, and unknowns. "Fewest stops of any kind" is Avoid on both
  Traffic lights and Stop signs.

### Multipliers

| Level | Multiplier | Why |
| --- | --- | --- |
| Avoid | x3 | Enough to move the factor ahead of most others in the same mode (a bike signal at 8 s becomes 24 s, above a stop sign at 10 s and close to a 20 s bike route gap), without one option swamping the time budget, which still caps every calmer route. |
| Normal | x1 | The model as described above. |
| Don't mind | x0.3 | Close to ignoring the factor, but not zero: a route with 10 extra stop signs still loses to an equal one without them. |

How they were tuned: 40 trips between bundled places 1.5 to 6 km apart, in
every mode with a 5-minute budget, each offered option set to one level at a
time (680 runs per level), compared with the default route shown:

| Multiplier | Route changed | Option's amount on the shown routes | Runs where it went the wrong way |
| --- | --- | --- | --- |
| Avoid x2 | 43% | -17% | 15 |
| **Avoid x3** | 54% | -26% | 9 |
| Avoid x5 | 66% | -41% | 6 |
| Don't mind x0.5 | 39% | +23% | 13 |
| **Don't mind x0.3** | 48% | +43% | 12 |
| Don't mind x0 | 61% | +106% | 11 |

Average travel time moved by less than 10 s at every setting. x2 was too
timid (most trips unchanged), x5 starts to override the rest of the model.
Don't mind at 0 makes the factor free, so routes collect them for a second
saved; 0.3 still breaks ties toward fewer.

"Wrong way" means, for Avoid, the shown route has more of that option's
factors than the default one. It happens on about 1 run in 75, for two
reasons: the six searches sample a different set of routes once the weights
change, so the default route may not be among the candidates; and options
that group factors (Hills is climbing and steps) can trade one for the other.
Four of the nine at x3 differ by under 0.5% (metres of climb or of sidewalk
beside traffic). The tests pin trips where each option clearly works.

### Defaults

`RoutePreferences.default(for:)` is Normal for every option in every mode, and
reproduces the routes exactly as before preferences existed (checked against
`Evidence/route-audit.json`). Each mode's defaults are the per-mode weights in
the sections above, which already encode what a typical local minds in that
mode: a cyclist's stop sign (10 s) costs more than a signal (8 s) because
restarting costs momentum, and a walker's signal costs only 10 s because the
wait is already in the time estimate. Changing those weights is a model change
to be argued with evidence, not a preference.

### How the router uses them

- Only the calmer search reads preferences. The fastest route stays the pure
  time estimate, and the extra-time budget still applies.
- Multipliers are resolved once per request. Per-edge exposure is precomputed
  per mode with each option's share stored separately, so a request rescales
  only the edges an option touches; junction costs are scaled as they are
  recorded. With defaults the search takes exactly the old code path.
- Avoid makes every search weigh stress more, so even the lightest weight
  (0.25) can detour past the budget. When no candidate fits the budget, the
  router tries weights 0.125 and then 0.0625 before giving up.
- The calmer route is chosen by stress as this person weighs it, and the
  reasons are ranked the same way, so an avoided factor ranks higher. Every
  count, distance and cost in `Breakdown` stays the model's real value.
- Latency (release build, 12 trips x 2 rounds, 5-minute budget): defaults
  unchanged within noise. One option on Avoid costs 0 to 9% more per request,
  because a heavier stress term makes A* settle more states; the most were
  walk Hills (+9%), bike Busy streets (+9%) and drive Traffic lights or Lefts
  (+9%). Two exposure options together on walk reached +10 to 14%.
- Stored as JSON listing only changed options, for example
  `{"trafficLights":"avoid","hills":"dontMind"}`. Option and level names are
  stable keys; unknown ones are skipped when reading.

## Choosing and explaining routes

### What ships

Changed on 1 November 2026, after the owner's call: the target audience would
often add 5 to 10 minutes for a calmer route, so bias for calm.

**Search.** One fastest search, then six searches minimizing `seconds + weight ×
stress` at weights 0.25, 0.5, 1, 2, 4 and 8. The extra-time limit does not bound
or steer these. It only filters their results afterwards, so 2, 5 and 10 minutes
cost the same router time; "None" runs the fastest search alone.

**Selection** (`NativeRouter.selectCalmer`). A candidate can be the calmer route
when it is a different route from the fastest, fits the limit (default 10
minutes), has at least 5% and 30 equivalent seconds less stress, and removes more
than 15 equivalent seconds of stress per extra minute. Of those, the one with the
most `stress saved − 0.25 × extra seconds` wins.

**Nearly identical routes count.** The owner's call: "yes show them, the goal is
that users trust that the route were giving them is the best option even if its
exactly the same as the fastest route." A rule that hid any route sharing 90% of
its length with the fastest is gone, because one block can be the whole point:
DIY Tea Lab to Lassi and Spice by car shares 96% with the fastest route, costs
seconds, and takes stress from 668 to 366.

**When no calmer route qualifies** (`NoCalmerFinding`), the preview says what the
router knows, and only that. "Calmest" is claimed only when no route it compared
has less stress.

| What the router saw | Title | Detail | Sampled trips, drive / bike / walk |
| --- | --- | --- | ---: |
| Extra time is None, so only the fastest search ran | Fastest route only | Extra time is None, so nothing else was checked. | not in the sample |
| All six calm-weighted searches found this route | Already the calmest we found | By our estimates, every search found this route. | 7 / 3 / 0 |
| Other routes compared, none with less stress | Already the calmest we found | Calmest of N routes compared, by our estimates. | 3 / 0 / 0 |
| Less stress exists, but only beyond the limit | Calmest we found within this extra time | By our estimates, calmer routes take N+ min more. | 0 / 0 / 0 |
| Less stress exists inside the limit, but under the floors or not worth its time, and nothing beyond the limit clears them | Best balance we found | By our estimates, other routes gain too little. | 4 / 3 / 2 |
| Too little gain inside the limit, but a route beyond it clears the floors and the price | Best balance within this extra time | By our estimates, a clearly calmer route takes N+ min more. | 0 / 0 / 0 |

The last row needs a limit shorter than the sample's 10 minutes: Kerry Park to
Gas Works by bike says it at 2 and 5 minutes, and offers the route at 10.

These describe the candidates only. The search does not prove no calmer route
exists, and the Why this route sheet says so.

**What the app shows first.** When a calmer route exists the preview lists it
first and selects it, resetting on every new request, and Start follows the
selection. This already leaned calm and did not change, including for routes
that cost only seconds. The place card's Directions button shows the route Start
would take: "Calmer: 12–14 min, 3.4 mi" over "Mixed → Breezy, mostly fewer
unsignalled lefts", or the fastest route and what the router found when there is
no calmer one.

**Why the 15 per minute.** The limit is a maximum, not a target, and the old rule
took the least stressful candidate inside it however little that last stretch
bought. At 10 minutes that means paying for scraps: Ballard Library to Hyson by
car would go from 2 extra minutes at stress 848 to 5.6 extra minutes at stress
828. Rule 4 prices one equivalent second at one second, so a neutral rate would be
60 per minute; 15 is the bias for calm. An unsignalled left (120) can justify up
to 8 extra minutes here, against 2 in the model alone, which fits the owner's 5
to 10. Netting the time, rather than only filtering on it, is what stops a slower
route winning when a nearly-as-calm quicker one exists. Like every weight here,
15 is a hypothesis.

Measured on 150 seeded random pairs of bundled places, in each mode. Extra time
is for trips that show a calmer route; stress saved is against the fastest route.

| Mode | Rule, limit | Calmer shown | Extra min, median / p90 / max | Stress saved, median |
| --- | --- | ---: | ---: | ---: |
| Drive | old, 5 min | 126 | 1.5 / 3.0 / 4.6 | 335 (44%) |
| Drive | old, 10 min | 126 | 1.7 / 3.7 / 8.0 | 343 (45%) |
| Drive | **new, 10 min** | 136 | 1.3 / 3.0 / 8.0 | 313 (44%) |
| Bike | old, 5 min | 142 | 2.1 / 4.4 / 5.0 | 908 (49%) |
| Bike | old, 10 min | 143 | 3.3 / 8.4 / 9.5 | 1016 (54%) |
| Bike | **new, 10 min** | 144 | 2.9 / 8.1 / 9.3 | 1016 (53%) |
| Walk | old, 5 min | 146 | 3.3 / 4.6 / 5.0 | 504 (50%) |
| Walk | old, 10 min | 148 | 5.7 / 9.0 / 10.0 | 639 (59%) |
| Walk | **new, 10 min** | 148 | 5.1 / 8.4 / 9.7 | 639 (59%) |

"Old" is the least stressful candidate, with the 90% overlap rule; "new" is the
rule above. Dropping the overlap rule adds 10 drive trips and 1 bike trip, and
changes the pick on 4 more drives. The drive median falls because those added
trips often save less, not because any trip got worse.

Against the old rule at 10 minutes, the new one keeps nearly all the extra calm
for less time: mean stress change from the old 5 minute default of −18, −107 and
−99 (drive, bike, walk) rather than −6, −108 and −104, at a mean of 0.12, 1.47
and 2.02 extra minutes rather than 0.24, 1.68 and 2.50. Trips that end up less
calm than the old default give up at most 39 equivalent seconds. A limit beyond
10 adds little: at 20 minutes under the old rule, drive is unchanged, bike saves
54% either way, and walk goes from 59% to 65% for 2.6 more minutes at the median.
`Evidence/route-audit.json` (`peoplemaps-audit`) has per-trip numbers.

### Calm score

What people see instead of stress numbers (`Core/CalmScore.swift`). The 15 per
minute price stays internal.

`score = 100 / (1 + (rate / R)²)`, rounded, higher is calmer, where `rate` is
stress per minute of the fastest route's time, with a 5 minute floor. Both routes
in a comparison divide by the same time, so a route can't look calmer just for
being slower, and the floor stops one left turn on a two minute trip from reading
as Yikes. Stress means different things per mode, so R is per mode: **drive 50,
bike 65, walk 12**, about where a typical fastest route lands in Spicy to Mixed.

| Level | Breezy | Chill | Mixed | Spicy | Yikes |
| --- | --- | --- | --- | --- | --- |
| Score | 80+ | 60–79 | 40–59 | 20–39 | under 20 |

The cutoffs are even so the bar's bands can be even, with no number axis. R was
set on real trips: 150 seeded pairs in each mode, 10 minute limit
(`peoplemaps-audit --calm-sample 150`). Counts below are Breezy / Chill / Mixed /
Spicy / Yikes.

| Mode | Fastest | Calmer, where shown | Same level | Same score |
| --- | --- | --- | ---: | ---: |
| Drive | 3 / 18 / 42 / 73 / 14 | 13 / 71 / 37 / 6 / 0 (127) | 11 | 0 |
| Bike | 2 / 4 / 35 / 100 / 9 | 18 / 69 / 48 / 9 / 0 (144) | 23 | 0 |
| Walk | 9 / 8 / 29 / 81 / 23 | 54 / 68 / 23 / 2 / 0 (147) | 12 | 0 |

All five levels get used. Fastest routes skew Spicy and calmer ones Chill, which
is the point of the app; no calmer route landed in Yikes or scored worse than its
fastest. When both share a level the summary shows scores ("Mixed, 44 → 53"). Like
the weights, R and the cutoffs are hypotheses: the score only knows what the map
knows, so it is labelled an estimate.

The time range is −5% to +12% of the estimate, a judgement call with no live
traffic to measure against, not a measured spread.

### Still to consider

- **Use every best trade-off, not six fixed weights.** For each trip, compute
  the routes where you can't get less stress without more time (the Pareto
  frontier). The extra-time control moves along that curve instantly.
- **Budget in minutes or percent.** The thread asked for a "least complicated"
  button within about 125% of the fastest time. Offer both.
- **Say the trade both ways.** Show the 2 or 3 biggest differences, benefits
  and costs together: "Avoids 2 unsignalled lefts on Aurora · +3 min · 1 more
  turn." Each factor says whether it came from map data or was estimated.

## Data we need

| Need | Status |
| --- | --- |
| Signals, stop signs, lanes, maxspeed, turn lanes, parking, cycleway, surface, bridges | In the raw OSM data; the importer keeps only some of it |
| Pedestrian network: sidewalks, crossings, stairs | In the raw OSM data; the importer drops it |
| Elevation | Not in OSM (only 9 roads have `incline`). Bundle a public-domain DEM from USGS 3DEP and sample it along each segment |
| Traffic, signal timing, turn-arrow phases, bridge opening times | Not available offline. Stays disclosed as unknown |

Found while checking the data: the importer counts any `highway=traffic_signals`
node as a signal, including `traffic_signals=emergency` (a fire-station signal
that is normally dark), such as the one at Linden Ave N and N 38th St. Those
should not count as signals.

## How we'll check it

- **Thread test cases inside the bundled area.**
  - The stop-controlled five-way at Queen Anne Dr / 4th Ave N / Raye St, about
    200 m from Canlis. Probably the hill five-way from the thread; confirm.
  - The Aurora on-ramps next to it.
  - The Fremont Bridge.
  - The Kerry Park → Gas Works drive and bike routes.
- **Sanity checks.** Show the top cost contributors for a route and confirm a
  local would name the same pain points.
- **Fitting later.** Show locals pairs of routes, record which they'd take, and
  fit the weights to those choices. Until then, the weights stay labelled as
  hypotheses.
