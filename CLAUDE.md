# PeopleMaps

An offline iOS maps app for Seattle that picks the calmer route a local would choose (walk, bike, drive), not just the fastest. See `README.md`.

## Layout

- `Core/`: Swift package `PeoplemapsCore`. Graph, router (`RoutingEngine.swift`), stress model, navigation plan, search index, saved places, spoken text. Builds on macOS, iOS and Linux.
- `App/`: SwiftUI app. MapLibre map (`SeattleMap.swift`), `ExploreView.swift` (home, search, place card, preview), `Navigation/` (Ferrostar guidance, voice). macOS and Xcode only.
- `Scripts/`: Python data importer and search builder, project generator, `verify.sh`.
- `Data/`: OSM snapshots, elevation, provenance, licences.
- `Core/Resources/`: generated data. Never hand-edit it.
- `Docs/`: design docs and spikes. Read the relevant one before changing an area: `STRESS_MODEL`, `NAVIGATION`, `SEARCH`, `COVERAGE_SPIKE`, `VOICE_SPIKE`.

## Commands

```bash
Scripts/verify.sh                 # importer tests, data reproduction, Swift tests, iOS build (macOS)
Scripts/verify.sh --ui            # plus the UI suite (macOS)
python3 Scripts/import_osm.py     # regenerate Core/Resources from Data/
python3 Scripts/generate_project.py   # after adding or removing App/ or UITests/ files
```

On macOS, set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for `xcodebuild`, `simctl` and `swift`. In Claude Code they need the Bash sandbox off.

## Verifying your work

Before reporting any task done, committing or opening a PR, follow the `verify` skill: run `Scripts/verify.sh` (with `--ui` for `App/` or `UITests/` changes on a Mac) and paste the summary. Never skip or delete a failing test. Say plainly what you couldn't run; cloud sessions can't build the app or take screenshots.

## Rules

- **Never call a route "safe".** Say calmer, estimates, unknown when tags are missing. See the `product-rules` skill.
- **No Apple Maps data** in our data or UI, only the "Look up in Apple Maps" hand-off (`Docs/SEARCH.md`). Data licences and regeneration: the `data-pipeline` skill.
- Generated files come only from their generators: `Core/Resources/*` and `Data/provenance.json` from the importer, `Peoplemaps.xcodeproj` from `generate_project.py`. A hook blocks hand edits.
- Small, logical commits with plain messages and no attribution lines. Work on a branch, and land it through a PR into `main`.
- Use `trash`, never `rm`. Ask before deleting anything you didn't create.
- Match the surrounding code: terse Swift, few comments, `///` docs on non-obvious types.

## Things that went wrong before

- Worktrees and cloud sessions start from `origin/main`, not your local branch. Check the base before building on recent work.
- Two test runs on one simulator break each other. Give each worker its own device, and leave "Peoplemaps POC Validation" to the user.
- Graph places (`graph.places`) have no addresses; use `SearchIndex.withAddress`. Address rows share the OSM ID with their place row.
- The `xcodebuild` output to read is the `Executed N tests` and `error:` lines. "0 tests executed" means a broken run, not a pass.
