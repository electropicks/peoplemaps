# Stress model: walk, bike, drive

Implemented 27 October 2026 in `Core/StressModel.swift`, with data from
`Scripts/import_osm.py`. Differences from the first draft: walking has no
per-turn cost (sidewalk geometry makes turn counts noise), and the whole-route
factors (stop-and-go clusters, short freeway hops, side-street shortcuts) are
scored on each candidate but are not visible to the search itself.

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

- **Hill starts matter to me** (manual or weak car): grade-stop costs x3.
- **Steady over fast**: stop-and-go costs x2, for people who strongly prefer
  never stopping.

## Bike

Built on Level of Traffic Stress (LTS), the standard method from Mekuria,
Furth and Nixon (2012). It rates each street 1 to 4 from lanes, speed, bike
facility and parking. Seattle's OSM data has the inputs: lanes (99%), maxspeed
(98%), cycleway tags (54% of arterials) and parking (about 35% of arterials).

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
| Signal | 8 | Expected cost |
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

## Choosing and explaining routes

- **Use every best trade-off, not six fixed weights.** For each trip, compute
  the routes where you can't get less stress without more time (the Pareto
  frontier). The extra-time control moves along that curve instantly.
- **Budget in minutes or percent.** The thread asked for a "least complicated"
  button within about 125% of the fastest time. Offer both.
- **Real alternatives only.** A calmer route must differ meaningfully in path,
  not just one block.
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
