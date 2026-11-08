# go2rtc mit Grundkonfig und esp-mjpeg.sh eingebaut (nicht unter /config: das ist im Basis-Image ein VOLUME).
# Die Kameras kommen zur Laufzeit aus /config/generated/kameras.yaml (kameras.sh).
FROM alexxit/go2rtc:1.9.15
COPY go2rtc.yaml esp-mjpeg.sh /app/
CMD ["go2rtc", "-config", "/app/go2rtc.yaml", "-config", "/config/generated/kameras.yaml"]
