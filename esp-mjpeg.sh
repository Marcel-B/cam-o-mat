#!/bin/sh
# Holt den MJPEG-Stream einer ESP32-CAM mit Prusa-Firmware für go2rtc.
# Die Firmware schickt vor dem ersten Bild keine Boundary-Zeile ("--…"), go2rtc bricht dann mit
# "multipart: wrong boundary" ab. Deshalb wird sie hier einmal vorangestellt; danach passt der Stream.
# Aufruf aus go2rtc.yaml: exec:sh /config/esp-mjpeg.sh http://<ip>/stream.mjpg
printf -- '--123456789000000000000987654321\r\n'
exec curl -sfN --connect-timeout 5 "$1"
