# Peoplemaps — independent review

Peoplemaps is a placeholder name. The interesting question is whether a map can
help people choose a route that asks less of them, with an explicit small time
tradeoff and reasons they can inspect. Take a fresh creative and technical look;
you do not need to preserve the current visual design or implementation choices.

There is a working native iOS baseline: SwiftUI, MapLibre, an offline Seattle OSM
extract, local place search, driving/cycling comparisons, an extra-time budget,
and transparent explanations. Everything runs on-device without accounts,
credentials, a server, or location access. The repository is standalone and has
no connection to Chimera, GoopGal, or heater assets. Leave those projects alone.

Start with `README.md`, run the app, and read `Evidence/VERIFICATION.md`. The
architecture rationale explains where this intentionally small router differs
from mature engines. `Evidence/route-audit.json` contains reproducible modeled
comparisons, not field measurements.

The opening Kerry Park → Gas Works example can avoid one highway entry and one
arterial left at a modest modeled time cost. Cycling uses different criteria.
The UI also accepts that no useful alternate candidate may be found. The time
budget is a hard filter on unrounded modeled seconds.

Please challenge the experience, route plausibility, accessibility, and the
meaning of “calmer.” In particular, consider whether the explanation makes both
benefits and uncertainty legible, whether the controls leave enough room for
the map, and how the routing foundation should evolve. We own route selection
and preference scoring; commercial place details could be optional later.
The constants are design hypotheses, not validated human preferences.

No route may be represented as safe, no missing attributes should become facts,
and no ETA should be presented as verified or traffic-aware. Grade is currently
not modeled. Endpoint gaps, limited coverage, OSM restrictions, and the bounded
candidate search matter. Improve the product freely while keeping those claims
honest. No publishing, paid services, signing, or location permission is part
of this handoff.

Preserve the baseline and experiment in a separate worktree:

```sh
cd /Users/lkbidy/Documents/Codex/2026-10-11/task-5/Peoplemaps
git worktree add ../Peoplemaps-claude-review -b claude/independent-review peoplemaps-poc-v0.1
cd ../Peoplemaps-claude-review
open Peoplemaps.xcodeproj
```

Use separate DerivedData in that worktree, a dedicated Simulator, and per-command
`DEVELOPER_DIR`; avoid switching global Xcode selection. A separate Blender task
may still be using this Mac. Check before heavy concurrent work or taking the
foreground for capture. There is no remote and no review worktree yet; the
command above is a suggestion, not a claim that it was created.
