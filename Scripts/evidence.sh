#!/usr/bin/env bash
# Run UITests/EvidenceTour.swift in dark and light and save its screenshots as PNGs. macOS with Xcode only.
#   Scripts/evidence.sh            into Evidence/ui-attachments/, on the "PeopleMaps Verify" simulator
#   Scripts/evidence.sh OUT UDID   into OUT, on that simulator
# CI runs this in the ui-tests job and uploads OUT as the "evidence" workflow artifact.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-Evidence/ui-attachments}"; udid="${2:-}"
[[ "$(uname)" == Darwin ]] || { echo "evidence.sh needs macOS with Xcode" >&2; exit 69; }
export DEVELOPER_DIR="${PEOPLEMAPS_XCODE:-/Applications/Xcode.app/Contents/Developer}"

if [[ -z "$udid" ]]; then
  udid="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == "PeopleMaps Verify": print(d["udid"]); raise SystemExit')"
  [[ -n "$udid" ]] || { echo "no \"PeopleMaps Verify\" simulator; run Scripts/verify.sh --ui first" >&2; exit 69; }
fi
xcrun simctl boot "$udid" 2>/dev/null || true
mkdir -p "$out"

# Attachments come out of the result bundle as <name>_<n>_<uuid>.png; keep <name>-<appearance>.png.
collect() {
  local bundle="$1" appearance="$2" raw; raw="$(mktemp -d)"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$raw"
  python3 - "$raw" "$out" "$appearance" <<'PY'
import json, re, shutil, sys
from pathlib import Path
raw, out, appearance = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
manifest = raw / "manifest.json"
entries = json.loads(manifest.read_text()) if manifest.exists() else []
attachments = [a for e in entries for a in e.get("attachments", [])]
if not attachments:
    attachments = [{"exportedFileName": p.name} for p in raw.glob("*.png")]
for a in attachments:
    src = raw / a["exportedFileName"]
    if not src.exists(): continue
    name = Path(a.get("suggestedHumanReadableName") or src.name).stem
    name = re.sub(r"_\d+_[0-9A-Fa-f-]+$", "", name)
    dest = out / f"{name}-{appearance}{src.suffix.lower()}"
    shutil.copyfile(src, dest); print(dest)
PY
}

status=0
for appearance in dark light; do
  echo "==> evidence tour, $appearance"
  xcrun simctl ui "$udid" appearance "$appearance"
  bundle="$(mktemp -d)/evidence-$appearance.xcresult"
  TEST_RUNNER_PEOPLEMAPS_EVIDENCE=1 xcodebuild -quiet -project Peoplemaps.xcodeproj -scheme Peoplemaps -configuration Debug \
    -destination "platform=iOS Simulator,id=$udid" -only-testing:PeoplemapsUITests/EvidenceTour \
    -parallel-testing-enabled NO -resultBundlePath "$bundle" test || status=1
  [[ -d "$bundle" ]] && collect "$bundle" "$appearance"
done
exit $status
