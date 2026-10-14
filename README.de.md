# gPlug HA

*[English](README.md)*

Home Assistant MQTT Auto-Discovery für das [gPlug](https://gplug.ch) Smartmeter-Interface, als Tasmota
Berry-App — ohne manuelle YAML-Konfiguration auf der Home-Assistant-Seite.

Tasmotas eigenes, früheres HA-Discovery (`SetOption19`) wurde firmwareseitig entfernt. Diese App füllt
genau diese Lücke, gezielt für den im gPlug fest eingebauten Smartmeter (je nach Modell P1-DSMR, Kamstrup
HAN oder M-Bus) — nicht als generische Tasmota-Sensor-zu-HA-Brücke.

**Kein YAML, kein Home-Assistant-Add-on, keine zusätzliche Integration nötig.** Die gesamte Logik läuft
auf dem gPlug selbst; Home Assistant braucht nur seine eingebaute MQTT-Integration, die bereits mit deinem
Broker verbunden ist.

<p>
  <img src="docs/tasmota-status-badge.png" alt="Statusanzeige in der Tasmota-Weboberfläche" width="420">
</p>

## Was die App macht

- Liest den fest eingebauten Smartmeter lokal über Tasmotas SML-Sensor aus (`tasmota.read_sensors()`) und
  löst die tatsächlich verwendeten Variablennamen anhand ihres OBIS-Codes aus `script.txt` auf — funktioniert
  damit auch auf Zählern mit abweichenden Variablennamen für denselben Messwert.
- Veröffentlicht sämtliche vom Zähler gelieferten Werte: aggregierte und phasenweise Wirkleistung
  (Bezug/Einspeisung), Spannung und Strom je Phase, Blindleistung, Leistungsfaktor, Energie Bezug/Einspeisung
  (inkl. Tarifregister bei 2-Tarif-Zählern, sofern der Zähler diese liefert) sowie Blindenergie.
- Veröffentlicht zusätzlich gPlug-/Tasmota-Diagnosedaten: ESP32-Temperatur, freier Heap, Laufzeit, letzter
  Neustart-Grund.
- Publiziert eine Home-Assistant-MQTT-Discovery-Nachricht, sodass alle obigen Werte automatisch als
  Entities erscheinen — ganz ohne YAML.
- Aktualisiert bei jedem Smartmeter-Messwert (kein fixes Abfrageintervall), veröffentlicht die Discovery
  neu, wenn sich die Zähler-ID ändert (z.B. nach einem Zählertausch), sowie nach einem Neustart von Home
  Assistant bzw. des Brokers.
- Schützt kumulative Energiezähler vor kurzzeitigen Nullwerten (Übertragungs-/Parsing-Fehler), damit ein
  fehlerhafter Messwert nicht als Zähler-Reset missverstanden wird und Home Assistants
  Langzeit-Energiestatistik verfälscht.
- Eine kleine Statusanzeige in der Tasmota-Weboberfläche zeigt, dass die App läuft, mit Link zu diesem
  Repository.

## Was in Home Assistant entsteht

Ein Gerät mit nach Art gruppierten Sensoren — Messwerte, Leistungs-/Energie-Details je Phase sowie
Geräte-Diagnose erscheinen automatisch:

<p>
  <img src="docs/home-assistant-device.png" alt="Das resultierende Gerät samt Entities in Home Assistant" width="640">
</p>

Das basiert vollständig auf Home Assistants eingebauter
[MQTT-Integration](https://www.home-assistant.io/integrations/mqtt), resp. deren MQTT-Discovery-Mechanismus.
Sobald die App auf dem gPlug läuft und ihre erste Discovery-Nachricht publiziert, erscheint das Gerät von
selbst unter **Einstellungen → Geräte & Dienste → MQTT** — kein manuelles Anlegen von Entities, keine
zusätzliche Integration nötig.

## Installation

1. Aktuelle `gplug_ha.tapp` von den [Releases](../../releases) herunterladen (oder selbst bauen, siehe
   unten).
2. In der Tasmota-Weboberfläche des gPlug: **Werkzeuge → Dateisystem verwalten → Upload**, `gplug_ha.tapp`
   auswählen.
3. Gerät neu starten (**Neustart**-Button auf der Startseite). Danach ist kein weiterer Schritt nötig —
   Tasmota sucht beim Boot automatisch nach `*.tapp`-Dateien und führt sie aus.
4. In Home Assistant unter **Einstellungen → Geräte & Dienste → MQTT** nachsehen: das Smartmeter-Gerät
   (benannt "Smart Meter `<SMid>`") erscheint dort automatisch, mit allen zugehörigen Entities.

Der MQTT-Broker des gPlug muss bereits in Tasmota konfiguriert sein (**Konfiguration → MQTT**) sowie als
Integration in Home Assistant eingerichtet sein; diese App nutzt diese bestehende Verbindung und verwaltet
keine eigenen Zugangsdaten.

## Selbst bauen

```
cd berry
./build_tapp.sh
```

Kompiliert `gplug_ha.be` und `gplug_ha_setup.be` zu Berry-Bytecode vor und packt beide in `gplug_ha.tapp`.
Beim ersten Lauf wird ein passender `berry`-CLI-Compiler gebaut und gecacht (aus exakt dem
Tasmota-Firmware-Quell-Tag, da Tasmota Berry patcht); spätere Läufe nutzen das gecachte Binary. Benötigt
`curl`, `make` und Python 3.

Für Firmware ohne automatischen `.tapp`-Scan zeigt `autoexec.be.example` stattdessen den Weg für die
Einzeldatei-Installation (`gplug_ha.be`, `gplug_ha_setup.be` und `autoexec.be` separat hochladen).

## MQTT-Topics

Alle Topics verwenden die eigene ID des Smartmeters (`SMid`), nicht das Tasmota-Topic des Geräts, und
bleiben damit über Geräte-Rekonfigurationen hinweg stabil:

| Topic | Inhalt | Aktualisierung |
|---|---|---|
| `gplug-ha/<smid>/state` | Netzleistung, Spannung/Strom je Phase, Leistungsfaktor, Zählerstatus | bei jedem Messwert |
| `gplug-ha/<smid>/power` | Leistung Bezug/Einspeisung/Saldo je Phase, Blindleistung | ~alle 2 Minuten |
| `gplug-ha/<smid>/energy` | Energie Bezug/Einspeisung (+ Tarife falls vorhanden), Blindenergie | ~alle 2 Minuten |
| `gplug-ha/<smid>/diag` | ESP32-Temperatur, freier Heap, Laufzeit, Neustart-Grund | ~alle 2 Minuten |
| `homeassistant/device/<smid>*/config` | HA-MQTT-Discovery (vier Nachrichten, ein Gerät) | bei erster Erkennung, Zählertausch oder HA-Neustart |

## Optional: Publish-Takt reduzieren

Wer nur das Home-Assistant-Energie-Dashboard nutzt und keine sekundengenauen Live-Werte braucht, kann die
App verlangsamen, um Recorder-/`state_changed`-Datenmenge zu reduzieren. Dazu eine Datei `gplug_ha.cfg`
(JSON) neben `script.txt` im Dateisystem des gPlug anlegen (**Werkzeuge → Dateisystem verwalten → Neue
Datei erstellen**) und neu starten:

```json
{"state_interval_s": 30, "power_interval_s": 60, "diag_interval_s": 300, "energy_interval_s": 300}
```

- `state_interval_s` (Standard `0`): Mindestabstand in Sekunden zwischen `state`-Publishes (Netzleistung,
  Spannung/Strom je Phase, Leistungsfaktor). `0` bedeutet "bei jedem Smartmeter-Update", der Standard —
  sinnvoll schnell zu lassen, falls z.B. eine PV-Regelung auf die aktuelle Netzleistung angewiesen ist.
- `power_interval_s`, `diag_interval_s`, `energy_interval_s` (je Standard `120`): Mindestabstand in
  Sekunden zwischen den Publishes von `power`, `diag` bzw. `energy` — vollständig unabhängig voneinander,
  sodass z.B. `energy` (kumulative Zählerstände, alles was das Energie-Dashboard tatsächlich braucht)
  verlangsamt werden kann, ohne `power` oder `diag` zu beeinflussen.
- `detail_interval_s` (Standard `120`, veraltet): setzt den gemeinsamen Standardwert für
  `power_interval_s`, `diag_interval_s` und `energy_interval_s`, sofern einer der drei nicht explizit
  gesetzt ist. Weiterhin unterstützt für Konfigurationen, die vor den drei obigen Optionen erstellt wurden.

Fehlt die Datei oder ist sie ungültig, bleiben die Standardwerte erhalten — es ist eine lokale Datei, keine
Fernkonfiguration, ein Neustart ist für Änderungen nötig, genau wie bei `script.txt`.

## Bekannte Einschränkung

Tasmota loggt gelegentlich `BRY: ERROR, bad json` für einen ausgehenden MQTT-Publish dieser App — auf
echter gPlug-Hardware während der Entwicklung beobachtet. Die genaue Ursache konnte nicht abschliessend
geklärt werden - sie korreliert weder erkennbar mit der Nachrichtengrösse noch mit der Anzahl rasch
aufeinanderfolgender `mqtt.publish()`-Aufrufe, und die bei Home Assistant tatsächlich ankommenden Daten
waren davon nachweislich nicht betroffen. Falls du echte fehlende/veraltete Entity-Werte bemerkst (nicht
nur diese Log-Zeile), erstelle bitte ein Issue mit deiner `script.txt` und dem Konsolen-Log rund um den
Zeitpunkt der Lücke.

## Voraussetzungen

- gPlug (gPlugD/-D-E/-K/-M) mit Tasmota, `USE_BERRY` und dem Smart-Meter-Modul (`USE_SCRIPT`,
  SML-Sensor) einkompiliert.
- ESP32-C3 ohne PSRAM — diese App ist mit diesem Speicherbudget im Hinterkopf geschrieben.

## Credits

- Das in der Statusanzeige der Tasmota-Weboberfläche gezeigte Home-Assistant-Symbol ist das offizielle
  "Home Assistant"-Zeichen aus dem [Simple Icons](https://simpleicons.org/icons/homeassistant.svg)-Projekt
  (CC0-lizenziert).
- [Tasmota](https://tasmota.github.io/docs/) und dessen [Berry](https://tasmota.github.io/docs/Berry/)
  Skriptsprache.

## Lizenz

[MIT](LICENSE)

Dies ist ein unabhängiges Community-Projekt, das weder mit den Herstellern des gPlug noch mit
Home Assistant / Nabu Casa oder dem Tasmota-Projekt verbunden ist oder von ihnen unterstützt wird. Alle
Produktnamen und Marken gehören ihren jeweiligen Inhabern.
