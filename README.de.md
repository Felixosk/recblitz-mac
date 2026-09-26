# RecBlitz

**Eine macOS-Menüleisten-App für Sprachnotizen und Bildschirmaufnahmen, die auf deinem Mac transkribiert.**
Klick aufs Symbol, sprechen, nochmal klicken. Du bekommst eine Markdown-Notiz
mit Titel und dem ganzen Transkript, und wenn du willst, ein Google Doc und den
Drive-Link zum Video in der Zwischenablage.

### ⬇ [RecBlitz 2.0 herunterladen](https://github.com/Felixosk/recblitz-mac/releases/latest/download/RecBlitz.zip)

Fertige App · 1,8 MB · macOS 14+ (Transkription braucht macOS 26) · Apple Silicon **und** Intel ·
[ein Befehl beim ersten Start](#variante-a-fertige-app-herunterladen) ·
oder [selbst bauen](#variante-b-selbst-bauen) in zwei Minuten

[**Webseite**](https://felixosk.github.io/recblitz-mac/) ·
[Changelog](CHANGELOG.md) ·
[English version](README.md) ·
Schwester-App: [MeetingBlitz](https://github.com/Felixosk/meetingblitz-mac)

[![Build](https://github.com/Felixosk/recblitz-mac/actions/workflows/build.yml/badge.svg)](https://github.com/Felixosk/recblitz-mac/actions/workflows/build.yml)

![Eine laufende Bildschirmaufnahme, die fertige Notiz und die Meldung](docs/hero.png)

## Warum es das gibt

Das meiste, was ich laut sage, ist zehn Minuten später weg. Die Idee beim
Spazierengehen, die Erklärung für einen Kollegen, die Liste mit Sachen zum
Reparieren. Diktier-Apps schreiben Text in das Fenster, in dem du gerade bist.
Zum Schreiben ist das super, eine Notiz, die du nächste Woche wiederfindest,
ist es nicht. Bildschirmrekorder liefern ein Video, und die Worte bleiben darin
eingesperrt.

RecBlitz erledigt den langweiligen Teil dazwischen:

1. **Ein Klick oder ⌥⌘R** startet eine Sprachnotiz. Für einen Screencast vorher
   *Bildschirm* oder *Bereich* wählen, dein Mikrofon läuft immer mit.
2. **Apples Spracherkennung transkribiert auf dem Mac** (SpeechAnalyzer,
   macOS 26). Eine Notiz von 25 Sekunden ist in etwa einer halben Sekunde Text,
   für diesen Schritt verlässt nichts den Rechner.
3. **Eine Notiz landet in einem Ordner**, als Markdown mit einem Titel in einer
   Zeile, einer optionalen Zusammenfassung mit nächsten Schritten und dem
   Transkript. Zeig auf deinen Obsidian-Vault, und alles Gesagte ist durchsuchbar.
4. **Optional: Google Drive.** Mit eingerichtetem [rclone](https://rclone.org)
   wird dieselbe Notiz auch ein Google Doc, ein Screencast wird daneben
   hochgeladen, und der Freigabe-Link liegt in der Zwischenablage, sobald die
   Meldung erscheint.

Natives Swift und SwiftUI, kein Electron, kein Server, kein Konto.

![Das Menüleisten-Panel, bereit und während ein Video hochlädt](docs/panel.png)

## Im Vergleich

Sterne Stand September 2026. Die Apps rechts sind in ihrem Fach ausgereifter,
nimm sie, wenn du nur das brauchst.

| | RecBlitz | [Cap](https://github.com/CapSoftware/Cap) | [Handy](https://github.com/cjpais/Handy) | [VoiceInk](https://github.com/Beingpax/VoiceInk) | [QuickRecorder](https://github.com/lihaoyun6/QuickRecorder) |
|---|---|---|---|---|---|
| Nimmt den Bildschirm auf | ja | ja | nein | nein | ja |
| Transkribiert | ja, auf dem Mac | ja (Cap AI) | ja, auf dem Mac | ja, auf dem Mac | nein |
| Ergebnis | Markdown-Notiz, optional Google Doc + Drive-Link | Freigabe-Link, lokaler Export | Text wird in die aktive App eingefügt | Text wird in die aktive App eingefügt | Videodatei |
| Titel + Zusammenfassung pro Aufnahme | ja, optional | nein | nein | nein | nein |
| Konto nötig | nein | ja | nein | nein | nein |
| Lizenz | MIT | AGPL-3.0 | MIT | GPL-3.0 | AGPL-3.0 |
| Sterne | neu | 22,8k | 32,2k | 6,6k | 8,7k |

Ehrlich gesagt: zum Diktieren in andere Apps sind Handy und VoiceInk
hervorragend. Als Loom-Ersatz mit Team und Web-Player nimm Cap. RecBlitz ist
für den Fall dazwischen: du sprichst und willst danach eine Notiz oder ein Doc,
mit Video, wenn es eins gibt.

Am nächsten dran ist [Voom](https://github.com/aritropaul/voom) (nativ, auf dem
Gerät, Bildschirm plus Webcam). Es lädt in dein eigenes Cloudflare-Konto hoch
und schreibt keine Notizen.

## Funktionen

- **Sprachnotiz mit einem Klick** aus der Menüleiste, oder mit **⌥⌘R**, ohne etwas zu öffnen
- **Transkription auf dem Gerät** mit Apples SpeechAnalyzer, Deutsch, Englisch, Spanisch oder automatisch erkannt
- **Bildschirm- oder Bereichsaufnahme**, das Mikrofon läuft immer mit, Systemton (Video, Musik) optional
- **Webcam-Blase**, rund und verschiebbar, landet mit im Video
- **Vorlauf, Pause, Neustart, Verwerfen** in einer kleinen Steuerleiste, die nie im Video auftaucht
- **Bereit-Zustand** vor dem Screencast: Bereich und Webcam platzieren, dann erst aufnehmen
- **Titel und Zusammenfassung** pro Aufnahme über die Claude-Befehlszeile, falls installiert
- **Markdown-Notiz** in einen beliebigen Ordner, zum Beispiel deinen Obsidian-Vault
- **Google Doc + Drive-Upload** über rclone, Freigabe-Link in der Zwischenablage, Upload-Fortschritt in Prozent
- **Letzte Aufnahme** im Panel: Doc oder Notiz öffnen, Transkript kopieren, Video-Link kopieren
- **Mehrere Bildschirme**: Monitor wählen, ein Bereich folgt dem Bildschirm, auf dem du ihn aufziehst
- **Oberfläche auf Deutsch und Englisch**, live umschaltbar, beim ersten Start wie die Systemsprache

## Voraussetzungen

- **macOS 14 (Sonoma) oder neuer** zum Starten
- **macOS 26 für die eingebaute Transkription.** Auf älteren Systemen nimmt
  RecBlitz [mlx-whisper](https://github.com/ml-explore/mlx-examples) (`pip3 install mlx-whisper`, Apple Silicon)
- **macOS 15 oder neuer für Bildschirmaufnahmen** (Mikrofon und Bildschirm laufen dort auf einer Uhr und driften nie auseinander)
- Apple Silicon oder Intel, die App wird als Universal Binary gebaut
- **Xcode Command Line Tools** zum Bauen (einmalig, siehe unten)

Optionale Helfer, jeder bringt nur etwas dazu:

| Werkzeug | Bringt | Installation |
|---|---|---|
| [rclone](https://rclone.org) | Google Doc, Video-Upload, Freigabe-Link | `brew install rclone`, dann `rclone config` (ein Google-Drive-Remote) |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Titel, Zusammenfassung, nächste Schritte | der Befehl `claude` muss im PATH liegen |
| ffmpeg | eine gemischte Tonspur bei Systemton, automatische Spracherkennung | `brew install ffmpeg` |
| mlx-whisper | automatische Spracherkennung, Transkription auf macOS 14/15 | `pip3 install mlx-whisper` |

## Installation

### Variante A: fertige App herunterladen

`RecBlitz.zip` aus dem [neuesten Release](https://github.com/Felixosk/recblitz-mac/releases/latest)
laden, entpacken und **RecBlitz.app** in den Ordner **Programme** ziehen.

Die App ist nicht mit einem bezahlten Apple-Entwicklerkonto signiert, deshalb
stellt macOS sie beim Download unter Quarantäne. Ein Befehl nimmt die Markierung
weg:

```bash
xattr -dr com.apple.quarantine /Applications/RecBlitz.app
```

Danach ganz normal öffnen. **Was der Befehl tut:** du sagst macOS, dass du
selbst für die App bürgst, die Gatekeeper-Prüfung entfällt. Mach das nur bei
Software, der du vertraust. Hier kannst du vorher jede Zeile des Quelltexts
lesen, oder du nimmst Variante B und baust selbst.

Ohne den Befehl geht es auch auf dem langen Weg: Doppelklick, bei der Warnung
**Fertig** klicken, dann **Systemeinstellungen → Datenschutz & Sicherheit →
Trotzdem öffnen** und nochmal bestätigen.

### Variante B: selbst bauen

Zwei Minuten und kein Gatekeeper-Tanz, denn selbst kompilierte Software landet
nicht in Quarantäne.

```bash
git clone https://github.com/Felixosk/recblitz-mac.git
cd recblitz-mac
./build.sh && open dist/RecBlitz.app
```

Fehlen die Command Line Tools, installiert das sie (einige hundert MB, einmalig),
danach nochmal bauen:

```bash
xcode-select --install
```

### Gut zu wissen

**Die App hat kein Fenster und kein Dock-Symbol.** Sie sitzt oben rechts in der
Menüleiste als kleine Wellenform. Passiert nach dem Start scheinbar nichts,
schau dort nach. Ist die Menüleiste voll, blendet macOS Symbole wortlos aus;
**⌥⌘R** startet trotzdem eine Aufnahme.

## Google Drive einrichten (optional)

1. `brew install rclone`, dann `rclone config` und ein Google-Drive-Remote
   anlegen, zum Beispiel mit dem Namen `gdrive`.
2. In RecBlitz: **Einstellungen → Google Drive** einschalten, das Remote
   (`gdrive:`) eintragen und den Link des Drive-Ordners für die Docs einfügen.
   Videos können in einen eigenen Ordner.
3. Etwas aufnehmen. Die Meldung zeigt *Google Doc bereit*, bei einem Screencast
   *Video bereit · Link kopiert*.

Die Freigabe läuft über `rclone link` und stellt die Datei auf "Jeder mit dem
Link". Schalte **Video freigeben** aus, wenn nur du die Links öffnen sollst.

## Wo deine Daten landen

- Aufnahmen liegen in `~/Library/Application Support/RecBlitz/recordings/`.
  **Einstellungen → Allgemein** zeigt, wie viel Platz sie brauchen.
- Einstellungen liegen in `~/Library/Application Support/RecBlitz/config.json`.
  [`config.example.json`](config.example.json) zeigt alle Schlüssel.
- Transkribiert wird auf dem Mac. Titel und Zusammenfassung gehen nur an Claude,
  wenn der Befehl `claude` installiert und **Zusammenfassung** an ist.
- Google Drive ist aus, bis du es einschaltest.
- Kein Server, keine Telemetrie, kein Konto.

## Berechtigungen

- **Mikrofon**, bei der ersten Aufnahme.
- **Bildschirmaufnahme**, beim ersten Screencast. macOS will, dass du sie unter
  **Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme**
  erlaubst und RecBlitz danach neu startest.
- **Kamera**, nur für die Webcam-Blase.

## Wenn etwas hakt

**Es entsteht kein Google Doc.** In **Einstellungen → Google Drive** schauen: die
grüne Zeile heißt, rclone wurde gefunden. Dann im Terminal `rclone lsd gdrive:`
ausführen; fragt das nach einem Login, braucht das Remote
`rclone config reconnect gdrive:`.

**Transkription schlägt auf macOS 26 fehl.** Beim ersten Mal lädt macOS das
Sprachmodell der jeweiligen Sprache einmalig (etwa 10 Sekunden). Danach geht es
schnell.

**Logs** liegen in `~/Library/Application Support/RecBlitz/logs/pipeline.log`.

## Testmodi

| Schalter | Wirkung |
|---|---|
| `--transcribe <audio> [locale]` | transkribiert eine Datei und gibt den Text aus |
| `--render-panel <png> [zustand]` | rendert Panel oder Einstellungen als Bild (die Bilder in dieser README) |
| `--selftest` | prüft die reine Logik, läuft in `build.sh` |
| `--demo-banner` | zeigt 10 Minuten lang eine Ergebnis-Meldung |

## Mit Claude Code weiterbauen

Im Repo liegt eine [`CLAUDE.md`](CLAUDE.md) mit Architektur, Build und den
Fallen, die diese App bereithält. Claude Code in diesem Ordner öffnen und sagen,
was geändert werden soll.

## Signatur

Ohne Konfiguration signiert `build.sh` ad-hoc. Dann **verwirft macOS bei jedem
Neubau die Mikrofon- und Bildschirm-Freigaben**, weil es die App für eine neue
hält. Wer oft baut, legt ein selbstsigniertes Zertifikat an und kopiert
`signing.local.example` nach `signing.local`. Die Anleitung steht in der Datei.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
