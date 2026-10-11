#!/bin/bash
# Builds the iPhone app for the simulator and installs it on the booted one.
# Usage: scripts/build-ios-sim.sh   (prints the app path on the last line)
set -euo pipefail
cd "$(dirname "$0")/.."
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
if xcrun simctl list devices booted | grep -q Booted; then
  xcrun simctl install booted "$APP"
fi
echo "$APP"
