#!/usr/bin/env bash
# Kameras von cam-o-mat verwalten. Die Liste steht in kameras.conf (eine Zeile pro Kamera: "name ip [Anzeigename]"),
# daraus entsteht generated/kameras.yaml (go2rtc). "Kamera hinzufügen" auf der Seite schreibt dieselbe Datei.
# kameras.conf ist nicht im Repository; fehlt sie, wird sie aus kameras.conf.example angelegt.
#
#   ./kameras.sh list
#   ./kameras.sh add <name> <ip> [Anzeigename]   z. B. ./kameras.sh add kueche 192.168.2.140 Küche
#   ./kameras.sh rm <name>
#   ./kameras.sh gen                 nur die Datei neu schreiben (macht auch das Proxmox-Skript)
#
# add und rm starten go2rtc danach neu (docker compose), ausser mit --no-restart.

set -Eeuo pipefail
cd "$(dirname "$(realpath "$0")")"

CONF=kameras.conf
GEN=generated

abbruch() {
    printf 'Fehler: %s\n' "$*" >&2
    exit 1
}

# Zeilen "name ip [Anzeigename]" ohne Kommentare und Leerzeilen
eintraege() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$CONF"; }

sicherstellen() {
    if [[ ! -f $CONF ]]; then
        if [[ -f $CONF.example ]]; then cp "$CONF.example" "$CONF"; else : >"$CONF"; fi
    fi
}

gen() {
    mkdir -p "$GEN"
    local name ip yaml
    yaml="# Erzeugt von kameras.sh aus $CONF - nicht von Hand ändern.
streams:"
    while read -r name ip _; do
        yaml+=$'\n'"  $name: exec:sh /app/esp-mjpeg.sh http://$ip/stream.mjpg"
    done < <(eintraege)
    # Ohne Kamera wäre "streams:" null; go2rtc mag dann eine leere Map lieber.
    [[ $yaml == *exec:* ]] || yaml+=" {}"
    printf '%s\n' "$yaml" >"$GEN/kameras.yaml.tmp" && mv "$GEN/kameras.yaml.tmp" "$GEN/kameras.yaml"
    # Bis 2026-11: Licht-Schalter für Caddy; das macht jetzt verwaltung.py.
    rm -f "$GEN/kameras.caddy"
}

neustart() {
    [[ ${NO_RESTART:-0} == 1 ]] && return 0
    if command -v docker >/dev/null && docker compose ps --services --status running 2>/dev/null | grep -q go2rtc; then
        docker compose restart go2rtc >/dev/null
        echo "go2rtc neu gestartet. Seite neu laden."
    fi
}

liste() {
    local name ip label
    while read -r name ip label; do printf '  %-16s %-18s %s\n' "$name" "$ip" "$label"; done < <(eintraege)
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
        [[ $# -ge 3 ]] || abbruch "Aufruf: $0 add <name> <ip> [Anzeigename]"
        pruefe_name "$2"
        [[ $3 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]+)?$ ]] || abbruch "Keine IP-Adresse: $3"
        name=$2 ip=$3
        shift 3
        label=$(printf '%s' "$*" | tr -d '#')
        if eintraege | awk -v n="$name" '$1 == n { f = 1 } END { exit !f }'; then
            # vorhandene Kamera: IP ersetzen, Anzeigename nur, wenn einer angegeben ist
            awk -v n="$name" -v ip="$ip" -v l="$label" '
                { split($0, t, "#"); split(t[1], f, " ") }
                f[1] == n { if (l == "") { l = $0; sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]#]+[[:space:]]*/, "", l); sub(/[[:space:]]*#.*/, "", l) }
                            print n " " ip (l == "" ? "" : " " l); next }
                { print }' "$CONF" >"$CONF.tmp"
            cat "$CONF.tmp" >"$CONF" && rm -f "$CONF.tmp"
            echo "Kamera $name jetzt unter $ip."
        else
            printf '%s %s%s\n' "$name" "$ip" "${label:+ $label}" >>"$CONF"
            echo "Kamera $name ($ip) hinzugefügt."
        fi
        gen
        neustart
        liste
        ;;
    rm)
        [[ $# -eq 2 ]] || abbruch "Aufruf: $0 rm <name>"
        pruefe_name "$2"
        eintraege | awk -v n="$2" '$1 == n { f = 1 } END { exit !f }' || abbruch "Keine Kamera namens $2."
        sed -E "/^[[:space:]]*$2[[:space:]]/d" "$CONF" >"$CONF.tmp"
        cat "$CONF.tmp" >"$CONF" && rm -f "$CONF.tmp"
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
