# Seite und Proxy: Caddy mit Caddyfile und web/ eingebaut.
# Für "Kamera hinzufügen" kommen beim Bauen dazu (fest auf eine Version, mit Prüfsumme):
#   - esptool-js von Espressif (flasht die ESP32-CAM aus dem Browser über USB)
#   - die Prusa-Firmware für die Ai-Thinker ESP32-CAM
# Zur Laufzeit lädt die Seite also nichts von fremden Servern.
FROM alpine:3.22 AS downloads
ARG ESPTOOL_JS_VERSION=0.7.0
ARG ESPTOOL_JS_SHA256=9c7797cfbcac3a989ab85c52c9daaa65ffc0d538c273a055757b98bb846fdf1f
ARG FIRMWARE_VERSION=v1.1.2
ARG FIRMWARE_SHA256=a173fe14eeb06ef1ad6b37dbf73e87fbf9580699bf45d943d5e3c8062f8cabb6
RUN apk add --no-cache curl unzip
WORKDIR /out
RUN curl -fsSL -o /tmp/esptool.tgz "https://registry.npmjs.org/esptool-js/-/esptool-js-${ESPTOOL_JS_VERSION}.tgz" \
 && echo "${ESPTOOL_JS_SHA256}  /tmp/esptool.tgz" | sha256sum -c - \
 && mkdir -p vendor/esptool-js /tmp/esptool \
 && tar -xzf /tmp/esptool.tgz -C /tmp/esptool \
 && cp /tmp/esptool/package/bundle.js /tmp/esptool/package/LICENSE vendor/esptool-js/
RUN curl -fsSL -o /tmp/fw.zip "https://github.com/prusa3d/Prusa-Firmware-ESP32-Cam/releases/download/${FIRMWARE_VERSION}/esp32-cam.zip" \
 && echo "${FIRMWARE_SHA256}  /tmp/fw.zip" | sha256sum -c - \
 && mkdir -p firmware/esp32-cam \
 && unzip -q /tmp/fw.zip -d firmware/esp32-cam \
 && printf '{"version":"%s","dateien":[{"datei":"ESP32_PrusaConnectCam.ino.bootloader.bin","adresse":4096},{"datei":"ESP32_PrusaConnectCam.ino.partitions.bin","adresse":32768},{"datei":"ESP32_PrusaConnectCam.ino.bin","adresse":65536}]}\n' \
      "${FIRMWARE_VERSION}" > firmware/esp32-cam/firmware.json \
 && for f in bootloader.bin partitions.bin bin; do test -s "firmware/esp32-cam/ESP32_PrusaConnectCam.ino.$f"; done

FROM caddy:2-alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY web /srv
COPY --from=downloads /out /srv
