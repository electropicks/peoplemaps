#!/usr/bin/env bash
# One entry point for checking a change, on macOS, Linux (cloud sessions) and CI.
#   Scripts/verify.sh            importer tests, data reproduction, Swift tests; plus the app build on macOS
#   Scripts/verify.sh --ui       also the UI suite on a simulator (macOS only; creates "PeopleMaps Verify" if needed)
#   Scripts/verify.sh --ui UDID  the UI suite on that simulator
#   Scripts/verify.sh --fast     skip data reproduction and the app build
#   Scripts/verify.sh --region   also reproduce each full region in Data/regions.json from its fetched files
#                                (Scripts/fetch_data first; regions not fetched are skipped, and it says so)
set -euo pipefail
cd "$(dirname "$0")/.."

ui=""; fast=0; region=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ui) ui="auto"; if [[ $# -gt 1 && "$2" != --* ]]; then ui="$2"; shift; fi ;;
    --fast) fast=1 ;;
    --region) region=1 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

mac=0; [[ "$(uname)" == Darwin ]] && mac=1
[[ $mac == 1 ]] && export DEVELOPER_DIR="${PEOPLEMAPS_XCODE:-/Applications/Xcode.app/Contents/Developer}"
results=()
step() { local name="$1"; shift; echo "==> $name"; if "$@"; then results+=("PASS  $name"); else results+=("FAIL  $name"); summary; exit 1; fi; }
summary() { echo; echo "verify summary ($(uname -s)):"; printf '  %s\n' "${results[@]}"; }

step "importer tests" python3 Scripts/test_importer.py

# The shipped data must be exactly what the importer produces from the archived snapshots.
reproduce() {
  local out; out="$(mktemp -d)"
  # BinaryGraphTests reuses this run's output (graph.json and the binary graph) instead of running the importer again.
  export PEOPLEMAPS_IMPORT_DIR="$out"
  python3 Scripts/import_osm.py --out "$out" --json-graph "$out/graph.json" > "$out/import.log" 2>&1 || { tail -20 "$out/import.log"; return 1; }
  local bad=0 files=(seattle-graph.bin seattle-map.pmtiles)
  # The search index's bytes depend on the SQLite version, so it is compared only where that matches the shipped build.
  local built shipped
  built="$(python3 -c 'import sqlite3; print(sqlite3.sqlite_version)')"
  shipped="$(python3 -c 'import json; print(json.load(open("Data/provenance.json"))["search"]["sqlite"])')"
  if [[ "$built" == "$shipped" ]]; then
    files+=(seattle-search.sqlite.gz)
    cmp -s "$out/provenance.json" Data/provenance.json || { echo "differs from a fresh import: Data/provenance.json"; bad=1; }
  else
    echo "SQLite $built here, $shipped shipped: search index and provenance not compared"
  fi
  for f in "${files[@]}"; do
    cmp -s "$out/$f" "Core/Resources/$f" || {
      echo "differs from a fresh import: Core/Resources/$f"; bad=1
      # The index's bytes depend on the zlib and SQLite builds too; say which layer differs.
      [[ "$f" == *.sqlite.gz ]] && python3 Scripts/compare_search_index.py "$out/$f" "Core/Resources/$f"
    }
  done
  return $bad
}
[[ $fast == 0 ]] && step "data reproduces byte for byte" reproduce

# Full regions live in release assets, not git, so this is opt-in; CI and the Swift tests never need them.
if [[ $region == 1 ]]; then step "regions reproduce byte for byte" python3 Scripts/reproduce_regions.py
else echo "regions not checked (pass --region after Scripts/fetch_data); the shipped fixture is checked above"; fi

step "Swift tests" swift test

if [[ $mac == 1 && $fast == 0 ]]; then
  step "iOS app build" xcodebuild -quiet -project Peoplemaps.xcodeproj -scheme Peoplemaps -configuration Debug \
    -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
fi

if [[ -n "$ui" ]]; then
  [[ $mac == 1 ]] || { echo "--ui needs macOS with Xcode" >&2; exit 69; }
  if [[ "$ui" == auto ]]; then
    ui="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == "PeopleMaps Verify": print(d["udid"]); raise SystemExit')"
    if [[ -z "$ui" ]]; then
      type="$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
names = [t["identifier"] for t in json.load(sys.stdin)["devicetypes"] if t["name"].startswith("iPhone") and "Pro" in t["name"] and "Max" not in t["name"]]
print(names[-1])')"
      ui="$(xcrun simctl create "PeopleMaps Verify" "$type")"
    fi
  fi
  xcrun simctl boot "$ui" 2>/dev/null || true
  # xcodebuild -quiet names a failed test but not what failed in it, so a failed run prints each failure's message
  # from the result bundle and keeps the bundle for Xcode.
  ui_tests() {
    local bundle; bundle="${PEOPLEMAPS_UI_RESULT:-$(mktemp -d)/ui-tests.xcresult}"
    xcodebuild -quiet -project Peoplemaps.xcodeproj -scheme Peoplemaps -configuration Debug \
      -destination "platform=iOS Simulator,id=$ui" -only-testing:PeoplemapsUITests/PeoplemapsUITests \
      -parallel-testing-enabled NO -resultBundlePath "$bundle" test && return 0
    echo "result bundle: $bundle"
    xcrun xcresulttool get test-results summary --path "$bundle" 2>/dev/null | python3 -c '
import json, sys
for f in json.load(sys.stdin).get("testFailures", []):
    print("  " + str(f.get("testName")) + ": " + str(f.get("failureText")))' || true
    return 1
  }
  step "UI tests on $ui" ui_tests
fi

summary
