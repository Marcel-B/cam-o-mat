#!/usr/bin/env python3
"""Verwaltung von cam-o-mat: Kameras eintragen (für "Kamera hinzufügen" auf der Seite) und Licht schalten.

Läuft im go2rtc-Image (Python ohne Zusatzpakete) und lauscht nur intern auf 127.0.0.1:8081; Caddy reicht
/api/kameras und /cam/<name>/light hierher weiter.

  GET  /api/kameras                -> [{"name", "ip", "label"}]
  POST /api/kameras                {"name", "ip", "label"} -> Kamera in kameras.conf eintragen (gleicher Name: ersetzen),
                                   generated/kameras.yaml neu schreiben und go2rtc neu laden
  GET  /cam/<name>/light?on|off    an die Kamera weiterreichen (mit CAM_BASIC_AUTH, falls gesetzt)

kameras.conf hat dasselbe Format wie bei kameras.sh: "name ip [Anzeigename]", eine Zeile pro Kamera.
"""

import ipaddress
import json
import os
import re
import socket
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

CONF = os.environ.get("KAMERAS_CONF", "/data/kameras.conf")
GEN = os.environ.get("KAMERAS_GEN", "/data/generated")
GO2RTC = os.environ.get("GO2RTC_API", "http://127.0.0.1:1984")
LISTEN = os.environ.get("LISTEN", "127.0.0.1:8081")
CAM_BASIC_AUTH = os.environ.get("CAM_BASIC_AUTH", "")

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
LABEL_MAX = 40
lock = threading.Lock()


def eintraege():
    """Kameras aus kameras.conf (ohne Kommentare und Leerzeilen)."""
    try:
        with open(CONF, encoding="utf-8") as f:
            zeilen = f.read().splitlines()
    except FileNotFoundError:
        return []
    kameras = []
    for zeile in zeilen:
        teile = zeile.split("#", 1)[0].split(None, 2)
        if len(teile) >= 2:
            kameras.append({"name": teile[0], "ip": teile[1], "label": teile[2].strip() if len(teile) > 2 else ""})
    return kameras


def gen(kameras):
    """generated/kameras.yaml schreiben, genau wie kameras.sh gen."""
    os.makedirs(GEN, exist_ok=True)
    zeilen = ["# Erzeugt von kameras.sh aus kameras.conf - nicht von Hand ändern.", "streams:"]
    for k in kameras:
        zeilen.append(f"  {k['name']}: exec:sh /app/esp-mjpeg.sh http://{k['ip']}/stream.mjpg")
    if not kameras:
        zeilen[-1] += " {}"
    tmp = os.path.join(GEN, "kameras.yaml.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(zeilen) + "\n")
    os.replace(tmp, os.path.join(GEN, "kameras.yaml"))


def eintragen(name, ip, label):
    """Zeile in kameras.conf setzen. Die Datei ist einzeln eingebunden, darum wird sie an Ort und Stelle
    geschrieben (kein Umbenennen); Kommentare und Reihenfolge bleiben."""
    neu = f"{name} {ip} {label}".rstrip()
    try:
        with open(CONF, encoding="utf-8") as f:
            zeilen = f.read().splitlines()
    except FileNotFoundError:
        zeilen = []
    ersetzt = False
    for i, zeile in enumerate(zeilen):
        teile = zeile.split("#", 1)[0].split()
        if teile and teile[0] == name:
            zeilen[i] = neu
            ersetzt = True
            break
    if not ersetzt:
        zeilen.append(neu)
    with open(CONF, "r+" if os.path.exists(CONF) else "w", encoding="utf-8") as f:
        f.seek(0)
        f.write("\n".join(zeilen) + "\n")
        f.truncate()
    return ersetzt


def go2rtc_neu_laden():
    """go2rtc liest seine Konfig neu ein (startet sich selbst neu, dauert etwa eine Sekunde)."""
    try:
        req = urllib.request.Request(GO2RTC + "/api/restart", method="POST")
        urllib.request.urlopen(req, timeout=5).close()
        return True
    except (urllib.error.URLError, OSError) as e:
        print(f"go2rtc nicht neu geladen: {e}", file=sys.stderr)
        return False


def erreichbar(ip):
    host, _, port = ip.partition(":")
    try:
        socket.create_connection((host, int(port or 80)), timeout=3).close()
        return True
    except OSError:
        return False


def pruefe_ip(ip):
    """Nur private IPv4-Adressen im Heimnetz, optional mit Port."""
    m = re.fullmatch(r"(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))?", ip or "")
    if not m:
        return False
    try:
        adresse = ipaddress.IPv4Address(m.group(1))
    except ValueError:
        return False
    return adresse.is_private and not adresse.is_loopback and not adresse.is_link_local and not adresse.is_unspecified


class Handler(BaseHTTPRequestHandler):
    server_version = "cam-o-mat-verwaltung"

    def antwort(self, code, daten):
        body = json.dumps(daten, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def fehler(self, code, text):
        self.antwort(code, {"fehler": text})

    def do_GET(self):
        pfad = urlsplit(self.path)
        if pfad.path == "/api/kameras":
            return self.antwort(200, eintraege())
        m = re.fullmatch(r"/cam/([^/]+)/light", pfad.path)
        if m and pfad.query in ("on", "off"):
            return self.licht(m.group(1), pfad.query)
        self.fehler(404, "Nicht gefunden")

    def licht(self, name, an_aus):
        kamera = next((k for k in eintraege() if k["name"] == name), None)
        if not kamera:
            return self.fehler(404, "Keine Kamera namens " + name)
        req = urllib.request.Request(f"http://{kamera['ip']}/light?{an_aus}")
        if CAM_BASIC_AUTH:
            req.add_header("Authorization", "Basic " + CAM_BASIC_AUTH)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                code = r.status
        except urllib.error.HTTPError as e:
            code = e.code
        except (urllib.error.URLError, OSError):
            return self.fehler(502, "Kamera nicht erreichbar")
        self.antwort(200 if code < 400 else 502, {"ok": code < 400, "kamera": code})

    def do_POST(self):
        if urlsplit(self.path).path != "/api/kameras":
            return self.fehler(404, "Nicht gefunden")
        # Nur von der eigenen Seite: JSON (erzwingt bei fremden Seiten eine CORS-Vorabfrage, die hier scheitert)
        # und, falls der Browser ihn schickt, ein passender Origin.
        if not self.headers.get("Content-Type", "").startswith("application/json"):
            return self.fehler(415, "Nur JSON")
        origin = self.headers.get("Origin")
        hosts = {self.headers.get("Host"), self.headers.get("X-Forwarded-Host")}
        if origin and urlsplit(origin).netloc not in hosts:
            return self.fehler(403, "Fremde Herkunft")
        try:
            laenge = int(self.headers.get("Content-Length", "0"))
            if not 0 < laenge <= 4096:
                raise ValueError
            daten = json.loads(self.rfile.read(laenge))
            name = str(daten.get("name", "")).strip()
            ip = str(daten.get("ip", "")).strip()
            label = " ".join(str(daten.get("label", "")).split())[:LABEL_MAX]
        except (ValueError, AttributeError):
            return self.fehler(400, "Ungültige Anfrage")
        if not NAME_RE.fullmatch(name):
            return self.fehler(400, "Name nur aus Kleinbuchstaben, Ziffern, - und _ (z. B. wohnzimmer)")
        if not pruefe_ip(ip):
            return self.fehler(400, "Keine private IP-Adresse: " + ip)
        label = label.replace("#", "")
        with lock:
            ersetzt = eintragen(name, ip, label)
            gen(eintraege())
            neu_geladen = go2rtc_neu_laden()
        print(f"Kamera {name} ({ip}) {'ersetzt' if ersetzt else 'hinzugefügt'}", file=sys.stderr)
        self.antwort(200, {"name": name, "ip": ip, "label": label, "ersetzt": ersetzt,
                           "neu_geladen": neu_geladen, "erreichbar": erreichbar(ip)})

    def log_message(self, fmt, *args):
        if os.environ.get("VERWALTUNG_LOG"):
            super().log_message(fmt, *args)


def main():
    host, _, port = LISTEN.rpartition(":")
    server = ThreadingHTTPServer((host, int(port)), Handler)
    print(f"cam-o-mat-Verwaltung auf {LISTEN}, Kameras in {CONF}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()
