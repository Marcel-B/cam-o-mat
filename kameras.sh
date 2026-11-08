#!/usr/bin/env bash
# Kameras von cam-o-mat verwalten. Die Liste steht in kameras.conf (eine Zeile pro Kamera: "name ip"),
# daraus entstehen generated/kameras.yaml (go2rtc) und generated/kameras.caddy (Licht-Schalter).
# kameras.conf ist nicht im Repository; fehlt sie, wird sie aus kameras.conf.example angelegt.
#
#   ./kameras.sh list
#   ./kameras.sh add <name> <ip>     z. B. ./kameras.sh add wohnzimmer 192.168.2.140
#   ./kameras.sh rm <name>
#   ./kameras.sh gen                 nur die Dateien neu schreiben (macht auch das Proxmox-Skript)
#
# add und rm starten go2rtc und web danach neu (docker compose), ausser mit --no-restart.

set -Eeuo pipefail
cd "$(dirname "$(realpath "$0")")"

CONF=kameras.conf
GEN=generated

abbruch() {
    printf 'Fehler: %s\n' "$*" >&2
    exit 1
}

# Zeilen "name ip" ohne Kommentare und Leerzeilen
eintraege() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$CONF"; }

sicherstellen() {
    if [[ ! -f $CONF ]]; then
        if [[ -f $CONF.example ]]; then cp "$CONF.example" "$CONF"; else : >"$CONF"; fi
    fi
}

gen() {
    mkdir -p "$GEN"
    local name ip yaml caddy
    yaml="# Erzeugt von kameras.sh aus $CONF - nicht von Hand ändern.
streams:"
    caddy="# Erzeugt von kameras.sh aus $CONF - nicht von Hand ändern."
    while read -r name ip _; do
        yaml+=$'\n'"  $name: exec:sh /app/esp-mjpeg.sh http://$ip/stream.mjpg"
        caddy+=$'\n'"import cam $name $ip"
    done < <(eintraege)
    # Ohne Kamera wäre "streams:" null; go2rtc mag dann eine leere Map lieber.
    [[ $yaml == *exec:* ]] || yaml+=" {}"
    printf '%s\n' "$yaml" >"$GEN/kameras.yaml.tmp" && mv "$GEN/kameras.yaml.tmp" "$GEN/kameras.yaml"
    printf '%s\n' "$caddy" >"$GEN/kameras.caddy.tmp" && mv "$GEN/kameras.caddy.tmp" "$GEN/kameras.caddy"
}

neustart() {
    [[ ${NO_RESTART:-0} == 1 ]] && return 0
    if command -v docker >/dev/null && docker compose ps --services --status running 2>/dev/null | grep -q go2rtc; then
        docker compose restart go2rtc web >/dev/null
        echo "go2rtc und web neu gestartet. Seite neu laden."
    fi
}

liste() {
    local name ip
    while read -r name ip _; do printf '  %-16s %s\n' "$name" "$ip"; done < <(eintraege)
}

pruefe_name() {
    [[ $1 =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || abbruch "Name nur aus Kleinbuchstaben, Ziffern, - und _ (z. B. wohnzimmer)."
}

ARGS=()
for a in "$@"; do
    if [[ $a == --no-restart ]]; then NO_RESTART=1; else ARGS+=("$a"); fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

sicherstellen
case ${1:-list} in
    list)
        liste
        ;;
    add)
        [[ $# -eq 3 ]] || abbruch "Aufruf: $0 add <name> <ip>"
        pruefe_name "$2"
        [[ $3 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]+)?$ ]] || abbruch "Keine IP-Adresse: $3"
        if eintraege | awk -v n="$2" '$1 == n { f = 1 } END { exit !f }'; then
            # vorhandene Kamera: IP ersetzen
            sed -i -E "s/^([[:space:]]*$2)[[:space:]]+[^[:space:]#]+/\1 $3/" "$CONF"
            echo "Kamera $2 jetzt unter $3."
        else
            printf '%s %s\n' "$2" "$3" >>"$CONF"
            echo "Kamera $2 ($3) hinzugefügt."
        fi
        gen
        neustart
        liste
        ;;
    rm)
        [[ $# -eq 2 ]] || abbruch "Aufruf: $0 rm <name>"
        pruefe_name "$2"
        eintraege | awk -v n="$2" '$1 == n { f = 1 } END { exit !f }' || abbruch "Keine Kamera namens $2."
        sed -i -E "/^[[:space:]]*$2[[:space:]]/d" "$CONF"
        echo "Kamera $2 entfernt."
        gen
        neustart
        liste
        ;;
    gen)
        gen
        ;;
    *)
        sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
