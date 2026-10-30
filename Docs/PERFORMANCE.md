# Router performance

How long a route takes, what it costs in memory, and the budgets we hold it to. Measured with `peoplemaps-bench` (`Bench/`), which supersedes `Scripts/coverage_bench`.

**These numbers come from a shared 4-core Linux container, not an iPhone.** Load average was 2 to 3 from other jobs while measuring, so expect about ±10% between runs. The coverage spike put Mac to phone at roughly 2 to 3 times slower; nothing here has been run on a device. The *ratios* (before to after, scale 4 to scale 1) should carry over better than the milliseconds.

## Method

```bash
swift build -c release --product peoplemaps-bench
.build/release/peoplemaps-bench                  # scale 1, human-readable
.build/release/peoplemaps-bench --scale 4 --json # four copies of the graph, JSON
```

- Loads the bundled graph (`StreetGraph.bundled()`), builds `NativeRouter`, and reports each time and the peak resident set (`getrusage`; kilobytes on Linux, bytes on macOS).
- Each trip, in each mode, with 5 extra minutes, is run 5 times and the median reported. Two preference sets per mode: the defaults, and hills plus traffic lights set to Avoid.
- Scale 1 runs five trips: Fremont to Gas Works and Cal Anderson to Volunteer Park (about 1.7 km), Ballard to SLU (6.6 km), Ballard to Capitol Hill (9.4 km) and Ballard to Madrona (10.4 km). Coordinates are in `Bench/main.swift`.
- `--scale N` routes on the bundled graph plus N-1 translated copies, with fresh node, edge and restriction ids and widened bounds, and checks that no edge or restriction crosses between copies. Places come only from the original copy. It runs the two short trips: the route is the same, so any extra time is per-search work that grows with the graph.
- `--runs N` changes the repeat count, `--trip NAME` keeps trips whose name contains NAME. The JSON includes a hash of each route's edge ids, to compare two builds quickly.
- `Tests/RouteGoldenTests.swift` is the guard: about 110 requests (14 short and 2 long place pairs, 3 modes, budgets 0 and 5, plus requests with preferences) must reproduce the recorded edge-id hashes, candidate counts, metrics (to 1e-6) and reasons in `Tests/Fixtures/route-golden.json`. The fixture was recorded from the router before any change below. Regenerate it only for a deliberate routing change: `PEOPLEMAPS_WRITE_GOLDEN=1 swift test --filter RouteGoldenTests`.

## What was slow

A profile of one short trip (callgrind) put 91% of search time inside `StressModel.transition`, and a large part of that in `GraphEdge.roadClass`: it builds arrays of strings and calls Foundation's `replacingOccurrences` every time it is read, several times per junction. The same junction was costed again by each of the seven searches (1 fastest plus 6 weights): a typical request evaluated each turn 4 to 6 times. The per-search arrays the spike suspected were real but small: scale 4 cost 1.05 to 1.33 times scale 1 for the same short trip.

## What changed

All of it is inside `Core/RoutingEngine.swift` plus new files; the stress model, preferences and public API are untouched, and routes are identical (the golden test and the bench hashes agree before and after each step).

1. **Search state that does not scale with the graph** (`SearchBuffers.swift`). Cost, parent and closed state live in pooled buffers cleared by a generation stamp instead of three new arrays per search. Preferences are applied per edge when it is read, not by copying the whole stress array. This took the scale 4 penalty on short trips from 1.05 to 1.33 times down to 0.97 to 1.1 (with the later steps). The pool holds one buffer set per concurrent search, so it costs memory (see below). A sparse hash table per search was not tried: the stamped version already removed the scale penalty.
2. **Hot loop** (`RoutingEngine.swift`, `TransitionCache.swift`). Flat arrays for edge ends, ways and mode bits, compressed adjacency, a per-node restriction flag and an allocation-free arterial lookup, with edges borrowed from the graph instead of copied. Alone this was worth about 2%, because the stress model dominates. The win is the per-request cache of turn costs, shared by all searches of a request: it records the additions the stress model makes, in order, and replays them under any preferences, so totals are bit-for-bit those of a direct call. It is capped at 262k entries (a miss just recomputes). About 3.5 to 4 times faster by itself.
3. **Concurrent searches.** The fastest search and the six base weights run together with `DispatchQueue.concurrentPerform`; candidates are added in weight order, so deduplication and `selectCalmer` see what they did before. The lighter weights that preferences can add run afterwards, as before. Cancellation reaches the other threads through a flag set by the task's cancellation handler. About 2 times on 4 cores; a phone with fewer fast cores will see less.
4. **Init and snap.** The three modes' strong components run in parallel on bitsets, the per-edge time and stress tables are built in parallel chunks, road legs come from a sorted list instead of a set per node, and nearest-node snapping uses a grid. Router init went from 885 to 285 ms. Tests compare the components and the snap against the plain algorithms they replaced.

## Results (release build, milliseconds)

Median of 5, scale 1, 5 extra minutes. Before is the router as of the start of this work.

| Trip | Mode | Before | After | Before, hills + lights avoid | After, hills + lights avoid |
|---|---|---:|---:|---:|---:|
| Fremont-GasWorks | walk | 103 | 14.7 | 102 | 14.9 |
| Fremont-GasWorks | bike | 76.6 | 14.7 | 66.3 | 11.5 |
| Fremont-GasWorks | drive | 42.5 | 7.0 | 66.5 | 10.1 |
| CalAnderson-Volunteer | walk | 206 | 45.7 | 249 | 44.7 |
| CalAnderson-Volunteer | bike | 178 | 21.0 | 187 | 23.5 |
| CalAnderson-Volunteer | drive | 172 | 20.4 | 151 | 19.6 |
| Ballard-SLU | walk | 625 | 84.4 | 691 | 99.0 |
| Ballard-SLU | bike | 446 | 60.2 | 446 | 57.4 |
| Ballard-SLU | drive | 831 | 88.9 | 937 | 98.7 |
| Ballard-CapHill | walk | 4417 | 600 | 4814 | 608 |
| Ballard-CapHill | bike | 1922 | 204 | 1919 | 208 |
| Ballard-CapHill | drive | 1528 | 163 | 1583 | 163 |
| Ballard-Madrona | walk | 5631 | 687 | 5983 | 710 |
| Ballard-Madrona | bike | 2215 | 221 | 2256 | 223 |
| Ballard-Madrona | drive | 1785 | 182 | 1772 | 191 |

Scale 4 (293416 nodes, 795852 edges) against scale 1, same trips and routes:

| Trip | Mode | Before, scale 1 | Before, scale 4 | Ratio | After, scale 1 | After, scale 4 | Ratio |
|---|---|---:|---:|---:|---:|---:|---:|
| Fremont-GasWorks | walk, default | 103 | 118 | 1.15 | 14.7 | 14.3 | 0.97 |
| Fremont-GasWorks | walk, hills + lights avoid | 102 | 115 | 1.13 | 14.9 | 14.8 | 0.99 |
| Fremont-GasWorks | bike, default | 76.6 | 88.9 | 1.16 | 14.7 | 14.1 | 0.96 |
| Fremont-GasWorks | bike, hills + lights avoid | 66.3 | 80.5 | 1.21 | 11.5 | 11.4 | 0.99 |
| Fremont-GasWorks | drive, default | 42.5 | 56.5 | 1.33 | 7.0 | 6.8 | 0.97 |
| Fremont-GasWorks | drive, hills + lights avoid | 66.5 | 80.4 | 1.21 | 10.1 | 9.6 | 0.95 |
| CalAnderson-Volunteer | walk, default | 206 | 216 | 1.05 | 45.7 | 38.4 | 0.84 |
| CalAnderson-Volunteer | walk, hills + lights avoid | 249 | 266 | 1.07 | 44.7 | 42.9 | 0.96 |
| CalAnderson-Volunteer | bike, default | 178 | 187 | 1.05 | 21.0 | 20.1 | 0.96 |
| CalAnderson-Volunteer | bike, hills + lights avoid | 187 | 201 | 1.07 | 23.5 | 22.9 | 0.97 |
| CalAnderson-Volunteer | drive, default | 172 | 182 | 1.06 | 20.4 | 19.5 | 0.96 |
| CalAnderson-Volunteer | drive, hills + lights avoid | 151 | 163 | 1.08 | 19.6 | 22.2 | 1.13 |

| | Before | After |
|---|---:|---:|
| Graph load, scale 1 | 125 ms | 97 ms |
| Router init, scale 1 | 885 ms | 285 ms |
| Router init, scale 4 | 3626 ms | 1184 ms |
| Peak RSS after init, scale 1 | 131 MB | 134 MB |
| Peak RSS after all trips, scale 1 | 136 MB | 265 MB |
| Peak RSS after short trips, scale 4 | 444 MB | 469 MB |

**Memory went up while routing.** A long trip now costs about 130 MB over the idle router at scale 1 (before: 5 MB): seven buffer sets, the turn cache, and per-thread allocator arenas. At scale 4 the short trips add about 10 MB. If the all-Seattle graph is bundled (3.6 times larger), the buffer sets grow with it. Reducing concurrency, or a smaller cache, trades time for memory; decide when we measure on a device.

## Budgets

Proposed, for this box in a release build, as limits on the medians above (current worst case in brackets). Re-measure on a device before treating the absolute numbers as product requirements.

- Short trips (about 2 km, any mode, any preferences): at most 60 ms at scale 1 (46), and at most 1.25 times that at scale 4 (1.13; it was 1.33).
- Medium trips (6 to 7 km): at most 150 ms (99).
- Long trips (9 to 11 km): bike and drive at most 300 ms (223), walk at most 900 ms (710).
- Router init: at most 400 ms at scale 1 (285), and at most 1.6 s at scale 4 (1184). Graph load at most 150 ms (97).
- Peak RSS after a long trip at scale 1: at most 320 MB (265).
- Debug `RouteGoldenTests`: under 30 s (16 s here).

Walking is the slowest because the walk network has the most edges. If a long walk is still too slow on a device, the next step is a better lower bound (landmarks), which this work did not need and did not try.
