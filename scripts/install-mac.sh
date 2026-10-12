#!/bin/bash
# Builds DarraOwl and installs it in /Applications. Never uses sudo.
# The first launch asks you to approve the system component in
# System Settings > General > Login Items.
set -euo pipefail
cd "$(dirname "$0")/.."

# Insomnia drives the same pmset settings: never run both.
if [ -e /etc/sudoers.d/insomnia ] || [ -e "$HOME/Library/LaunchAgents/com.insomnia.backstop.plist" ] \
   || launchctl print "gui/$(id -u)/com.insomnia.backstop" >/dev/null 2>&1; then
  echo "Insomnia est encore installé (/etc/sudoers.d/insomnia ou com.insomnia.backstop)." >&2
  echo "Désinstalle-le avant DarraOwl. Rien n'a été modifié." >&2
  exit 1
fi

# Replacing the app during a session would leave the running helper
# unverifiable by the new app until the session ends, and quitting the app
# ends the session. The installed CLI knows; without it, a disabled sleep is
# taken as a session.
CLI="/Applications/DarraOwl.app/Contents/Helpers/darraowl"
refuse_during_session() {
  if [ -x "$CLI" ] && STATUS="$("$CLI" status 2>/dev/null)"; then
    if grep -q "^Éveillé" <<<"$STATUS"; then
      echo "Une session DarraOwl est en cours : arrête-la (menu ou darraowl stop), puis relance l'installation." >&2
      exit 1
    fi
  elif pmset -g | awk '$1 == "SleepDisabled" { v = $2 } END { exit (v == "1") ? 0 : 1 }'; then
    echo "La veille est désactivée : une session semble en cours." >&2
    echo "Arrête-la depuis le menu de DarraOwl, puis relance l'installation." >&2
    exit 1
  fi
}

refuse_during_session
# Signed Developer ID, like the releases: macOS records the helper's signature
# when it is registered and refuses another one afterwards, so local builds
# and releases must never differ there.
source scripts/asc-auth.sh
OUT="build/install"
rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate --quiet
xcodebuild -project DarraOwl.xcodeproj -scheme DarraOwlMac -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$OUT/DarraOwl-mac.xcarchive" \
  -allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"} CURRENT_PROJECT_VERSION="$(date -u +%Y%m%d%H%M)" -quiet archive
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>S3YD258U2R</string>
	<key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/DarraOwl-mac.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT" -allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"} >/dev/null
APP="$OUT/DarraOwl.app"
codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" || {
  echo "Le build n'est pas signé Developer ID : rien n'a été installé." >&2; exit 1; }
DEST="/Applications/DarraOwl.app"
# The build takes minutes: a session may have started meanwhile.
refuse_during_session

if pgrep -x DarraOwl >/dev/null; then
  # No session (checked just above): quitting ends nothing.
  osascript -e 'tell application id "com.darrao.darraowl.mac" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x DarraOwl >/dev/null || break; sleep 0.5; done
fi

STAGE="/Applications/.DarraOwl.app.staging.$$"
rm -rf "$STAGE"
ditto "$APP" "$STAGE"
if [ -e "$DEST" ]; then
  rm -rf "$DEST"
fi
mv "$STAGE" "$DEST"
codesign --verify --strict --deep "$DEST"
# The built copy goes: macOS could otherwise open it instead of this one.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" >/dev/null 2>&1 || true
rm -rf "$OUT"
echo "Installé : $DEST"
open "$DEST"
