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
    echo "Arrêt avant suppression : un point n'a pas pu être rétabli (voir ci-dessus)."
    echo "Le composant système réessaie seul. Relance ce script dans une minute."
    exit 1
  fi
else
  echo "DarraOwl.app absent de /Applications : seul l'état du Mac est vérifié."
fi

echo "==> Vérification de l'état du Mac"
# The system component deletes its own folder once everything is restored.
# Left behind (it was unreachable), it is only reported: root owns it.
if [ -d "/Library/Application Support/DarraOwl" ]; then
  echo "Le dossier du composant système est resté : /Library/Application Support/DarraOwl."
  echo "Pour le supprimer, lance toi-même :"
  echo "  sudo rm -rf \"/Library/Application Support/DarraOwl\""
fi
# DarraOwl puts back the values it found: a "disablesleep 1" set before it
# stays. This is only reported, with the command to change it.
if pmset -g | awk '$1 == "SleepDisabled" { v = $2 } END { exit (v == "1") ? 0 : 1 }'; then
  echo "La veille est désactivée sur ce Mac (disablesleep 1)."
  echo "Si ce n'est pas un réglage à toi, rétablis-la en lançant toi-même :"
  echo "  sudo pmset -a disablesleep 0"
else
  echo "Veille normale."
fi
if pmset -g custom | awk '$1 == "lowpowermode" && $2 == "1" { found = 1 } END { exit found ? 0 : 1 }'; then
  echo "Le mode économie d'énergie est activé : s'il ne vient pas de toi, Réglages Système > Batterie."
fi

if [ "$status" -eq 0 ] && [ -d "$APP" ]; then
  rm -rf "$APP" && echo "App supprimée : $APP"
fi
# The copy an update set aside, if the new version never started.
if [ "$status" -eq 0 ] && [ -d "/Applications/.DarraOwl-previous.app" ]; then
  rm -rf "/Applications/.DarraOwl-previous.app" && echo "Ancienne copie de mise à jour supprimée."
fi

if [ "$PURGE" -eq 1 ]; then
  defaults delete com.darrao.darraowl.mac >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Application Support/DarraOwl" "$HOME/Library/Logs/DarraOwl"
  echo "Préférences supprimées."
fi

[ "$status" -eq 0 ] && echo "Terminé." || echo "Terminé avec des points à vérifier (voir ci-dessus)."
exit "$status"
