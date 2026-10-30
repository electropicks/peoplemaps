---
name: simulator-evidence
description: Run PeopleMaps in the iOS Simulator and capture screenshots or a demo video as evidence of a visible change. Use for any App/ or UITests/ change, when asked to "show", "screenshot", "record a demo" or "check how it looks", and before calling UI work done. macOS only.
---

# Simulator evidence

macOS with Xcode only. In a cloud or Linux session, say so and leave the screenshots to the Mac or CI.

## Setup

- Every `xcodebuild` and `simctl` call needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. In Claude Code, run them with the Bash sandbox off, or XPC errors follow.
- **Don't use the user's UAT simulator ("Peoplemaps POC Validation")** unless asked. `Scripts/verify.sh --ui` creates and reuses "PeopleMaps Verify". Parallel workers each create their own device, because sharing one breaks test runs.
- Bundle ID: `electrocorp.peoplemaps`.

## Launch flags (Debug only; they never replace the router or data)

| Flag | Effect |
|---|---|
| `--ui-testing` | animations off, muted voice, isolated defaults |
| `--simulate-route` | Start replays the route instead of using GPS |
| `--fast-simulation` | replay at 40× |
| `--real-location` | use the simulated GPS track, and ask for location for real (the system prompt on first launch) |
| `--location-granted LAT,LON` | with `--ui-testing`: location allowed at that spot, no prompt. Without it (and without `--real-location`) location counts as denied |
| `--slow-routing` | 3 s router delay, to show loading states |
| `--keep-saved` | keep favourites and recents between UI-test launches |

## Capture

```bash
xcrun simctl launch --terminate-running-process $UDID electrocorp.peoplemaps --simulate-route
xcrun simctl ui $UDID appearance dark          # then light
xcrun simctl io $UDID screenshot Evidence/<screen>-<light|dark>.png
```

- UI tests save screenshots through `capture(...)` into the test results.
- Landscape: `XCUIDevice.shared.orientation` in a test.
- Demo video: `UITests/DemoTour.swift` (skipped unless `TEST_RUNNER_PEOPLEMAPS_DEMO=1`), recorded with `xcrun simctl io $UDID recordVideo --codec h264`.
- Name files `Evidence/<feature>-<variant>-<light|dark>.png`. Look at every screenshot before citing it.
