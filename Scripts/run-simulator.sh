#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
peoplemaps_xcode="${PEOPLEMAPS_XCODE:-/Applications/Xcode.app/Contents/Developer}"
peoplemaps_sim="${1:?Pass an available Simulator UDID (xcrun simctl list devices available)}"
DEVELOPER_DIR="$peoplemaps_xcode" xcodebuild -project Peoplemaps.xcodeproj -scheme Peoplemaps \
  -configuration Debug -destination "platform=iOS Simulator,id=$peoplemaps_sim" \
  -derivedDataPath DerivedData -clonedSourcePackagesDirPath DerivedData/SourcePackages -jobs 4 build
DEVELOPER_DIR="$peoplemaps_xcode" xcrun simctl install "$peoplemaps_sim" DerivedData/Build/Products/Debug-iphonesimulator/Peoplemaps.app
DEVELOPER_DIR="$peoplemaps_xcode" xcrun simctl launch --terminate-running-process "$peoplemaps_sim" org.peoplemaps.prototype
