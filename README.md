# Hundecam

Kleine Handy-Seite für eine oder mehrere ESP32-CAMs (Prusa-Firmware). Sie ist nur in deinem Tailnet erreichbar:
`https://cam-o-mat.<dein-tailnet>.ts.net`

```
Handy (Tailscale-App) ──HTTPS──▶ tailscale ──▶ web (Caddy) :8080 ──▶ Seite (web/)
                                                  ├─▶ go2rtc ──▶ ESP32 /stream.mjpg (Stream, verteilt an alle Zuschauer)
                                                  └─▶ verwaltung ──▶ kameras.conf (Kamera hinzufügen)
                                                                 └─▶ ESP32 /light (Licht an/aus)
```

![Vorschau](docs/vorschau.png)

**Funktionen:** Live-Bild, Umschalten zwischen Kameras, neue Kamera per USB flashen und eintragen, Licht an/aus, Foto speichern, Bild um 180° drehen, Vollbild (auf dem iPhone über der Seite, Antippen schließt).
Wenn die App im Hintergrund ist, pausiert der Stream. Fällt eine Kamera aus, verbindet sich die Seite automatisch neu.

## Voraussetzungen

- Ein Gerät im Heimnetz, das dauerhaft läuft und Docker hat (Raspberry Pi, NAS, Server)
- In der Tailscale-Admin-Konsole unter **DNS** sind **MagicDNS** und **HTTPS Certificates** aktiviert
- Die ESP32-CAM hat eine feste IP (im Router reservieren)

## Einrichten auf Proxmox (empfohlen)

In der Shell des Proxmox-Hosts als root:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Marcel-B/cam-o-mat/main/deploy/proxmox/cam-o-mat-lxc.sh)"
```

Das Skript legt einen kleinen unprivilegierten Debian-LXC `cam-o-mat` an (1 Kern, 512 MB, 4 GB), installiert Docker, holt dieses Repository nach `/opt/cam-o-mat`, fragt nach dem Tailscale-Auth-Key (und optional nach dem Passwort der Kamera) und startet alles. Am Ende prüft es Container, Kameras und Seite und zeigt die Tailnet-Adresse. Tailscale läuft im Container im Userspace, am Proxmox-Host ist dafür nichts einzustellen.

| Befehl | Was passiert |
| --- | --- |
| `cam-o-mat-lxc.sh` | alles: Container anlegen, App einrichten |
| `cam-o-mat-lxc.sh update` | `main` holen, Images ziehen, neu starten |
| `cam-o-mat-lxc.sh pruefen` | Container, Kameras und Tailnet-Adresse prüfen |
| `cam-o-mat-lxc.sh logs` | die letzten Zeilen von tailscale, go2rtc, web und verwaltung |
| `cam-o-mat-lxc.sh kamera list` | Kameras anzeigen |
| `cam-o-mat-lxc.sh kamera add <name> <ip> [Anzeigename]` | Kamera hinzufügen (oder ihre IP ändern), danach neu starten |
| `cam-o-mat-lxc.sh kamera rm <name>` | Kamera entfernen |
| `cam-o-mat-lxc.sh autoupdate [on\|off\|status\|run]` | Auto-Update, siehe unten (`app` schaltet es ein) |

Ohne Container-ID nimmt das Skript den Container namens `cam-o-mat`. Weitere Einstellungen über Umgebungsvariablen, siehe `--help` (z. B. `IP=192.168.2.60/24 GATEWAY=192.168.2.1`).

## Einrichten von Hand (beliebiger Docker-Rechner)

1. Dieses Repository auf das Gerät klonen.
2. `./kameras.sh list` legt `kameras.conf` an (mit `hund 192.168.2.134`); weitere mit `./kameras.sh add <name> <ip>`.
3. `.env.example` nach `.env` kopieren und einen Auth-Key eintragen (https://login.tailscale.com/admin/settings/keys).
4. `docker compose up -d`
5. Auf dem Handy mit Tailscale `https://cam-o-mat.<dein-tailnet>.ts.net` öffnen und „Zum Home-Bildschirm“ hinzufügen.

## Kamera hinzufügen (per USB)

Auf der Seite steht hinter den Kameras **+ Kamera hinzufügen**. Damit wird eine neue ESP32-CAM in einem Rutsch eingerichtet:

1. Name eintragen, wo sie steht (z. B. „Küche oben“), dazu WLAN-Name und -Passwort.
2. Kamera auf dem USB-Board **ESP32-CAM-MB** an den Computer stecken und **Per USB verbinden** wählen.
3. Die Seite löscht die Kamera, spielt die [Prusa-Firmware](https://github.com/prusa3d/Prusa-Firmware-ESP32-Cam) auf, stellt über die serielle Konsole das WLAN ein, fragt die IP ab und trägt die Kamera in `kameras.conf` ein. go2rtc lädt neu, die Kamera erscheint sofort in der Liste.
4. Abstecken, an einem USB-Netzteil an ihren Platz stellen und im Router eine feste IP für sie reservieren (die MAC-Adresse zeigt die Seite an).

Ohne den Haken bei *Firmware aufspielen* wird nur das WLAN einer Kamera eingestellt, die die Prusa-Firmware schon hat.

**Grenzen:**

- Geht nur in **Chrome oder Edge am Computer** (Web Serial). iPhone, Safari und Firefox können kein USB-Seriell.
- Nur für die **Ai-Thinker ESP32-CAM** (ESP32 mit OV2640). Andere Boards lehnt die Seite ab.
- Das MB-Board schaltet die Kamera normalerweise selbst in den Flash-Modus. Klappt das Verbinden nicht: Taste **IO0** halten, kurz **RST** drücken, IO0 loslassen, nochmal. Mit einem einfachen USB-Seriell-Adapter (FTDI) muss IO0 beim Verbinden an GND; nach dem Flashen die Brücke entfernen und RST drücken, die Seite wartet darauf.
- Die ESP32-CAM kann nur **2,4-GHz-WLAN**.
- Das WLAN-Passwort geht nur an die Kamera, der Server speichert es nicht. Ein Kamera-Passwort (`CAM_BASIC_AUTH`) setzt die Seite nicht; das wie unten in der Weboberfläche der Kamera einstellen.
- Eintragen kann jeder, der die Seite im Tailnet öffnen kann.

Firmware und Flash-Werkzeug ([esptool-js](https://github.com/espressif/esptool-js) von Espressif) kommen beim Bauen des Images mit festen Versionen und Prüfsummen hinein (`docker/web/Dockerfile`); zur Laufzeit lädt die Seite nichts von fremden Servern. Eingetragen wird über den kleinen Dienst `verwaltung` (`verwaltung.py`, läuft im go2rtc-Image und nur intern), der auch das Licht schaltet.

## Kameras

Die Kameras stehen in `kameras.conf`, eine Zeile pro Kamera (`name ip [Anzeigename]`). Die Datei liegt nur auf dem Server, nicht im Repository; ein Update ändert sie nicht. `kameras.sh` schreibt daraus `generated/kameras.yaml` (go2rtc) und startet go2rtc neu:

```sh
./kameras.sh add wohnzimmer 192.168.2.140
./kameras.sh add kueche 192.168.2.141 Küche oben   # mit Anzeigename
./kameras.sh rm wohnzimmer
./kameras.sh list
```

Auf Proxmox dasselbe vom Host aus: `cam-o-mat-lxc.sh kamera add wohnzimmer 192.168.2.140`. Die Seite zeigt neue Kameras nach dem Neuladen; beschriftet wird mit dem Anzeigenamen, sonst mit dem Namen (`wohnzimmer` → „Wohnzimmer“). Ein gemeinsames Kamera-Passwort (`CAM_BASIC_AUTH`) gilt für alle.

## Images und Auto-Update

GitHub Actions (`.github/workflows/images.yml`) baut bei jedem Push auf `main` zwei Images und legt sie nach ghcr.io:

- `ghcr.io/marcel-b/cam-o-mat-web`: Caddy mit `Caddyfile`, `web/`, esptool-js und der Prusa-Firmware
- `ghcr.io/marcel-b/cam-o-mat-go2rtc`: go2rtc mit `go2rtc.yaml`, `esp-mjpeg.sh` und `verwaltung.py` (startet auch den Dienst `verwaltung`)

**Einmalig:** Auf GitHub unter *Packages* beide Pakete auf *Public* stellen (Package settings → Change visibility), sonst kann der Server sie nicht ohne Anmeldung laden. Bis dahin baut er sie selbst.

Im LXC läuft der systemd-Timer `cam-o-mat-update` alle 5 Minuten (`deploy/proxmox/update-in-ct.sh`): Ist `main` auf GitHub neuer, zieht er nach und schreibt die Kamera-Konfig neu; danach holt er die Images und legt nur Container neu an, deren Image sich geändert hat. Das passiert bei jedem Lauf, weil Actions nach einem Push noch ein, zwei Minuten baut. Das Auto-Update greift nur, wenn der Checkout auf `main` steht. Log: `pct exec <CTID> -- journalctl -u cam-o-mat-update`.

Von Hand bauen statt laden: `docker compose up -d --build`.

## Tipps für die ESP32-CAM

- In der Kamera-Weboberfläche ein Passwort setzen (Basic Auth) und es in `.env` als `CAM_BASIC_AUTH` eintragen, damit nur der Server das Licht schalten kann. Achtung: Den Stream selbst schützt die Firmware nicht mit dem Passwort. Er bleibt im Heimnetz offen.
- Den Prusa-Connect-Token leer lassen, dann lädt die Kamera nichts zu Prusa hoch.
- Auflösung SVGA oder XGA ist ein guter Kompromiss aus Bildqualität und Bildrate.
