// "Kamera hinzufügen": ESP32-CAM per USB flashen, WLAN einrichten und in cam-o-mat eintragen.
// Läuft nur in Browsern mit Web Serial (Chrome oder Edge am Computer) und nur über HTTPS.
//
// 1. Verbinden: esptool-js (liegt unter vendor/, kommt beim Bauen ins Image) bringt die Kamera in den Flash-Modus.
//    Auf dem USB-Board ESP32-CAM-MB geht das von selbst; sonst IO0-Taste halten (oder IO0 an GND).
// 2. Firmware: die Prusa-Firmware aus firmware/esp32-cam/ (Speicher vorher ganz gelöscht).
// 3. WLAN: über die serielle Konsole der Firmware (setwifissid:…; setwifipass:…; wificonnect;), dann die IP abfragen.
// 4. Eintragen: POST api/kameras (verwaltung.py), go2rtc lädt neu.

const ESPTOOL = "./vendor/esptool-js/bundle.js";
const FIRMWARE = "firmware/esp32-cam/";
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

export const unterstuetzt = () => "serial" in navigator && window.isSecureContext;

// "Küche oben" -> "kueche-oben" (so heißt die Kamera in kameras.conf und go2rtc)
export function kurzname(text) {
  return text.toLowerCase()
    .replace(/ä/g, "ae").replace(/ö/g, "oe").replace(/ü/g, "ue").replace(/ß/g, "ss")
    .normalize("NFKD").replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 32).replace(/-+$/, "");
}

export function einrichten({ vorhandene = () => [], fertig = () => {} }) {
  const $ = (id) => document.getElementById(id);
  const dlg = $("addDialog"), form = $("addForm"), logEl = $("addLog");
  const store = {
    get(k) { try { return localStorage.getItem("hundecam." + k) || ""; } catch { return ""; } },
    set(k, v) { try { localStorage.setItem("hundecam." + k, v); } catch {} },
  };
  let laeuft = false, neueKamera = null;

  function zeige(teil) {
    for (const t of ["addStart", "addLauf", "addFertig"]) $(t).hidden = t !== teil;
  }

  function log(text) {
    logEl.textContent = (logEl.textContent + text).slice(-20000);
    logEl.scrollTop = logEl.scrollHeight;
  }

  // Schritte in der Liste: "wartet" | "laeuft" | "ok" | "fehler" | "aus"
  function schritt(id, zustand, text) {
    const li = $(id);
    li.dataset.z = zustand;
    if (text !== undefined) li.querySelector("small").textContent = text;
  }

  function hinweis(text) { $("addHinweis").textContent = text || ""; $("addHinweis").hidden = !text; }

  function namePruefen() {
    const label = $("addLabel").value.trim();
    const name = kurzname(label);
    const info = $("addNameInfo");
    if (!label) info.textContent = "";
    else if (!name) info.textContent = "Bitte mit Buchstaben oder Ziffern.";
    else if (vorhandene().includes(name)) info.textContent = `„${name}“ gibt es schon, sie wird ersetzt.`;
    else info.textContent = `Kurzname: ${name}`;
    return name;
  }

  function oeffnen() {
    if (laeuft) return dlg.showModal();
    zeige("addStart");
    $("addSsid").value = $("addSsid").value || store.get("ssid");
    $("addKeinSerial").hidden = unterstuetzt();
    form.querySelector("button[type=submit]").disabled = !unterstuetzt();
    namePruefen();
    dlg.showModal();
    if (unterstuetzt()) $("addLabel").focus();
  }

  $("addLabel").addEventListener("input", namePruefen);
  $("addAbbrechen").onclick = () => dlg.close();
  $("addZurueck").onclick = () => { zeige("addStart"); };
  $("addSchliessen").onclick = () => dlg.close();
  dlg.addEventListener("cancel", (ev) => { if (laeuft) ev.preventDefault(); });
  dlg.addEventListener("close", () => {
    if (neueKamera) { const n = neueKamera; neueKamera = null; fertig(n); }
  });

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const label = $("addLabel").value.trim().replace(/\s+/g, " ");
    const name = namePruefen();
    const ssid = $("addSsid").value;
    const pass = $("addPass").value;
    const flashen = $("addFlash").checked;
    if (!name) return $("addLabel").focus();
    if (!ssid.trim()) return $("addSsid").focus();
    if (/[\r\n]/.test(ssid + pass)) return hinweis("WLAN-Name und Passwort dürfen keinen Zeilenumbruch enthalten.");
    store.set("ssid", ssid);

    let port;
    try {
      // Muss direkt aus dem Klick kommen, sonst lässt der Browser die Auswahl nicht zu.
      port = await navigator.serial.requestPort();
    } catch {
      return;   // Auswahl abgebrochen
    }

    laeuft = true;
    logEl.textContent = "";
    hinweis("");
    $("addZurueck").hidden = true;
    zeige("addLauf");
    schritt("sVerbinden", flashen ? "wartet" : "aus", "");
    schritt("sFlashen", flashen ? "wartet" : "aus", flashen ? "" : "übersprungen");
    schritt("sWlan", "wartet", "");
    schritt("sEintragen", "wartet", "");
    $("addBalken").value = 0;
    $("addBalken").hidden = true;

    let aktiv = flashen ? "sVerbinden" : "sWlan";
    let mac = "";
    try {
      if (flashen) {
        mac = await firmwareAufspielen(port, (s) => { aktiv = s; });
      }
      aktiv = "sWlan";
      schritt("sWlan", "laeuft", "warte auf die Kamera…");
      const ip = await wlanEinrichten(port, ssid, pass, flashen);
      schritt("sWlan", "ok", `verbunden, IP ${ip}`);

      aktiv = "sEintragen";
      schritt("sEintragen", "laeuft", "");
      const r = await fetch("api/kameras", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, ip, label }),
      });
      const antwort = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(antwort.fehler || `Server antwortet ${r.status}`);
      schritt("sEintragen", "ok", antwort.ersetzt ? "ersetzt" : "eingetragen");

      neueKamera = name;
      $("addErgebnis").textContent =
        `${label} läuft unter ${ip}. Du kannst sie jetzt abstecken und mit einem USB-Netzteil an ihren Platz stellen.`;
      $("addMac").textContent = mac
        ? `Damit die Adresse gleich bleibt: Im Router eine feste IP für die MAC-Adresse ${mac.toUpperCase()} reservieren.`
        : "Damit die Adresse gleich bleibt: Im Router eine feste IP für die Kamera reservieren.";
      $("addWarnung").textContent = antwort.erreichbar === false
        ? "Achtung: Der Server erreicht die Kamera gerade nicht. Ist er im selben Netz?" : "";
      zeige("addFertig");
    } catch (e) {
      console.error(e);
      schritt(aktiv, "fehler", e.message || String(e));
      $("addZurueck").hidden = false;
    } finally {
      laeuft = false;
      try { await port.close(); } catch {}
    }
  });

  // --- Flashen mit esptool-js ---------------------------------------------------------------------------------
  async function firmwareAufspielen(port, setzeAktiv) {
    schritt("sVerbinden", "laeuft", "Flash-Modus…");
    const { ESPLoader, Transport } = await import(ESPTOOL);
    const transport = new Transport(port, false);
    try {
      return await flashen(transport, ESPLoader, setzeAktiv);
    } catch (e) {
      await transport.disconnect().catch(() => {});
      throw e;
    }
  }

  async function flashen(transport, ESPLoader, setzeAktiv) {
    const terminal = { clean() {}, writeLine: (d) => log(d + "\n"), write: (d) => log(d) };
    const loader = new ESPLoader({ transport, baudrate: 460800, romBaudrate: 115200, terminal });
    const tipp = setTimeout(() => hinweis(
      "Klappt das Verbinden nicht? Am USB-Board die Taste IO0 gedrückt halten, kurz RST drücken, IO0 loslassen."), 8000);
    let chip;
    try {
      chip = await loader.main();
    } catch (e) {
      throw new Error("Keine Verbindung zum ESP32. IO0 halten und RST drücken, dann nochmal. (" + (e.message || e) + ")");
    } finally {
      clearTimeout(tipp);
    }
    hinweis("");
    if (/^ESP32-(S|C|H|P)\d/i.test(chip) || !/^ESP32/i.test(chip)) {
      throw new Error(`Das ist ein ${chip}. Die Firmware hier passt nur zur Ai-Thinker ESP32-CAM (ESP32).`);
    }
    const mac = await loader.chip.readMac(loader).catch(() => "");
    schritt("sVerbinden", "ok", chip);

    setzeAktiv("sFlashen");
    schritt("sFlashen", "laeuft", "lade Firmware…");
    const info = await (await fetch(FIRMWARE + "firmware.json", { cache: "no-cache" })).json();
    const fileArray = [];
    for (const d of info.dateien) {
      const r = await fetch(FIRMWARE + d.datei, { cache: "no-cache" });
      if (!r.ok) throw new Error("Firmware fehlt auf dem Server: " + d.datei);
      fileArray.push({ data: new Uint8Array(await r.arrayBuffer()), address: d.adresse });
    }
    const gesamt = fileArray.reduce((s, f) => s + f.data.length, 0);
    const vorher = fileArray.map((_, i) => fileArray.slice(0, i).reduce((s, f) => s + f.data.length, 0));
    const balken = $("addBalken");
    schritt("sFlashen", "laeuft", `lösche Speicher (Prusa-Firmware ${info.version})…`);
    await loader.writeFlash({
      fileArray, flashMode: "dio", flashFreq: "80m", flashSize: "4MB", eraseAll: true, compress: true,
      reportProgress: (i, geschrieben, groesse) => {
        const p = Math.round(((vorher[i] + Math.min(geschrieben, groesse) * fileArray[i].data.length / groesse) / gesamt) * 100);
        balken.hidden = false;
        balken.value = p;
        $("sFlashen").querySelector("small").textContent = `schreibe… ${p} %`;
      },
    });
    balken.value = 100;
    await loader.after("hard_reset");
    await transport.disconnect();
    schritt("sFlashen", "ok", `Prusa-Firmware ${info.version}`);
    return mac;
  }

  // --- WLAN über die serielle Konsole der Prusa-Firmware -----------------------------------------------------
  async function wlanEinrichten(port, ssid, pass, geflasht) {
    await port.open({ baudRate: 115200 });
    // DTR und RTS gleich: weder Reset noch Flash-Modus (Auto-Reset-Schaltung der USB-Boards)
    try { await port.setSignals({ dataTerminalReady: false, requestToSend: false }); } catch {}
    const enc = new TextEncoder(), dec = new TextDecoder();
    const reader = port.readable.getReader();
    const writer = port.writable.getWriter();
    let seit = "";
    const lesen = (async () => {
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          const t = dec.decode(value, { stream: true });
          seit = (seit + t).slice(-20000);
          log(t);
        }
      } catch {}
    })();
    const senden = async (cmd) => { log("\n> " + (cmd.startsWith("setwifipass:") ? "setwifipass:***;" : cmd) + "\n"); await writer.write(enc.encode(cmd + "\n")); };
    async function frage(cmd, re, ms = 2000) {
      seit = "";
      await senden(cmd);
      const ende = Date.now() + ms;
      while (Date.now() < ende) {
        const m = seit.match(re);
        if (m) return m;
        await pause(150);
      }
      return null;
    }

    try {
      // Bis die Firmware läuft und auf Befehle antwortet (nach dem Flashen: Neustart, Kamera, Speicher, ~10 s)
      const start = Date.now();
      let bereit = false;
      while (Date.now() - start < 90000) {
        if (await frage("getwifimode;", /wifimode:[^;]*;/, 2000)) { bereit = true; break; }
        if (Date.now() - start > 20000) hinweis(geflasht
          ? "Die Kamera meldet sich nicht. Steckt noch eine Brücke IO0–GND? Dann entfernen und RST drücken."
          : "Die Kamera meldet sich nicht. Läuft die Prusa-Firmware schon? Sonst „Firmware aufspielen“ anhaken. RST drücken hilft manchmal.");
      }
      if (!bereit) throw new Error("Die Kamera antwortet nicht auf der seriellen Konsole.");
      hinweis("");

      schritt("sWlan", "laeuft", `verbinde mit „${ssid}“…`);
      await senden(`setwifissid:${ssid};`);
      await pause(400);
      await senden(`setwifipass:${pass};`);
      await pause(400);
      await senden("wificonnect;");

      const ende = Date.now() + 60000;
      let status = "";
      while (Date.now() < ende) {
        await pause(2000);
        const m = await frage("getwifistaip;", /wifistaip:([0-9.]+);/, 2500);
        if (m && m[1] !== "0.0.0.0") return m[1];
        const s = await frage("getwifistastatus;", /wifistastatus:([^;]*);/, 2000);
        if (s) status = s[1];
        if (/No SSID/i.test(status)) hinweis("WLAN nicht gefunden. Name richtig? Die ESP32-CAM kann nur 2,4 GHz.");
        else if (/failed/i.test(status)) hinweis("Anmeldung im WLAN klappt nicht. Passwort richtig?");
      }
      throw new Error(`Kein WLAN (${status || "keine Antwort"}). Name, Passwort und 2,4 GHz prüfen.`);
    } finally {
      try { await reader.cancel(); } catch {}
      await lesen;
      reader.releaseLock();
      writer.releaseLock();
      await port.close().catch(() => {});
    }
  }

  return { oeffnen };
}
