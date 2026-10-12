#!/bin/bash
# Builds the iPhone app for the simulator and installs it on the booted one.
# Usage: scripts/build-ios-sim.sh   (prints the app path on the last line)
set -euo pipefail
cd "$(dirname "$0")/.."
# Prefer Xcode 27 when it sits next to an older Xcode.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer
fi
xcodegen generate --quiet
xcodebuild \
  -project DarraOwl.xcodeproj \
  -scheme DarraOwliOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates \
  -quiet \
  build
APP="build/DerivedData/Build/Products/Debug-iphonesimulator/DarraOwl.app"
# A booted iPhone simulator (a paired watch can be booted too).
SIM="$(xcrun simctl list devices booted 2>/dev/null | awk '!found && /iPhone/ && /Booted/ { if (match($0, /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/)) found = substr($0, RSTART, RLENGTH) } END { if (found) print found }' || true)"
if [ -n "$SIM" ]; then
  xcrun simctl install "$SIM" "$APP"
fi
echo "$APP"
