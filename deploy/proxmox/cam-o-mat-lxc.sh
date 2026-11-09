#!/usr/bin/env bash
# cam-o-mat (Hundecam) in einem Proxmox-LXC-Container mit Docker installieren oder aktualisieren.
# Läuft in der Shell des Proxmox-VE-Hosts (als root). Im Container laufen Tailscale (Userspace, kein /dev/net/tun nötig),
# go2rtc und Caddy per docker compose. Die Seite ist nur im Tailnet erreichbar: https://cam-o-mat.<tailnet>.ts.net
# Aufruf: --help, Einzelheiten im README.

set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/Marcel-B/cam-o-mat.git}"
REPO_BRANCH_GESETZT="${REPO_BRANCH:+1}"
REPO_BRANCH="${REPO_BRANCH:-main}"
APP_DIR=/opt/cam-o-mat

CT_HOSTNAME="${CT_HOSTNAME:-cam-o-mat}"
TS_HOSTNAME="${TS_HOSTNAME:-$CT_HOSTNAME}"
CORES="${CORES:-1}"
MEMORY="${MEMORY:-512}"
DISK="${DISK:-4}"
BRIDGE="${BRIDGE:-vmbr0}"
IP="${IP:-dhcp}"
GATEWAY="${GATEWAY:-}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
CAM_BASIC_AUTH="${CAM_BASIC_AUTH:-}"

NICHT_FRAGEN="${NONINTERACTIVE:-0}"

info() { printf '\e[1;34m==>\e[0m %s\n' "$*" >&2; }
ok() { printf '\e[1;32m ok\e[0m %s\n' "$*" >&2; }
warn() { printf '\e[1;33m !!\e[0m %s\n' "$*" >&2; }
abbruch() {
    printf '\e[1;31mFehler:\e[0m %s\n' "$*" >&2
    exit 1
}
trap 'abbruch "Befehl in Zeile $LINENO fehlgeschlagen: $BASH_COMMAND"' ERR

if [[ -f ${BASH_SOURCE[0]:-} ]]; then
    AUFRUF="bash $(realpath "${BASH_SOURCE[0]}")"
else
    AUFRUF="bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Marcel-B/cam-o-mat/main/deploy/proxmox/cam-o-mat-lxc.sh)\" --"
fi

hilfe() {
    cat <<EOF
cam-o-mat (Hundecam) in einem Proxmox-LXC-Container installieren oder aktualisieren (auf dem PVE-Host als root).

Aufruf: $AUFRUF [-y] [anlegen | app | update | pruefen | logs | kamera … | autoupdate …]  (jeweils optional <CTID>)

  (ohne)          alles der Reihe nach: anlegen, app
  anlegen         Schritt 1: Container anlegen (oder den namens $CT_HOSTNAME nehmen) und Docker installieren
  app <CTID>      Schritt 2: cam-o-mat holen, .env mit Tailscale-Auth-Key anlegen, starten, prüfen
  update <CTID>   git pull, Images von ghcr.io holen, neu starten; .env, Kameras und Tailscale-Login bleiben
  pruefen <CTID>  Container, Kameras und Tailnet-Adresse prüfen
  logs <CTID>     die letzten Zeilen von tailscale, go2rtc, web und verwaltung
  kamera [<CTID>] list | add <name> <ip> [Anzeigename] | rm <name>
                  Kameras verwalten (kameras.conf im Container), danach neu starten
  autoupdate [<CTID>] [on|off|status|run]
                  alle 5 Minuten main holen, wenn neu, und neue Images ziehen
                  (systemd-Timer cam-o-mat-update; app schaltet es ein)
  -y              ohne Rückfragen, Werte aus Umgebungsvariablen

Variablen (Vorgabe): CTID (nächste freie bzw. Container namens cam-o-mat), CT_HOSTNAME (cam-o-mat),
TS_HOSTNAME (wie CT_HOSTNAME, Name im Tailnet), CORES (1), MEMORY (512), DISK (4), BRIDGE (vmbr0),
IP (dhcp, sonst z. B. 192.168.2.60/24), GATEWAY, CT_STORAGE, TEMPLATE_STORAGE, TS_AUTHKEY,
CAM_BASIC_AUTH (base64 von benutzer:passwort der Kamera), REPO_URL, REPO_BRANCH (main).

Beispiel: $AUFRUF kamera add wohnzimmer 192.168.2.140
EOF
}

frage() {
    local var=$1 text=$2 eingabe
    [[ $NICHT_FRAGEN == 1 ]] && return 0
    read -rp "$text [${!var}]: " eingabe
    [[ -n $eingabe ]] && printf -v "$var" '%s' "$eingabe"
    return 0
}

pruefe_host() {
    [[ $EUID -eq 0 ]] || abbruch "Bitte als root in der Proxmox-Shell ausführen."
    command -v pct >/dev/null && command -v pveam >/dev/null \
        || abbruch "pct/pveam nicht gefunden. Das Skript muss auf einem Proxmox-VE-Host laufen."
}

storage_mit() {
    local inhalt=$1 bevorzugt=${2:-} liste
    liste=$(pvesm status -content "$inhalt" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
    if [[ -n $bevorzugt ]] && grep -qx "$bevorzugt" <<<"$liste"; then
        echo "$bevorzugt"
    else
        head -n1 <<<"$liste"
    fi
}

im_ct() { pct exec "$CTID" -- env DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 "$@"; }
compose() { im_ct bash -c "cd '$APP_DIR' && docker compose $*"; }

# Der Container mit dem Namen CT_HOSTNAME, falls es ihn gibt.
ct_nach_name() { pct list | awk -v name="$CT_HOSTNAME" 'NR > 1 && $NF == name { print $1; exit }'; }

# --- Schritt 1: Container

waehle_vorlage() {
    local version name
    info "Suche Debian-Vorlage"
    pveam update >/dev/null 2>&1 || warn "pveam update fehlgeschlagen, nutze vorhandene Liste"
    for version in ${DEBIAN_VERSION:-12 13}; do
        name=$(pveam available --section system 2>/dev/null | awk '{print $2}' \
            | grep -E "^debian-${version}-standard_.*amd64" | sort -V | tail -n1 || true)
        if [[ -n $name ]]; then
            VORLAGE=$name
            break
        fi
    done
    [[ -n ${VORLAGE:-} ]] || abbruch "Keine Debian-Vorlage gefunden (pveam available --section system)."
    if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$VORLAGE"; then
        ok "Vorlage $VORLAGE schon vorhanden"
    else
        info "Lade $VORLAGE nach $TEMPLATE_STORAGE"
        pveam download "$TEMPLATE_STORAGE" "$VORLAGE" >/dev/null
    fi
}

warte_auf_netz() {
    local _
    for _ in $(seq 1 30); do
        im_ct getent hosts github.com >/dev/null 2>&1 && return 0
        sleep 2
    done
    abbruch "Container $CTID hat kein Netz (DNS für github.com schlägt fehl). Bridge/IP prüfen."
}

anlegen() {
    info "Schritt 1: Container"
    local vorhanden
    vorhanden=$(ct_nach_name)
    if [[ -n $vorhanden ]]; then
        CTID=$vorhanden
        ok "Container $CTID ($CT_HOSTNAME) gibt es schon"
    else
        CTID="${CTID:-$(pvesh get /cluster/nextid)}"
        CT_STORAGE="${CT_STORAGE:-$(storage_mit rootdir local-lvm)}"
        TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-$(storage_mit vztmpl local)}"
        frage CTID "Container-ID"
        frage CT_HOSTNAME "Name"
        frage IP "IP (dhcp oder z. B. 192.168.2.60/24)"
        if [[ $IP != dhcp ]]; then frage GATEWAY "Gateway"; fi
        waehle_vorlage
        local netz="name=eth0,bridge=$BRIDGE,ip=$IP"
        [[ $IP != dhcp && -n $GATEWAY ]] && netz+=",gw=$GATEWAY"
        info "Lege Container $CTID ($CT_HOSTNAME) an"
        # Unprivilegiert; Docker darin braucht nesting und keyctl. Tailscale läuft im Userspace, also kein /dev/net/tun.
        pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$VORLAGE" \
            --hostname "$CT_HOSTNAME" --description "cam-o-mat: Hundecam im Tailnet, https://github.com/Marcel-B/cam-o-mat" \
            --memory "$MEMORY" --swap 512 --cores "$CORES" \
            --rootfs "$CT_STORAGE:$DISK" \
            --net0 "$netz" \
            --unprivileged 1 --features nesting=1,keyctl=1 \
            --onboot 1 >/dev/null
        ok "Container $CTID angelegt"
    fi
    [[ $(pct status "$CTID" | awk '{print $2}') == running ]] || pct start "$CTID"
    warte_auf_netz
    info "Installiere Docker im Container"
    im_ct bash -c 'apt-get update -qq && apt-get install -y -qq ca-certificates curl git >/dev/null
        command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh >/dev/null
        systemctl enable --now docker >/dev/null'
    ok "Docker $(im_ct docker --version | awk '{print $3}' | tr -d ,)"
}

# --- Schritt 2: App

hole_stand() {
    if im_ct test -d "$APP_DIR/.git"; then
        # Ohne REPO_BRANCH bleibt ein vorhandener Checkout auf seinem Zweig.
        [[ -n $REPO_BRANCH_GESETZT ]] || REPO_BRANCH=$(im_ct git -C "$APP_DIR" rev-parse --abbrev-ref HEAD)
        im_ct git -C "$APP_DIR" fetch -q origin "$REPO_BRANCH"
        im_ct git -C "$APP_DIR" checkout -q -B "$REPO_BRANCH" FETCH_HEAD
    else
        im_ct git clone -q --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
    fi
    ok "Stand $(im_ct git -C "$APP_DIR" log -1 --format='%h %s') ($REPO_BRANCH)"
}

schreibe_env() {
    # Ist Tailscale schon angemeldet, wird der Auth-Key nicht mehr gebraucht (Login liegt in tailscale-state/).
    if im_ct test -f "$APP_DIR/.env"; then
        ok ".env gibt es schon (ändern: pct exec $CTID -- nano $APP_DIR/.env, dann update)"
        return 0
    fi
    if [[ -z $TS_AUTHKEY && $NICHT_FRAGEN != 1 ]]; then
        echo >&2
        info "Tailscale-Auth-Key anlegen: https://login.tailscale.com/admin/settings/keys (einmal verwendbar reicht)"
        read -rsp "Auth-Key (tskey-auth-…): " TS_AUTHKEY
        echo >&2
    fi
    [[ $TS_AUTHKEY == tskey-* ]] || abbruch "Kein gültiger Tailscale-Auth-Key (TS_AUTHKEY=tskey-auth-…)."
    if [[ -z $CAM_BASIC_AUTH && $NICHT_FRAGEN != 1 ]]; then
        local benutzer passwort
        read -rp "Basic Auth der Kamera, Benutzer (leer = keine): " benutzer
        if [[ -n $benutzer ]]; then
            read -rsp "Passwort: " passwort
            echo >&2
            CAM_BASIC_AUTH=$(printf '%s:%s' "$benutzer" "$passwort" | base64 -w0)
        fi
    fi
    local datei
    datei=$(mktemp)
    chmod 600 "$datei"
    printf 'TS_AUTHKEY=%s\nTS_HOSTNAME=%s\nCAM_BASIC_AUTH=%s\n' "$TS_AUTHKEY" "$TS_HOSTNAME" "$CAM_BASIC_AUTH" >"$datei"
    pct push "$CTID" "$datei" "$APP_DIR/.env" --perms 600
    rm -f "$datei"
    ok ".env angelegt (Tailnet-Name $TS_HOSTNAME)"
}

app() {
    info "Schritt 2: cam-o-mat in Container $CTID"
    hole_stand
    schreibe_env
    im_ct bash "$APP_DIR/kameras.sh" gen
    info "Hole Images und starte"
    hole_images
    compose up -d --remove-orphans >/dev/null
    pruefen
    autoupdate on
}

# Images von ghcr.io; geht das nicht (Pakete noch privat?), hier bauen.
hole_images() {
    if ! compose pull -q 2>/dev/null; then
        warn "Images von ghcr.io nicht ladbar (Pakete öffentlich gestellt?), baue sie im Container"
        compose pull -q tailscale || true
        compose build -q
    fi
}

update() {
    info "Aktualisiere cam-o-mat in Container $CTID"
    hole_stand
    im_ct bash "$APP_DIR/kameras.sh" gen
    hole_images
    # go2rtc und web lesen generated/ nur beim Start: neu anlegen.
    compose up -d --remove-orphans >/dev/null
    compose up -d --force-recreate --no-deps go2rtc web >/dev/null
    im_ct docker image prune -f >/dev/null
    pruefen
}

logs() { compose logs --tail 30 tailscale go2rtc web verwaltung; }

kamera() {
    im_ct bash "$APP_DIR/kameras.sh" "${KAMERA_ARGS[@]+"${KAMERA_ARGS[@]}"}"
}

# Der Timer ruft update-in-ct.sh aus dem Checkout auf; so kommt mit jedem Update auch dessen neue Fassung.
autoupdate() {
    case ${1:-on} in
        on)
            im_ct bash -c "cat > /etc/systemd/system/cam-o-mat-update.service <<'UNIT'
[Unit]
Description=cam-o-mat: main holen und neue Images ziehen
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $APP_DIR/deploy/proxmox/update-in-ct.sh
UNIT
cat > /etc/systemd/system/cam-o-mat-update.timer <<'UNIT'
[Unit]
Description=cam-o-mat: Auto-Update alle 5 Minuten

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload && systemctl enable --now cam-o-mat-update.timer >/dev/null"
            local zweig
            zweig=$(im_ct git -C "$APP_DIR" rev-parse --abbrev-ref HEAD)
            ok "Auto-Update an: alle 5 Minuten (Log: pct exec $CTID -- journalctl -u cam-o-mat-update)"
            [[ $zweig == main ]] || warn "Der Checkout steht auf $zweig; das Auto-Update greift erst auf main ($AUFRUF update mit REPO_BRANCH=main)"
            ;;
        off)
            im_ct bash -c 'systemctl disable --now cam-o-mat-update.timer >/dev/null 2>&1; rm -f /etc/systemd/system/cam-o-mat-update.{service,timer}; systemctl daemon-reload'
            ok "Auto-Update aus"
            ;;
        status)
            im_ct systemctl list-timers cam-o-mat-update.timer --no-pager || true
            im_ct journalctl -u cam-o-mat-update -n 15 --no-pager || true
            ;;
        run)
            im_ct systemctl start cam-o-mat-update.service
            im_ct journalctl -u cam-o-mat-update -n 15 --no-pager || true
            ;;
        *) abbruch "autoupdate: on, off, status oder run" ;;
    esac
}

pruefen() {
    info "Prüfe"
    local laufend
    laufend=$(compose ps --status running --services 2>/dev/null | tr '\n' ' ' || true)
    for dienst in web go2rtc verwaltung tailscale; do
        if [[ " $laufend " == *" $dienst "* ]]; then ok "$dienst läuft"; else warn "$dienst läuft nicht ($AUFRUF logs $CTID)"; fi
    done

    # Kameras aus kameras.conf im Heimnetz erreichbar?
    local name ip code
    while read -r name ip _; do
        [[ -n $name ]] || continue
        code=$(im_ct curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://$ip/" 2>/dev/null || true)
        if [[ -n $code && $code != 000 ]]; then
            ok "Kamera $name erreichbar ($ip)"
        else
            warn "Kamera $name antwortet nicht: $ip (an? feste IP im Router?)"
        fi
    done < <(im_ct bash "$APP_DIR/kameras.sh" list 2>/dev/null)

    # Antwortet die Seite (Caddy -> go2rtc) im Netz des Tailscale-Containers?
    local streams=""
    for _ in $(seq 1 15); do
        streams=$(compose exec -T web wget -qO- http://127.0.0.1:8080/api/streams 2>/dev/null) && break
        sleep 2
    done
    if [[ -n $streams ]]; then ok "Seite und go2rtc antworten"; else warn "Seite antwortet nicht ($AUFRUF logs $CTID)"; fi

    # Adresse im Tailnet
    local name_ts=""
    for _ in $(seq 1 15); do
        name_ts=$(compose exec -T tailscale tailscale status --json 2>/dev/null \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null) && [[ -n $name_ts ]] && break
        sleep 2
    done
    echo >&2
    if [[ -n $name_ts ]]; then
        ok "cam-o-mat: https://$name_ts   (nur im Tailnet; das erste Laden holt das Zertifikat und dauert etwas)"
    else
        warn "Tailscale ist noch nicht angemeldet. Auth-Key prüfen: $AUFRUF logs $CTID"
    fi
}

# --- Ablauf

pruefe_host
SCHRITT=alles
while [[ $# -gt 0 ]]; do
    case $1 in
        -h | --help) hilfe; exit 0 ;;
        -y) NICHT_FRAGEN=1 ;;
        anlegen) SCHRITT=$1 ;;
        on | off | status | run)
            [[ ${SCHRITT:-} == autoupdate ]] || { hilfe; abbruch "Unbekannt: $1"; }
            AKTION=$1
            ;;
        kamera)
            SCHRITT=kamera
            if [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]]; then
                CTID=$2
                shift
            else
                CTID=$(ct_nach_name)
            fi
            [[ -n ${CTID:-} ]] || abbruch "kamera braucht die Container-ID"
            shift
            KAMERA_ARGS=("$@")
            break
            ;;
        app | update | pruefen | logs | autoupdate)
            SCHRITT=$1
            if [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]]; then
                CTID=$2
                shift
            else
                CTID=$(ct_nach_name)
            fi
            [[ -n ${CTID:-} ]] || abbruch "$1 braucht die Container-ID"
            ;;
        *) hilfe; abbruch "Unbekannt: $1" ;;
    esac
    shift
done

case $SCHRITT in
    anlegen) anlegen; echo >&2; ok "Weiter mit: $AUFRUF app $CTID" ;;
    app) app ;;
    update) update ;;
    pruefen) pruefen ;;
    logs) logs ;;
    kamera) kamera ;;
    autoupdate) autoupdate "${AKTION:-on}" ;;
    alles) anlegen; app ;;
esac
