#!/bin/bash
# Archives the iPhone app and uploads it to App Store Connect (TestFlight).
# Needs: the app record in App Store Connect (bundle id com.darrao.darraowl),
# the CloudKit schema deployed to Production, an Xcode account signed in.
# Usage: scripts/testflight.sh [--no-upload]
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer
fi
DESTINATION=upload
[ "${1:-}" = "--no-upload" ] && DESTINATION=export
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
ARCHIVE="build/DarraOwl-iOS-$BUILD_NUMBER.xcarchive"

xcodegen generate --quiet
xcodebuild \
  -project DarraOwl.xcodeproj -scheme DarraOwliOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet archive

OPTIONS="$(mktemp -t darraowl-export).plist"
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$DESTINATION</string>
	<key>teamID</key><string>S3YD258U2R</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
  -exportPath "build/export-$BUILD_NUMBER" -allowProvisioningUpdates
rm -f "$OPTIONS"
echo "Build $BUILD_NUMBER : $([ "$DESTINATION" = upload ] && echo 'envoyé à App Store Connect' || echo "exporté dans build/export-$BUILD_NUMBER")"
