# Verified baseline

The actual native app was built, installed, launched, visually inspected, and
driven through XCTest on **Peoplemaps POC Validation**, a dedicated iPhone 17 Pro
Simulator, iOS 26.5 (23F77), arm64. Xcode 27.0 (27A266a), macOS 27.0.1.
Simulator UDID: `D4304B61-4C72-414B-A592-0CC38A9DC2AC`.

The final UI run completed at **2026-10-12 00:03:27 UTC** (the Mac's logs display
11 October, 17:03 local time). No physical-device or road testing was performed.

| Gate | Result |
| --- | --- |
| Native app + UI bundle build | Passed |
| Swift core tests | 23 passed, 0 failed |
| Python import-policy tests | 12 passed, 0 failed |
| Actual-app Simulator UI tests | 5 passed, 0 failed, 0 skipped |
| Real Seattle route audit | 24 comparisons completed, 0 route errors |
| Offline regeneration from preserved archives | Byte-identical derived graph and map |

`ui-summary.json` is exported directly from the successful XCTest result bundle.
`data-reproduction.json` contains the verified SHA-256 values. The source hashes
in `source-manifest.json` identify the code/data used for this baseline.

## What was exercised

The five UI tests cover opening driving routes, cycling, budget changes including
No extra, explanation sheets, empty search, cancelling search without changing
the selection, selecting another place, swapping endpoints, repeated mode and
budget changes, a same-place error and recovery, and cancel/resume while a real
comparison is pending. Debug launch arguments add a delay for repeatable
cancellation testing; route data and computation are unchanged.

Core tests cover the exact-second budget boundary, candidate selection,
different modal costs, uncertain surface tags, turn restrictions and exceptions,
U-turn policy, continuity/mode legality in real routes, cancellation propagation,
stale errors and stale successful results, invalid inputs, bounded place search,
and snapping to the connected network near the Burke Museum.

The audit uses Ballard Library → Gas Works, Fremont Library → Burke Museum, and
Kerry Park → Gas Works, for both modes and budgets of 0/2/5/10 minutes. It is a
data/model exercise, not field validation. Its timings measure desktop core
computation, not iPhone performance or actual travel.

Verification caught and resolved an isolated-node snapping failure near the
museum, inherited SwiftUI identifiers that obscured Cancel/Retry from UI
automation, and map padding that placed the origin marker under attribution.
The final suite and screenshots reflect those corrections.

## Actual-app captures

- [Driving comparison](peoplemaps-driving.png)
- [Cycling comparison](peoplemaps-cycling.png)
- [Explanation and coverage metrics](peoplemaps-route-evidence.png)

All three are unedited screenshots exported from the successful UI test run.
They show the native app with its real bundled data, not mockups. They retain
visible OSM attribution where the map is shown.

Library saving was attempted for these three files. The upload helper stopped
before preparation because the Library upload service was unavailable in this
local execution environment. **No uploads were made and no Library IDs were
created.** The local files are complete and can be saved by the parent task if
its Library connection supports uploads.

Detailed local logs and `.xcresult` bundles remain in ignored `Evidence/` paths:
`core-tests.log`, `ui-tests-final.log`, `UI-Final.xcresult`. The first, superseded
UI failure run is also retained locally for diagnosis. Build output, dependencies,
and Simulator installation are reproducible from the committed source; they are
not committed.

## Remaining limits

Real travel time, route feasibility, driving comfort, physical separation,
turn protection, merge difficulty, grade effects, physical-device behavior,
all Dynamic Type sizes, and exhaustive VoiceOver behavior are unverified.
The app openly discloses its modeled times, limited coverage, endpoint gaps,
missing grade model, incomplete tags, and candidate-search limits. It does not
request location access, navigate, or claim safety. See the README and
architecture rationale before extending its claims.
