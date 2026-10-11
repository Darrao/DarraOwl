#!/bin/bash
# Builds and signs DarraOwl.app (menu bar app + embedded helper daemon).
# Usage: scripts/build-mac.sh [Debug|Release]   (default Release)
# Prints the path of the built app on the last line.
set -euo pipefail
cd "$(dirname "$0")/.."
# Prefer Xcode 27 when it sits next to an older Xcode.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer
fi

CONFIG="${1:-Release}"
# Each build gets its own number so the app can tell an outdated helper apart.
BUILD_NUMBER="$(date -u +%Y%m%d%H%M%S)"

xcodegen generate --quiet
xcodebuild \
  -project DarraOwl.xcodeproj \
  -scheme DarraOwlMac \
  -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet \
  build

APP="build/DerivedData/Build/Products/$CONFIG/DarraOwl.app"
codesign --verify --strict --deep "$APP"
test -x "$APP/Contents/MacOS/DarraOwlHelper"
test -f "$APP/Contents/Library/LaunchDaemons/com.darrao.darraowl.mac.helper.plist"
echo "$APP"
