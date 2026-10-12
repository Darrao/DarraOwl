#!/bin/bash
# Builds the iPhone app for the connected iPhone and installs it.
# Usage: scripts/install-ios.sh [device-udid]   (default: the first connected iPhone)
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer
fi
# An iPhone (not the paired Watch), connected or reachable over Wi-Fi, never "unavailable".
# awk reads to the end (no early exit, which would break the pipe) and a
# failing listing only means "none found".
UDID="${1:-$(xcrun devicectl list devices 2>/dev/null | awk '!found && /physical/ && /iPhone/ && !/unavailable/ && /(connected|available)/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { found=$i; break } } END { if (found) print found }' || true)}"
[ -n "$UDID" ] || { echo "Aucun iPhone connecté et déverrouillé." >&2; exit 1; }
BUILD_NUMBER="$(date -u +%Y%m%d%H%M%S)"
xcodegen generate --quiet
xcodebuild \
  -project DarraOwl.xcodeproj \
  -scheme DarraOwliOS \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet \
  build
APP="build/DerivedData/Build/Products/Debug-iphoneos/DarraOwl.app"
xcrun devicectl device install app --device "$UDID" "$APP"
echo "Installé sur $UDID"
