#!/usr/bin/env bash
# Auto-Update im cam-o-mat-Container (Proxmox-LXC). Der systemd-Timer cam-o-mat-update ruft es alle 5 Minuten auf
# (cam-o-mat-lxc.sh autoupdate legt ihn an); das Log steht im Journal (journalctl -u cam-o-mat-update).
#
# 1. Ist main auf GitHub weiter als der Checkout, wird nachgezogen (nur vorwärts, git pull --ff-only).
# 2. Dann holt docker compose die Images von ghcr.io. GitHub Actions baut sie nach jedem Push auf main; das dauert
#    ein, zwei Minuten, deshalb wird bei jedem Lauf nachgesehen, nicht nur nach einem neuen Commit. Neu angelegt
#    wird ein Container nur, wenn sein Image sich geändert hat.
#
# Nur auf dem Branch main. Der ganze Text steht in { }, damit bash ihn vor dem Ausführen ganz liest:
# der git pull darf diese Datei ändern, während sie läuft.
{
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/cam-o-mat}"
export GIT_TERMINAL_PROMPT=0
cd "$APP_DIR"

branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
if [ "$branch" != main ]; then
  echo "Checkout steht auf ${branch:-keinem Branch}, nicht main; nichts getan."
  exit 0
fi

git fetch -q origin main
head=$(git rev-parse HEAD)
remote=$(git rev-parse origin/main)
neu=0
if [ "$head" != "$remote" ] && ! git merge-base --is-ancestor "$remote" "$head"; then
  echo "Update ${head:0:7} -> ${remote:0:7}:"
  git log --format='    %h %s' "$head..$remote"
  git pull -q --ff-only origin main
  ./kameras.sh gen
  neu=1
fi

if ! docker compose pull -q 2>/dev/null; then
  # Etwa, solange die Pakete auf ghcr.io noch privat sind: dann hier bauen.
  echo "Images von ghcr.io nicht ladbar, baue sie hier."
  docker compose pull -q tailscale || true
  docker compose build -q
fi
vorher=$(docker compose ps -q | sort)
docker compose up -d --remove-orphans 2>&1 | grep -vE 'Running|Started|^$' || true
# Neuer Commit: go2rtc und web lesen generated/ nur beim Start.
[ "$neu" = 1 ] && docker compose restart go2rtc web > /dev/null
if [ "$neu" = 1 ] || [ "$vorher" != "$(docker compose ps -q | sort)" ]; then
  docker image prune -f > /dev/null || true
  echo "$(git rev-parse --short HEAD) läuft."
fi
exit 0
}
