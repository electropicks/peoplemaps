#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
peoplemaps_xcode="${PEOPLEMAPS_XCODE:-/Applications/Xcode.app/Contents/Developer}"
python3 Scripts/test_importer.py
DEVELOPER_DIR="$peoplemaps_xcode" swift test --jobs 4
if [[ $# -gt 0 ]]; then
  DEVELOPER_DIR="$peoplemaps_xcode" xcodebuild -project Peoplemaps.xcodeproj -scheme Peoplemaps \
    -configuration Debug -destination "platform=iOS Simulator,id=$1" \
    -derivedDataPath DerivedData -clonedSourcePackagesDirPath DerivedData/SourcePackages \
    -jobs 4 -parallel-testing-enabled NO test
fi
