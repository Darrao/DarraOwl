#!/bin/bash
# Puts the Mac back to normal and removes DarraOwl. Never uses sudo: when a
# setting cannot be restored, it prints the exact command for you to run.
# Usage: scripts/uninstall.sh [--purge]   (--purge also removes preferences)
set -uo pipefail

APP="/Applications/DarraOwl.app"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1
status=0

echo "==> DarraOwl : désinstallation"

if [ -x "$APP/Contents/MacOS/DarraOwl" ]; then
  if pgrep -x DarraOwl >/dev/null; then
    osascript -e 'tell application id "com.darrao.darraowl.mac" to quit' >/dev/null 2>&1 || true
    sleep 1
  fi
  # Ends any session, restores the journal, removes the helper and login item.
  if ! "$APP/Contents/MacOS/DarraOwl" --uninstall; then
    echo
    echo "Arrêt avant suppression : le composant système n'a pas tout rétabli."
    echo "Il réessaie seul. Relance ce script dans une minute."
    exit 1
  fi
else
  echo "DarraOwl.app absent de /Applications : seul l'état du Mac est vérifié."
fi

echo "==> Vérification de l'état du Mac"
if pmset -g | awk '$1 == "SleepDisabled" { exit ($2 == "1") ? 0 : 1 }'; then
  echo "La veille est encore désactivée. Pour la rétablir, lance toi-même :"
  echo "  sudo pmset -a disablesleep 0"
  status=1
else
  echo "Veille normale."
fi
if [ -e "/Library/Application Support/DarraOwl/journal.json" ]; then
  echo "Le journal du composant système est encore présent :"
  echo "  /Library/Application Support/DarraOwl/journal.json"
  echo "Pour le lire : sudo cat \"/Library/Application Support/DarraOwl/journal.json\""
  status=1
fi

if [ "$status" -eq 0 ] && [ -d "$APP" ]; then
  rm -rf "$APP" && echo "App supprimée : $APP"
fi

if [ "$PURGE" -eq 1 ]; then
  defaults delete com.darrao.darraowl.mac >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Application Support/DarraOwl" "$HOME/Library/Logs/DarraOwl"
  echo "Préférences supprimées."
fi

[ "$status" -eq 0 ] && echo "Terminé." || echo "Terminé avec des points à vérifier (voir ci-dessus)."
exit "$status"
