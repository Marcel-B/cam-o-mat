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

Aufruf: $AUFRUF [-y] [anlegen | app <CTID> | update <CTID> | pruefen <CTID> | logs <CTID>]

  (ohne)          alles der Reihe nach: anlegen, app
  anlegen         Schritt 1: Container anlegen (oder den namens $CT_HOSTNAME nehmen) und Docker installieren
  app <CTID>      Schritt 2: cam-o-mat holen, .env mit Tailscale-Auth-Key anlegen, starten, prüfen
  update <CTID>   git pull, neue Abbilder holen, neu starten; .env und Tailscale-Login bleiben
  pruefen <CTID>  Container, Kameras und Tailnet-Adresse prüfen
  logs <CTID>     die letzten Zeilen von tailscale, go2rtc und caddy
  -y              ohne Rückfragen, Werte aus Umgebungsvariablen

Variablen (Vorgabe): CTID (nächste freie bzw. Container namens cam-o-mat), CT_HOSTNAME (cam-o-mat),
TS_HOSTNAME (wie CT_HOSTNAME, Name im Tailnet), CORES (1), MEMORY (512), DISK (4), BRIDGE (vmbr0),
IP (dhcp, sonst z. B. 192.168.2.60/24), GATEWAY, CT_STORAGE, TEMPLATE_STORAGE, TS_AUTHKEY,
CAM_BASIC_AUTH (base64 von benutzer:passwort der Kamera), REPO_URL, REPO_BRANCH (main).

Kameras stehen in go2rtc.yaml und Caddyfile im Repository; nach einer Änderung dort: update.
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
    info "Hole Abbilder und starte"
    compose pull -q
    compose up -d --remove-orphans >/dev/null
    pruefen
}

update() {
    info "Aktualisiere cam-o-mat in Container $CTID"
    hole_stand
    compose pull -q
    compose up -d --remove-orphans >/dev/null
    # Caddy und go2rtc lesen ihre Konfig nur beim Start; nach einer Kamera-Änderung also neu starten.
    compose restart go2rtc caddy >/dev/null
    im_ct docker image prune -f >/dev/null
    pruefen
}

logs() { compose logs --tail 30 tailscale go2rtc caddy; }

pruefen() {
    info "Prüfe"
    local laufend
    laufend=$(compose ps --status running --services 2>/dev/null | tr '\n' ' ' || true)
    for dienst in caddy go2rtc tailscale; do
        if [[ " $laufend " == *" $dienst "* ]]; then ok "$dienst läuft"; else warn "$dienst läuft nicht ($AUFRUF logs $CTID)"; fi
    done

    # Kameras aus go2rtc.yaml im Heimnetz erreichbar?
    local zeile name url code
    while IFS= read -r zeile; do
        name=${zeile%%:*}
        url=${zeile#*: }
        code=$(im_ct curl -s --max-time 5 -o /dev/null -w '%{http_code}' "${url%/stream.mjpg}/" 2>/dev/null || true)
        if [[ -n $code && $code != 000 ]]; then
            ok "Kamera $name erreichbar (${url%/stream.mjpg})"
        else
            warn "Kamera $name antwortet nicht: $url (an? feste IP im Router?)"
        fi
    done < <(im_ct sed -n '/^streams:/,/^[^ #]/{s/^  \([A-Za-z0-9_-]*\):.*\(http:\/\/[^ ]*\).*/\1: \2/p}' "$APP_DIR/go2rtc.yaml")

    # Antwortet die Seite (Caddy -> go2rtc) im Netz des Tailscale-Containers?
    local streams=""
    for _ in $(seq 1 15); do
        streams=$(compose exec -T caddy wget -qO- http://127.0.0.1:8080/api/streams 2>/dev/null) && break
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
        ok "Hundecam: https://$name_ts   (nur im Tailnet; das erste Laden holt das Zertifikat und dauert etwas)"
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
        app | update | pruefen | logs)
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
    alles) anlegen; app ;;
esac
