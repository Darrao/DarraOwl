#!/bin/bash
# Builds DarraOwl for Mac signed "Developer ID", notarizes it with Apple and
# publishes it as a GitHub Release.
#
# Once, before the first release (see docs/publication.md):
#   1. A "Developer ID Application" certificate (Xcode > Settings > Accounts >
#      Manage Certificates > + > Developer ID Application).
#   2. An App Store Connect API key (see asc-auth.sh), or notary credentials
#      in the Keychain, profile "DarraOwl":
#        xcrun notarytool store-credentials DarraOwl --apple-id <apple id> --team-id S3YD258U2R
#
# Each release: set MAC_VERSION in project.yml to the new version first.
# Usage: scripts/release-mac.sh 0.2.0 [--no-publish]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/asc-auth.sh
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer
fi

VERSION="${1:?Version, par exemple 0.2.0}"
# Local builds carry MAC_VERSION: behind the release, the updater would
# replace them with it.
grep -q "^    MAC_VERSION: \"$VERSION\"$" project.yml || {
  echo "Mets MAC_VERSION à \"$VERSION\" dans project.yml, puis relance." >&2; exit 1; }
PUBLISH=1
[ "${2:-}" = "--no-publish" ] && PUBLISH=0
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
OUT="build/release-$VERSION"
ARCHIVE="$OUT/DarraOwl-mac.xcarchive"
rm -rf "$OUT" && mkdir -p "$OUT"

# Read whole first: under pipefail, grep -q leaving early fails the pipe (SIGPIPE).
IDENTITIES="$(security find-identity -v -p codesigning)"
grep -q "Developer ID Application" <<<"$IDENTITIES" || {
  echo "Aucun certificat Developer ID Application dans le trousseau. Voir docs/publication.md." >&2; exit 1; }
# Notarization: the API key when Apple takes it, else the Keychain profile.
if ! xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
  NOTARY_AUTH=(--keychain-profile DarraOwl)
  xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 || {
    echo "Notarisation impossible : ni clé App Store Connect valable, ni profil DarraOwl. Voir docs/publication.md." >&2; exit 1; }
fi

xcodegen generate --quiet
xcodebuild -project DarraOwl.xcodeproj -scheme DarraOwlMac -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"} \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" -quiet archive

OPTIONS="$OUT/ExportOptions.plist"
cat > "$OPTIONS" <<PLIST
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
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "$OUT" -allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"}

APP="$OUT/DarraOwl.app"
codesign --verify --strict --deep "$APP"
# -dvv: only then does codesign print the Authority lines.
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
grep -q "Authority=Developer ID Application" <<<"$SIGNATURE" || { echo "L'app n'est pas signée Developer ID." >&2; exit 1; }

ZIP="$OUT/DarraOwl-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarisation (quelques minutes)…"
xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
# Only the zip stays: macOS could open the built copy instead of the
# installed one (a second DarraOwl in the menu bar).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" >/dev/null 2>&1 || true
rm -rf "$APP" "$ARCHIVE"
# Hashed from inside the folder, so `shasum -c` works for whoever downloads it.
(cd "$OUT" && shasum -a 256 "DarraOwl-$VERSION.zip" | tee "DarraOwl-$VERSION.zip.sha256")

if [ "$PUBLISH" -eq 1 ]; then
  gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" --title "DarraOwl $VERSION" --notes "$(cat <<NOTES
App Mac signée Developer ID et notarisée par Apple.

Installation :
1. Télécharge DarraOwl-$VERSION.zip, ouvre-le, glisse DarraOwl dans Applications.
2. Ouvre DarraOwl, puis suis la fenêtre de bienvenue (composant système, iCloud, iPhone).

Nécessite macOS 26 ou plus récent sur un Mac Apple Silicon. App iPhone : TestFlight / App Store.
Désinstallation : dans le Terminal, /Applications/DarraOwl.app/Contents/MacOS/DarraOwl --uninstall, puis mets l'app à la corbeille (pas directement à la corbeille : le composant système resterait).
Mise à jour : arrête la session, quitte DarraOwl, remplace l'app, rouvre-la.
NOTES
)"
  echo "Release publiée : v$VERSION"
else
  echo "Prêt, non publié : $ZIP"
fi
