---
name: verify
description: Check a PeopleMaps change before calling it done. Use before reporting any task complete, before every commit, PR or push, after a merge or rebase, and whenever asked to "verify", "test", "check it works" or "run the suite".
---

# Verify

Run the checks, paste the summary, say what was not covered. Never skip, weaken or delete a failing test to get green; fix the cause or report it.

## 1. Run the script

```bash
Scripts/verify.sh            # every change; ~5 min on a Mac, less on Linux
Scripts/verify.sh --ui       # also the full UI suite (macOS only, ~10 min: 5 parallel simulator clones; PEOPLEMAPS_UI_WORKERS=1 for serial)
Scripts/verify.sh --fast     # inner loop only: skips data reproduction and the app build
```

`--fast` never counts as verified. Paste the `verify summary` block into your report.

## 2. What each area needs

| You changed | Required | Where it runs |
|---|---|---|
| `Core/`, `Tests/`, `Package.swift` | `verify.sh` | anywhere |
| `Scripts/*.py`, `Data/` | `verify.sh` (data must reproduce byte for byte; if outputs changed on purpose, rerun `python3 Scripts/import_osm.py` and commit them with the code) | anywhere |
| `App/`, `UITests/`, project generator | `verify.sh --ui`, plus screenshots (the `simulator-evidence` skill) for anything visible | macOS only |
| `Backend/` | `npm test` and `npx tsc --noEmit` in `Backend/` (`verify.sh` does not cover it; CI runs it in the `backend` job) | anywhere with Node 22.13+ |
| Docs only | read the rendered Markdown; check that every command and path in it exists | anywhere |
| `.claude/`, `CLAUDE.md`, `.github/` | `verify.sh --fast`, and trigger the skill or hook you changed once | anywhere |

The full UI suite passing on a Mac is the final check before a tag. Workers run only the UI tests their change affects; the suite runs once per batch.

To keep the Mac quiet, or from a session with no Xcode, GitHub can do the build and tests. It takes about 50 minutes for the UI suite, and its screenshots land in the run's `ui-screenshots` artifact:

```bash
gh workflow run ci.yml --ref <branch> [-f region=true]   # region=true bundles full Seattle data
```

## 3. Cloud and Linux sessions

There is no Xcode, Simulator or iPhone. `verify.sh` runs the importer, data and Swift tests and skips the app. For any `App/` or `UITests/` change, say plainly "not built or UI-tested: needs macOS" and rely on the macOS CI job on the PR. Never claim a visual change looks right without a screenshot.

## 4. Report

- The `verify summary` block, with counts if asked.
- What you did not run, and why.
- For UI work, the screenshot paths.
