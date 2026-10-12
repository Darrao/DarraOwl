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
# unverifiable by the new app until the session ends. The installed CLI
# knows; without it, a disabled sleep is taken as a session.
CLI="/Applications/DarraOwl.app/Contents/Helpers/darraowl"
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

APP="$(scripts/build-mac.sh Release | tail -n 1)"
DEST="/Applications/DarraOwl.app"

if pgrep -x DarraOwl >/dev/null; then
  # A running session lives in the helper and survives this.
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
echo "Installé : $DEST"
open "$DEST"
