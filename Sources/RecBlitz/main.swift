import AppKit
import SwiftUI
import Combine
import BlitzKit

// RecBlitz — Sprachnotiz aus der Menüleiste:
// Klick aufs Icon öffnet das Panel (Sprache wählen → Aufnahme starten),
// ⌥⌘R startet/stoppt direkt. Transkription on-device via Apple SpeechAnalyzer
// (macOS 26), Whisper als Fallback. Ergebnis: Google Doc im konfigurierten
// Drive-Ordner (Zusammenfassung, Nächste Schritte, Transkript) + Markdown-Kopie.

enum AppPhase {
    case idle
    /// Alles steht (Ausschnitt gewählt, Webcam platziert), es wird aber noch
    /// NICHT aufgenommen. Erst Play löst den Vorlauf aus (Rückmeldung 01.08.).
    case armed
    case recording
    case transcribing
    case uploading
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    /// Bildschirmaufnahme (31.07.) — eigener Recorder, weil ScreenCaptureKit und
    /// AVCaptureSession völlig verschiedene Maschinen sind. Beide liegen in
    /// BlitzKit, damit MeetingBlitz dieselbe Engine nutzt statt einer Kopie.
    private let screenRecorder = ScreenRecorder()
    /// Läuft die aktuelle Aufnahme über den Bildschirm-Pfad?
    private var screenRecordingActive = false
    /// „Nur Ton" mit Systemton läuft über die Bildschirm-Engine (nur sie kann den
    /// Systemton), das Video ist dabei winzig und wird nach dem Ton-Ausziehen
    /// gelöscht, nie hochgeladen (05.10.).
    private var audioOnlyViaScreen = false
    /// Hatte die laufende Bildschirm-Aufnahme Mikro UND Systemton (= zwei Spuren)?
    private var recordedTwoAudioTracks = false
    /// Video der gerade verarbeiteten Aufnahme; wird an pipeline.py durchgereicht,
    /// die es nach Drive lädt und den Link in Doc + Obsidian schreibt.
    /// Startton laeuft gerade (Aufnahme beginnt direkt danach).
    private var cueStarting = false
    private var pendingVideoURL: URL?
    /// Läuft gerade ein Verwerfen? Der Mikro-Pfad liefert seine Datei erst über
    /// den Delegate, deshalb muss das Aufräumen dort wissen, dass niemand sie will.
    private var discarding = false
    /// Womit gerade aufgenommen wird — fürs "Neu starten" in der Steuerleiste.
    private var activeScope: CaptureScope?
    /// Video, das gerade hochgeladen wird — wird nach nachgewiesenem Erfolg
    /// lokal gelöscht (Rückmeldung 01.08.: 146 MB nach einem Testnachmittag).
    private var uploadingVideoPath: URL?
    private let state = AppState()
    /// Beobachtet den Webcam-Schalter, damit die Blase SOFORT erscheint statt
    /// erst bei der Aufnahme (Rückmeldung 01.08.: "dann soll ich sie direkt am Screen
    /// sehen, damit ich sie auch verschieben kann").
    private var webcamWatch: AnyCancellable?
    private var timer: Timer?
    private var hotKey: HotKey?
    private var uploadsInFlight = 0

    private var phase: AppPhase = .idle {
        didSet {
            state.phase = phase
            render()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Look.apply()
        if CommandLine.arguments.contains("--check-panels") { runCheckPanels(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--demo-window") {
            let a = CommandLine.arguments
            runDemoWindow(kind: i + 1 < a.count ? a[i + 1] : "panel",
                          state: i + 2 < a.count && !a[i + 2].hasPrefix("--") ? a[i + 2] : "idle")
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "RecBlitz" // Position in der Leiste bleibt gemerkt
        if let button = statusItem.button {
            button.action = #selector(statusClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        recorder.onFinished = { [weak self] url, seconds in
            self?.handleRecordingFinished(url: url, seconds: seconds)
        }
        state.onToggleRecording = { [weak self] in self?.toggle() }
        state.onDiscardRecording = { [weak self] in self?.discardRecording() }
        state.onTogglePause = { [weak self] in self?.togglePause() }
        hotKey = HotKey { [weak self] in self?.toggle() }
        // .dropFirst(): der gespeicherte Wert darf beim Start NICHT ungefragt
        // die Kamera und die Kamera-LED anwerfen (Rückmeldung 01.08.: "meine Webcam
        // ist die ganze Zeit an"). Die Blase erscheint beim bewussten
        // Umschalten — und beim Vorbereiten einer Aufnahme, siehe enterArmed.
        // × auf der Blase = Schalter aus, sonst käme sie sofort wieder.
        MainActor.assumeIsolated {
            WebcamBubble.shared.onClose = {
                ConfigStore.shared.webcamEnabled = false
                ConfigStore.shared.save()
            }
        }
        webcamWatch = ConfigStore.shared.$webcamEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] on in
                DispatchQueue.main.async { self?.syncWebcamBubble(enabled: on) }
            }
        // Letztes Transkript über App-Neustarts hinweg verfügbar halten.
        state.lastTranscript = try? String(contentsOf: AppDelegate.lastTranscriptURL, encoding: .utf8)
        render()

        // Die alten Hilfen --demo-banner/--demo-settings sind weg (sie oeffneten Fenster auf dem externen Bildschirm).
        // Ersatz: `--demo-window panel|settings|both|banner` (nur eingebauter Bildschirm, erfundene Daten).

        // Verifikations-Hilfe: echte Aufnahme MIT eingeblendeter Steuerleiste,
        // um zu prüfen dass die Leiste nicht im Video landet. Muss in der
        // richtigen App laufen — ein loses Testprogramm hat keine Bundle-ID und
        // kann sich deshalb gar nicht selbst ausschließen (01.08.).
        if CommandLine.arguments.contains("--demo-record") {
            let out = URL(fileURLWithPath: NSTemporaryDirectory() + "recblitz_bartest.mp4")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    let ds = await ScreenRecorder.availableDisplays()
                    guard let t = ds.first(where: { !$0.isMain }) ?? ds.first else { exit(1) }
                    self.showControlBar(for: .fullScreen(displayID: t.id))
                    RecordingControlBar.shared.update(elapsed: 7, paused: false)
                    // Blase direkt zeigen, OHNE die Einstellung des Nutzers anzufassen —
                    // ein Prueflauf darf seine Konfiguration nicht umstellen.
                    _ = await WebcamBubble.shared.show(on: self.screenFor(.fullScreen(displayID: t.id)),
                                                       diameter: 190)
                    print("Webcam-Blase sichtbar: \(WebcamBubble.shared.isVisible)")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    // NUR den Recorder, NICHT die Pipeline: ein Prueflauf darf
                    // kein Testvideo ins echte Drive laden (01.08. passiert).
                    self.enterArmed(scope: .fullScreen(displayID: t.id))
                    print("Phase nach enterArmed: \(self.phaseName)")
                    self.discardRecording()
                    print("Phase nach Abbrechen: \(self.phaseName)  discarding=\(self.discardingFlag)")
                    do {
                        try await self.screenRecorder.start(to: out, options: .init(
                            scope: .fullScreen(displayID: t.id), includeSystemAudio: false,
                            microphoneDeviceID: nil, maxDimension: nil, fps: 10,
                            includeWindowIDs: WebcamBubble.shared.windowID.map { [$0] } ?? []))
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        _ = await self.screenRecorder.stop()
                        print("OK \(out.path)")
                    } catch { print("FEHLER: \(error.localizedDescription)") }
                    RecordingControlBar.shared.hide(); RegionFrame.shared.hide()
                    WebcamBubble.shared.hide()
                    exit(0)
                }
            }
        }

        // Verifikations-Hilfe: nur die Webcam-Blase, 25s stehen lassen.
        if CommandLine.arguments.contains("--demo-webcam") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    let ds = await ScreenRecorder.availableDisplays()
                    let t = ds.first(where: { !$0.isMain }) ?? ds.first
                    let screen = t.flatMap { d in NSScreen.screens.first {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == d.id } }
                    let ok = await WebcamBubble.shared.show(on: screen, diameter: 160)
                    print("Blase: \(ok)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { exit(0) }
        }

        // Headless UI-Test: Settings-Panel öffnen, Zustand loggen, beenden.
        if CommandLine.arguments.contains("--ui-test-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { SettingsPanelController.shared.toggle(anchor: nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let info = MainActor.assumeIsolated { SettingsPanelController.shared.debugInfo }
                    try? info.write(toFile: NSTemporaryDirectory() + "recblitz_uitest.txt",
                                    atomically: true, encoding: .utf8)
                    exit(0)
                }
            }
        }
    }

    /// Testfenster: `--demo-window panel|settings|both|banner [zustand] [--seconds=N] [--light] [--lang=en]`.
    /// Oeffnet das ECHTE Fenster mit erfundenen Daten, NUR auf dem eingebauten Bildschirm, schreibt Fenster-ID,
    /// Rahmen und Ebene in `$TMPDIR/recblitz_demo.txt` und beendet sich nach 20 s (oder `--seconds=N`).
    /// Kein Menueleisten-Symbol, kein Hotkey, keine Aufnahme, liest/schreibt keine Konfiguration.
    private func runDemoWindow(kind: String, state st: String) {
        let builtin = NSScreen.screens.first { s in
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                .map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
        guard let screen = builtin else {
            print("KEIN eingebauter Bildschirm, Demo abgebrochen"); exit(2)
        }
        let secs = CommandLine.arguments.compactMap { a -> Double? in
            a.hasPrefix("--seconds=") ? Double(a.dropFirst(10)) : nil }.first ?? 20
        demoState = Demo.state(mode: st)
        let vf = screen.visibleFrame
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            MainActor.assumeIsolated {
                switch kind {
                case "settings":
                    SettingsPanelController.shared.toggle(
                        anchor: CGRect(x: vf.maxX - 392, y: vf.maxY - 330, width: 392, height: 330), screen: screen)
                case "banner":
                    Banner.show(title: st == "error" ? L.t("Aufnahme fehlgeschlagen", "Recording failed")
                                                     : L.t("Video bereit · Link kopiert", "Video ready · link copied"),
                                subtitle: st == "error" ? L.t("Kein Mikrofon-Zugriff", "No microphone access")
                                                        : L.t("Besprechung Onboarding und die zwei offenen Fragen",
                                                              "Onboarding meeting and the two open questions"),
                                url: nil, isError: st == "error", seconds: 600,
                                hint: st == "error" ? nil : L.t("Klick öffnet das Video", "Click opens the video"),
                                screen: screen)
                default:
                    PanelController.shared.toggle(state: demoState!, statusButton: nil, screen: screen)
                    if kind == "both" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            MainActor.assumeIsolated {
                                SettingsPanelController.shared.toggle(anchor: PanelController.shared.glassFrame, screen: screen)
                            }
                        }
                    }
                }
            }
        }
        for t in [1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { Self.dumpDemoWindows() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
    }

    private var demoState: AppState?

    /// Waechter `--check-panels`: oeffnet Panel, Einstellungen und Banner (erfundene Daten, nur eingebauter
    /// Bildschirm) und prueft von jedem Fenster Ebene (.floating), Aussehen (passt zu Look), Breite und dass es auf dem
    /// eingebauten Bildschirm liegt. Exit 0 = gruen, 1 = rot. `RB_CHECK_BREAK=1` dreht die Erwartung absichtlich um
    /// (Gegenprobe: der Check muss dann ROT werden).
    private func runCheckPanels() {
        guard let screen = NSScreen.screens.first(where: { s in
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                .map { CGDisplayIsBuiltin($0) != 0 } ?? false }) else { print("FAIL kein eingebauter Bildschirm"); exit(2) }
        let broken = ProcessInfo.processInfo.environment["RB_CHECK_BREAK"] != nil
        demoState = Demo.state(mode: "idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            MainActor.assumeIsolated {
                PanelController.shared.toggle(state: demoState!, statusButton: nil, screen: screen)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    MainActor.assumeIsolated {
                        SettingsPanelController.shared.toggle(anchor: PanelController.shared.glassFrame, screen: screen)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    Banner.show(title: "Check", subtitle: "Check", url: nil, seconds: 60, screen: screen)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            var fails: [String] = []
            var checked = 0
            let wantLevel = broken ? NSWindow.Level.popUpMenu : NSWindow.Level.floating
            MainActor.assumeIsolated {
                for w in NSApp.windows where w.isVisible {
                    checked += 1
                    let name = String(describing: type(of: w))
                    if w.level != wantLevel { fails.append("\(name): Ebene \(w.level.rawValue), erwartet \(wantLevel.rawValue)") }
                    if !Look.matches(w) { fails.append("\(name): Aussehen passt nicht zu Look \(Look.mode)") }
                    if !screen.frame.intersects(w.frame) { fails.append("\(name): nicht auf dem eingebauten Bildschirm") }
                    if name == "StagePanel" || name == "ThemePanel",
                       abs(w.frame.width - (Theme.widgetWidth + 2 * Theme.stageInset)) > 0.5 {
                        fails.append("\(name): Breite \(w.frame.width)")
                    }
                    print("  \(name) Ebene \(w.level.rawValue) Aussehen \(w.effectiveAppearance.name.rawValue) \(Int(w.frame.width))x\(Int(w.frame.height))")
                }
                // Gegenprobe des Aussehens-Checks: mit umgedrehtem Aussehen muss Look.matches false liefern.
                if let w = NSApp.windows.first(where: { $0.isVisible }) {
                    let saved = NSApp.appearance
                    NSApp.appearance = NSAppearance(named: Look.mode == .light ? .darkAqua : .aqua)
                    if Look.mode != .system, Look.matches(w) { fails.append("Gegenprobe: Look.matches blieb true bei falschem Aussehen") }
                    NSApp.appearance = saved
                }
            }
            if checked < 3 { fails.append("nur \(checked) Fenster sichtbar, erwartet 3") }
            if fails.isEmpty { print("check-panels OK (\(checked) Fenster)"); exit(0) }
            for f in fails { print("FAIL: \(f)") }
            exit(1)
        }
    }

    /// Fenster-ID, Rahmen (Punkte, Ursprung oben links wie CGWindowList), Ebene und Alpha in eine Datei.
    private static func dumpDemoWindows() {
        let h = NSScreen.screens.first?.frame.height ?? 0
        var lines: [String] = []
        for w in NSApp.windows where w.isVisible {
            let f = w.frame
            lines.append("id=\(w.windowNumber) class=\(type(of: w)) x=\(f.minX) y=\(h - f.maxY) w=\(f.width) h=\(f.height) level=\(w.level.rawValue) alpha=\(w.alphaValue) key=\(w.isKeyWindow)")
        }
        try? lines.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "recblitz_demo.txt",
                                                  atomically: true, encoding: .utf8)
    }

    /// Nur für den Prüfmodus.
    fileprivate var phaseName: String {
        switch phase {
        case .idle: return "idle"; case .armed: return "armed"
        case .recording: return "recording"; case .transcribing: return "transcribing"
        case .uploading: return "uploading"
        }
    }
    fileprivate var discardingFlag: Bool { discarding }
    fileprivate var screenActive: Bool { screenRecordingActive }

    // MARK: - Interaktion

    @objc private func statusClicked() {
        let button = statusItem.button
        let appState = state
        MainActor.assumeIsolated {
            PanelController.shared.toggle(state: appState, statusButton: button)
        }
    }

    private func toggle() {
        if cueStarting { return }   // Startton laeuft, nicht doppelt starten
        switch phase {
        case .idle, .uploading: startRecording()
        case .armed:            startFromArmed()      // Kürzel = Play
        case .recording:        stopRecording()
        case .transcribing:     break
        }
    }

    private func startRecording() {
        guard !recorder.isRecording, !screenRecordingActive, phase != .armed else { return }
        let cfg = ConfigStore.shared
        // Nie eine stumme Aufnahme: ohne Mikro UND ohne Systemton gar nicht erst starten.
        guard cfg.captureMicrophone || cfg.screenSystemAudio else {
            Banner.show(title: L.t("Mikrofon oder Systemton einschalten", "Turn on microphone or system audio"),
                        subtitle: L.t("Beide sind aus, die Aufnahme wäre stumm.",
                                      "Both are off, the recording would be silent."),
                        url: nil, isError: true)
            return
        }
        let mode = cfg.screenMode
        if mode != "off" {
            startScreenRecording(mode: mode)
            return
        }
        if cfg.screenSystemAudio {
            // Kein Region-Picker, keine Leiste, kein Vorlauf: fühlt sich an wie
            // die normale Sprachnotiz und startet sofort.
            let chosen = cfg.screenDisplayID
            startCapture(scope: .fullScreen(displayID: chosen > 0 ? CGDirectDisplayID(chosen) : nil),
                         audioOnly: true)
            return
        }
        startMicRecording()
    }

    // MARK: - Bildschirmaufnahme (31.07.)

    /// Bereich zuerst auswählen lassen, dann aufnehmen. Das Panel ist zu diesem
    /// Zeitpunkt schon zu (der Button schließt es), die Zieh-Auswahl liegt also
    /// frei über dem, was man zeigen will.
    private func startScreenRecording(mode: String) {
        if mode == "region" {
            MainActor.assumeIsolated {
                RegionPicker.pick { [weak self] picked in
                    guard let self else { return }
                    guard let picked else { return }        // Escape = kein Fehler
                    // Der Bildschirm kommt aus der Auswahl, NICHT aus den
                    // Einstellungen — man zieht den Bereich ja dort auf, wo man
                    // ihn haben will.
                    self.enterArmed(scope: .region(picked.rect, displayID: picked.displayID))
                }
            }
        } else {
            let chosen = ConfigStore.shared.screenDisplayID
            enterArmed(scope: .fullScreen(
                displayID: chosen > 0 ? CGDirectDisplayID(chosen) : nil))
        }
    }

    // MARK: - Bereit-Zustand (01.08.)

    /// Alles vorbereiten, aber noch nicht aufnehmen: Ausschnitt steht, Webcam
    /// steht, die Steuerleiste zeigt "Bereit" mit Aufnehmen-Knopf. So kann man
    /// sich in Ruhe sortieren, statt vom Vorlauf überrascht zu werden.
    private func enterArmed(scope: CaptureScope) {
        guard !recorder.isRecording, !screenRecordingActive, phase != .armed else { return }
        activeScope = scope
        phase = .armed
        // Blase nachziehen, falls der Schalter an ist sie aber (z.B. nach einem
        // App-Neustart) noch nicht steht. Bereits sichtbare NIE neu erzeugen.
        if ConfigStore.shared.webcamEnabled {
            MainActor.assumeIsolated {
                if !WebcamBubble.shared.isVisible { syncWebcamBubble(enabled: true) }
            }
        }
        showControlBar(for: scope, armed: true)
    }

    /// Play in der Bereit-Leiste (oder ⌥⌘R).
    private func startFromArmed() {
        guard phase == .armed, let scope = activeScope else { return }
        beginScreenCapture(scope: scope)
    }

    /// Bereit-Zustand verlassen, ohne aufzunehmen. Räumt AUCH einen eventuell
    /// schon laufenden Vorlauf ab — sonst startet der danach eine Aufnahme, die
    /// niemand mehr wollte und die keine Steuerleiste mehr hat.
    private func cancelArmed() {
        MainActor.assumeIsolated {
            CountdownOverlay.dismiss()
            RecordingControlBar.shared.hide(); RegionFrame.shared.hide()
            WebcamBubble.shared.hide()
        }
        activeScope = nil
        phase = uploadsInFlight > 0 ? .uploading : .idle
    }

    /// Blase an den Schalter angleichen. Sie lebt UNABHÄNGIG von der Aufnahme:
    /// einmal eingeschaltet steht sie da, kann in Ruhe verschoben werden und
    /// bleibt beim Start der Aufnahme genau dort — deshalb darf sie beim
    /// Aufnahmestart NICHT neu erzeugt werden (das würde sie zurückspringen
    /// lassen und die Fenster-ID ändern).
    private func syncWebcamBubble(enabled: Bool) {
        MainActor.assumeIsolated {
            if enabled {
                guard !WebcamBubble.shared.isVisible else { return }
                let target = defaultCaptureScreen()
                let d = CGFloat(ConfigStore.shared.webcamSize)
                Task { @MainActor in
                    if await WebcamBubble.shared.show(on: target, diameter: d) == false {
                        Banner.show(title: L.t("Webcam nicht verfügbar", "Webcam unavailable"),
                                    subtitle: L.t("Kamera-Zugriff prüfen: Systemeinstellungen → Datenschutz → Kamera.",
                                                  "Check camera access: System Settings → Privacy → Camera."),
                                    url: nil, isError: true)
                    }
                }
            } else {
                WebcamBubble.shared.hide()
            }
        }
    }

    /// Bildschirm, auf dem eine Bildschirmaufnahme aktuell landen würde.
    private func defaultCaptureScreen() -> NSScreen? {
        let chosen = ConfigStore.shared.screenDisplayID
        guard chosen > 0 else { return NSScreen.main }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                == CGDirectDisplayID(chosen)
        } ?? NSScreen.main
    }

    /// Auf welchem Bildschirm liegt dieser Ausschnitt?
    private func screenFor(_ scope: CaptureScope) -> NSScreen? {
        let targetID: CGDirectDisplayID?
        switch scope {
        case .fullScreen(let id): targetID = id
        case .region(_, let id):  targetID = id
        case .window:             targetID = nil
        }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == targetID
        }
    }

    /// Vorlauf, dann aufnehmen. Der Countdown erscheint auf dem Bildschirm, der
    /// aufgenommen wird — dort schaut man in dem Moment hin.
    private func beginScreenCapture(scope: CaptureScope) {
        let seconds = ConfigStore.shared.countdownSeconds
        guard seconds > 0 else { startCapture(scope: scope); return }

        let targetID: CGDirectDisplayID?
        switch scope {
        case .fullScreen(let id): targetID = id
        case .region(_, let id):  targetID = id
        case .window:             targetID = nil
        }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == targetID
        }
        MainActor.assumeIsolated {
            // Blase NICHT neu erzeugen — sie steht schon, seit der Schalter an
            // ist, und der Nutzer hat sie dort hingeschoben, wo er sie haben will.
            CountdownOverlay.run(seconds: seconds, on: screen,
                                 onCancel: { [weak self] in
                                     // Escape im Vorlauf: zurück in den Bereit-
                                     // Zustand, nicht alles wegwerfen.
                                     guard let self, self.phase == .armed else { return }
                                     MainActor.assumeIsolated {
                                         RecordingControlBar.shared.setArmed(true)
                                     }
                                 }) { [weak self] in
                self?.startCapture(scope: scope)
            }
        }
    }

    private func startCapture(scope: CaptureScope, audioOnly: Bool = false) {
        // Eigener Guard: seit es den Play-Knopf gibt, ist startRecording() nicht
        // mehr der einzige Weg hierher. Ohne das könnten zwei Recorder parallel
        // laufen und die App danach dauerhaft blockieren.
        guard !recorder.isRecording, !screenRecordingActive else { return }
        let cfg = ConfigStore.shared
        guard cfg.captureMicrophone || cfg.screenSystemAudio else {
            cancelArmed()
            Banner.show(title: L.t("Mikrofon oder Systemton einschalten", "Turn on microphone or system audio"),
                        subtitle: L.t("Beide sind aus, die Aufnahme wäre stumm.",
                                      "Both are off, the recording would be silent."),
                        url: nil, isError: true)
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let url = Recorder.recordingsDir.appendingPathComponent(
            "\(audioOnly ? "audio" : "screen")_\(df.string(from: Date())).mp4")

        let opts = ScreenRecorder.Options(
            scope: scope,
            includeSystemAudio: cfg.screenSystemAudio,
            captureMicrophone: cfg.captureMicrophone,
            // Die Mikrofon-Auswahl aus den Einstellungen gilt auch hier.
            microphoneDeviceID: Recorder.captureMicID(),
            maxDimension: audioOnly ? 320 : (cfg.screenMaxDimension > 0 ? cfg.screenMaxDimension : nil),
            fps: audioOnly ? 1 : max(15, cfg.screenFPS),
            // Die Blase gehört uns und wäre sonst mit ausgeschlossen — sie soll
            // aber gerade zu sehen sein.
            includeWindowIDs: audioOnly ? [] : MainActor.assumeIsolated {
                WebcamBubble.shared.windowID.map { [$0] } ?? []
            })

        cueStarting = true
        Task { @MainActor in
            await Cue.playStart()
            cueStarting = false
            do {
                try await screenRecorder.start(to: url, options: opts)
                screenRecordingActive = true
                audioOnlyViaScreen = audioOnly
                recordedTwoAudioTracks = opts.captureMicrophone && opts.includeSystemAudio
                activeScope = scope
                phase = .recording
                state.elapsed = 0
                state.paused = false
                timer?.invalidate()          // alten Ticker nie doppelt laufen lassen
                // Leiste NICHT neu aufbauen: sie steht schon und wurde
                // vielleicht verschoben. Nur den Zustand umschalten.
                if audioOnly {
                    // keine Leiste: „Nur Ton" bleibt unsichtbar wie die Sprachnotiz
                } else if RecordingControlBar.shared.isVisible {
                    RecordingControlBar.shared.setArmed(false)
                } else {
                    showControlBar(for: scope)
                }
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.state.elapsed = Int(self.screenRecorder.elapsed)
                    if !self.audioOnlyViaScreen {
                        MainActor.assumeIsolated {
                            RecordingControlBar.shared.update(elapsed: self.screenRecorder.elapsed,
                                                              paused: self.screenRecorder.isPaused)
                        }
                    }
                    self.render()
                }
            } catch {
                Banner.show(title: audioOnly ? L.t("Systemton-Aufnahme fehlgeschlagen", "System audio recording failed")
                                             : L.t("Bildschirmaufnahme fehlgeschlagen", "Screen recording failed"),
                            subtitle: error.localizedDescription
                                + (audioOnly ? "\n" + L.t("Systemton braucht die Bildschirmaufnahme-Erlaubnis. Oder Systemton ausschalten, dann läuft nur das Mikrofon.",
                                                          "System audio needs the screen recording permission. Or turn system audio off to record the mic only.") : ""),
                            url: nil, isError: true)
                RecordingControlBar.shared.hide(); RegionFrame.shared.hide()
                activeScope = nil
                phase = uploadsInFlight > 0 ? .uploading : .idle
            }
        }
    }

    /// Stoppt den Bildschirm-Pfad: Datei finalisieren, Tonspur herausziehen und
    /// die bestehende Transkript-/Doc-Kette damit füttern. Das Video reist als
    /// zusätzliches Argument mit, damit die Pipeline es nach Drive lädt.
    private func stopScreenRecording() {
        Task { @MainActor in
            let audioOnly = audioOnlyViaScreen
            audioOnlyViaScreen = false
            guard let (videoURL, seconds) = await screenRecorder.stop() else {
                screenRecordingActive = false
                phase = .idle
                return
            }
            screenRecordingActive = false
            if !audioOnly { Cue.playStop() }

            if seconds < 2 {                       // Fehlklick-Schutz wie beim Mikro
                try? FileManager.default.removeItem(at: videoURL)
                phase = uploadsInFlight > 0 ? .uploading : .idle
                return
            }

            // Mit Systemton entstehen ZWEI Tonspuren (Mikro + System). Player
            // spielen meist nur die erste — vor allem die Drive-Vorschau. Also
            // vor dem Weiterreichen auf eine Spur mischen.
            if recordedTwoAudioTracks {
                if !AudioMixdown.mixToSingleTrack(at: videoURL) {
                    NSLog("RecBlitz: Tonspuren nicht gemischt (ffmpeg fehlt?), Video hat zwei Spuren")
                }
            }

            let audioURL = videoURL.deletingPathExtension().appendingPathExtension("m4a")
            do {
                try await AudioExtractor.extractAudio(from: videoURL, to: audioURL)
                if audioOnly {
                    // „Nur Ton": das Mini-Video war nur Mittel zum Zweck. Weg damit,
                    // kein Upload (pendingVideoURL bleibt leer).
                    try? FileManager.default.removeItem(at: videoURL)
                } else {
                    // Original dauerhaft nach ~/Movies/RecBlitz (nie auto-löschen).
                    pendingVideoURL = Recorder.keepOriginalVideo(videoURL)
                }
                handleRecordingFinished(url: audioURL, seconds: seconds)
            } catch {
                // Ohne Ton kein Transkript — das Video ist trotzdem da, also nicht
                // wegwerfen, sondern melden und im Ordner lassen.
                Banner.show(title: L.t("Kein Ton in der Aufnahme", "No audio in the recording"),
                            subtitle: error.localizedDescription + "\n"
                                + L.t("Video liegt in den lokalen Aufnahmen.", "The video is in your local recordings."),
                            url: videoURL, isError: true)
                phase = .idle
            }
        }
    }

    private func startMicRecording() {
        recorder.requestAccess { [weak self] ok in
            guard let self else { return }
            guard ok else {
                Banner.show(title: L.t("Kein Mikrofon-Zugriff", "No microphone access"),
                            subtitle: L.t("Systemeinstellungen → Datenschutz → Mikrofon → RecBlitz erlauben.",
                                          "System Settings → Privacy → Microphone → allow RecBlitz."),
                            url: nil, isError: true)
                return
            }
            self.cueStarting = true
            Task { @MainActor in
            await Cue.playStart()
            self.cueStarting = false
            do {
                try self.recorder.start()
                self.phase = .recording
                self.state.elapsed = 0
                self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.state.elapsed = Int(self.recorder.elapsed)
                    self.render()
                }
            } catch {
                Banner.show(title: L.t("Aufnahme fehlgeschlagen", "Recording failed"),
                            subtitle: error.localizedDescription, url: nil, isError: true)
            }
            }
        }
    }

    /// Loom-artige Steuerleiste unten links auf dem aufgenommenen Bildschirm.
    /// Sie gehört RecBlitz und ist damit aus der Aufnahme ausgeschlossen.
    private func showControlBar(for scope: CaptureScope, armed: Bool = false) {
        let targetID: CGDirectDisplayID?
        switch scope {
        case .fullScreen(let id): targetID = id
        case .region(_, let id):  targetID = id
        case .window:             targetID = nil
        }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == targetID
        }
        MainActor.assumeIsolated {
            RegionFrame.shared.show(for: scope)
            RecordingControlBar.shared.show(
                on: screen,
                armed: armed,
                onStart:       { [weak self] in self?.startFromArmed() },
                onTogglePause: { [weak self] in self?.togglePause() },
                onRestart:     { [weak self] in self?.restartRecording() },
                onDiscard:     { [weak self] in self?.discardRecording() },
                onStop:        { [weak self] in self?.stopRecording() })
        }
    }

    /// Verwerfen und mit demselben Ausschnitt neu anfangen — inklusive Vorlauf,
    /// damit man sich wieder sortieren kann.
    private func restartRecording() {
        guard screenRecordingActive, let scope = activeScope else { return }
        timer?.invalidate(); timer = nil
        MainActor.assumeIsolated { RecordingControlBar.shared.hide(); RegionFrame.shared.hide() }
        Task { @MainActor in
            let result = await screenRecorder.stop()
            screenRecordingActive = false
            state.paused = false
            if let (url, _) = result { try? FileManager.default.removeItem(at: url) }
            phase = uploadsInFlight > 0 ? .uploading : .idle
            // Zurück in den Bereit-Zustand: nach einem Fehlversuch will man sich
            // neu sortieren, nicht sofort wieder im Vorlauf stehen.
            enterArmed(scope: scope)
        }
    }

    /// Pause nur im Bildschirm-Pfad: der Mikro-Recorder (AVCaptureFileOutput)
    /// hat kein Pause, und eine Sprachnotiz ist ohnehin in Sekunden vorbei.
    private func togglePause() {
        guard screenRecordingActive else { return }
        MainActor.assumeIsolated {
            screenRecorder.setPaused(!screenRecorder.isPaused)
            state.paused = screenRecorder.isPaused
            RecordingControlBar.shared.update(elapsed: screenRecorder.elapsed,
                                              paused: screenRecorder.isPaused)
            render()
        }
    }

    private func stopRecording() {
        timer?.invalidate()
        timer = nil
        state.paused = false
        // Blase mit ausblenden: die Aufnahme ist vorbei, sie hat nichts mehr auf
        // dem Bildschirm zu suchen (Rückmeldung 01.08.). Der Schalter bleibt an, beim
        // nächsten Vorbereiten kommt sie automatisch wieder.
        MainActor.assumeIsolated {
            RecordingControlBar.shared.hide(); RegionFrame.shared.hide()
            WebcamBubble.shared.hide()
        }
        phase = .transcribing // sofortiges Feedback, Datei-Finalisierung kommt gleich
        if screenRecordingActive { stopScreenRecording() } else { recorder.stop() }
    }

    /// Aufnahme abbrechen: sauber stoppen (die Datei MUSS finalisiert werden,
    /// sonst bleibt ein kaputter Rest liegen) und dann löschen. Keine
    /// Transkription, kein Upload, keine Notiz.
    private func discardRecording() {
        timer?.invalidate()
        timer = nil
        state.paused = false
        // Noch gar keine Aufnahme (Bereit-Zustand oder laufender Vorlauf):
        // NICHT `discarding` setzen — es gäbe kein onFinished, das es je wieder
        // zurücksetzt, und der nächste echte Stopp würde stillschweigend
        // weggeworfen.
        guard screenRecordingActive || recorder.isRecording else {
            cancelArmed()
            return
        }
        MainActor.assumeIsolated {
            RecordingControlBar.shared.hide(); RegionFrame.shared.hide()
            WebcamBubble.shared.hide()
        }
        discarding = true
        if screenRecordingActive {
            Task { @MainActor in
                let result = await screenRecorder.stop()
                screenRecordingActive = false
                audioOnlyViaScreen = false
                if let (url, _) = result { try? FileManager.default.removeItem(at: url) }
                discarding = false
                phase = uploadsInFlight > 0 ? .uploading : .idle
                Banner.show(title: L.t("Aufnahme verworfen", "Recording discarded"),
                            subtitle: L.t("Nichts gespeichert, nichts hochgeladen.", "Nothing saved, nothing uploaded."), url: nil)
            }
        } else {
            // Mikro-Pfad meldet die Datei asynchron über den Delegate; das
            // Aufräumen passiert dort anhand von `discarding`.
            recorder.stop()
        }
    }

    // MARK: - Verarbeitung

    private func handleRecordingFinished(url: URL, seconds: TimeInterval) {
        if discarding {
            discarding = false
            try? FileManager.default.removeItem(at: url)
            if let v = pendingVideoURL {          // sonst bleibt das Video liegen
                try? FileManager.default.removeItem(at: v)
                pendingVideoURL = nil
            }
            phase = uploadsInFlight > 0 ? .uploading : .idle
            Banner.show(title: L.t("Aufnahme verworfen", "Recording discarded"),
                            subtitle: L.t("Nichts gespeichert, nichts hochgeladen.", "Nothing saved, nothing uploaded."), url: nil)
            return
        }
        // Versehentlicher Klick: unter 2 Sekunden verwerfen.
        if seconds < 2 {
            try? FileManager.default.removeItem(at: url)
            phase = uploadsInFlight > 0 ? .uploading : .idle
            return
        }
        if #available(macOS 26.0, *) {
            let setting = ConfigStore.shared.language
            if setting == "auto" {
                // Schnelle Sprach-Erkennung (whisper-tiny, ~2s), dann Apple Speech.
                PipelineRunner.detectLanguage(audioPath: url.path) { [weak self] code in
                    guard let self else { return }
                    let map = ["de": "de-DE", "en": "en-US", "es": "es-ES"]
                    if let code, let locale = map[code] {
                        self.transcribeNative(url: url, seconds: seconds, locale: locale)
                    } else if code == nil {
                        // Erkennung gar nicht verfügbar (kein Whisper installiert):
                        // dann in der App-Sprache transkribieren statt mit einem
                        // Whisper-Rückfall zu scheitern, der ebenso fehlt.
                        self.transcribeNative(url: url, seconds: seconds,
                                              locale: L.isDE ? "de-DE" : "en-US")
                    } else {
                        // Unbekannte Sprache -> Whisper mit Auto-Detect
                        self.runWhisperFallback(url: url, seconds: seconds,
                                                reason: "Auto-Erkennung: \(code ?? "fehlgeschlagen")")
                    }
                }
            } else {
                transcribeNative(url: url, seconds: seconds, locale: setting)
            }
        } else {
            runWhisperFallback(url: url, seconds: seconds, reason: "macOS < 26")
        }
    }

    private func transcribeNative(url: URL, seconds: TimeInterval, locale: String) {
        if #available(macOS 26.0, *) {
            Task {
                do {
                    let t0 = Date()
                    let text = try await Transcriber.transcribe(fileURL: url, localeIdentifier: locale)
                    let dt = Date().timeIntervalSince(t0)
                    await MainActor.run {
                        if text.isEmpty {
                            self.runWhisperFallback(url: url, seconds: seconds, reason: "leeres Ergebnis")
                        } else {
                            self.handleTranscript(text, audioURL: url, seconds: seconds, elapsed: dt)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.runWhisperFallback(url: url, seconds: seconds,
                                                reason: error.localizedDescription)
                    }
                }
            }
        } else {
            runWhisperFallback(url: url, seconds: seconds, reason: "macOS < 26")
        }
    }

    static var lastTranscriptURL: URL {
        Recorder.recordingsDir.deletingLastPathComponent().appendingPathComponent("last_transcript.txt")
    }

    private func rememberTranscript(_ text: String) {
        state.lastTranscript = text
        try? text.write(to: AppDelegate.lastTranscriptURL, atomically: true, encoding: .utf8)
    }

    private func handleTranscript(_ text: String, audioURL: URL, seconds: TimeInterval, elapsed: TimeInterval) {
        rememberTranscript(text)
        let preview = String(text.prefix(160)) + (text.count > 160 ? "…" : "")
        let next = ConfigStore.shared.driveEnabled
            ? L.t("Google Doc wird erstellt …", "Creating Google Doc …")
            : L.t("Notiz wird gespeichert …", "Saving note …")
        Banner.show(title: String(format: L.t("Transkript fertig (%.1fs)", "Transcript ready (%.1fs)"), elapsed),
                    subtitle: preview + "\n" + next, url: nil)

        let txtURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recblitz_\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try text.write(to: txtURL, atomically: true, encoding: .utf8)
        } catch {
            Banner.show(title: L.t("Fehler", "Error"),
                        subtitle: L.t("Transkript konnte nicht gespeichert werden", "Could not save the transcript")
                            + ": \(error.localizedDescription)",
                        url: nil, isError: true)
            phase = .idle
            return
        }
        var args = ["--text", txtURL.path, "--audio", audioURL.path,
                    "--duration", String(Int(seconds))]
        if let video = pendingVideoURL {
            args += ["--video", video.path]
            pendingVideoURL = nil
            uploadingVideoPath = video       // fürs Aufräumen nach Erfolg
            // Panel zeigt "Video wird hochgeladen", aber nur, wenn es auch wirklich
            // nach Drive geht. Ohne Drive bleibt das Video lokal liegen.
            state.uploadingVideo = ConfigStore.shared.driveEnabled
            state.uploadProgress = nil
        }
        launchPipeline(arguments: args)
    }

    private func runWhisperFallback(url: URL, seconds: TimeInterval, reason: String) {
        NSLog("RecBlitz: Whisper-Fallback (%@)", reason)
        phase = .transcribing
        launchPipeline(arguments: [url.path], keepTranscribingPhase: true)
    }

    private func launchPipeline(arguments: [String], keepTranscribingPhase: Bool = false) {
        uploadsInFlight += 1
        state.uploading = true
        if !keepTranscribingPhase { phase = .uploading }
        PipelineRunner.run(arguments: arguments, onProgress: { [weak self] pct in
            self?.state.uploadProgress = pct
        }) { [weak self] result, errorMessage in
            guard let self else { return }
            self.uploadsInFlight -= 1
            self.state.uploading = self.uploadsInFlight > 0
            self.state.uploadingVideo = false
            self.state.uploadProgress = nil
            // Weder eine laufende noch eine vorbereitete Aufnahme ueberschreiben.
            if self.phase != .recording, self.phase != .armed {
                self.phase = self.uploadsInFlight > 0 ? .uploading : .idle
            }
            if let result {
                if let text = result.text, !text.isEmpty {
                    self.rememberTranscript(text) // deckt den Whisper-Fallback ab
                }
                let docURL = result.doc_url.flatMap(URL.init(string:))
                let mdPath = result.obsidian_path.flatMap { $0.isEmpty ? nil : $0 }
                var videoURL = result.video_url.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                var sub = result.preview ?? ""
                if let mdErr = result.obsidian_error, !mdErr.isEmpty {
                    sub += "\n⚠️ Markdown: \(mdErr)"
                }
                if let docErr = result.doc_error, !docErr.isEmpty {
                    sub += "\n⚠️ Google Doc: \(docErr)"
                }
                // Das Ergebnis mit dem höchsten Nutzen gewinnt die Meldung:
                // Video vor Doc vor Markdown-Notiz.
                var title = L.t("Notiz gespeichert", "Note saved")
                var bannerURL = mdPath.map { URL(fileURLWithPath: $0) }
                if let docURL {
                    title = L.t("Google Doc bereit", "Google Doc ready")
                    bannerURL = docURL
                }
                // Bei einem Screencast ist der Video-Link das, was man
                // weiterschickt, der gehört sofort in die Zwischenablage, sonst
                // sucht man ihn im Doc oder in Drive zusammen.
                if let videoURL {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(videoURL.absoluteString, forType: .string)
                    // Klick auf die Meldung soll das VIDEO öffnen, nicht das Doc,
                    // das Video ist bei einem Screencast die Hauptsache.
                    bannerURL = videoURL
                    title = L.t("Video bereit · Link kopiert", "Video ready · link copied")
                    // Das Original bleibt lokal (~/Movies/RecBlitz), nie automatisch löschen.
                } else if let local = self.uploadingVideoPath,
                          FileManager.default.fileExists(atPath: local.path) {
                    // Ohne Drive bleibt das Video lokal. Die Zeile „Zuletzt"
                    // öffnet es dann direkt, statt ins Leere zu zeigen.
                    videoURL = local
                }
                let keptLocal = self.uploadingVideoPath.flatMap {
                    FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil }
                self.uploadingVideoPath = nil
                if let vErr = result.video_error, !vErr.isEmpty {
                    sub += "\n⚠️ \(vErr)"
                }
                self.state.last = LastResult(title: result.title ?? L.t("Sprachnotiz", "Voice note"),
                                             date: Date(), docURL: docURL, videoURL: videoURL,
                                             markdownPath: mdPath, localVideoPath: keptLocal)
                self.state.last?.save()
                Banner.show(title: title, subtitle: sub, url: bannerURL)
            } else {
                Banner.show(title: L.t("Verarbeitung fehlgeschlagen", "Processing failed"),
                            subtitle: errorMessage ?? L.t("Unbekannter Fehler", "Unknown error"),
                            url: nil, isError: true, seconds: 20)
            }
        }
    }

    // MARK: - Menüleisten-Icon

    private func render() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        switch phase {
        case .idle:
            // Nicht "mic": andere Diktier-Apps belegen das Mikro-Symbol schon.
            button.image = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "RecBlitz")
                ?? NSImage(systemSymbolName: "recordingtape", accessibilityDescription: "RecBlitz")
            button.contentTintColor = nil
            button.title = ""
        case .armed:
            // Sichtbar anders als "läuft": es wird noch NICHT aufgenommen.
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: L.t("Bereit zur Aufnahme", "Ready to record"))
            button.contentTintColor = .systemOrange
            button.title = ""
        case .recording:
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: L.t("Aufnahme läuft", "Recording"))
            button.contentTintColor = .systemRed
            // state.elapsed statt recorder.elapsed: bei Bildschirmaufnahme läuft
            // der Mikro-Recorder gar nicht, seine Uhr stand deshalb auf 0:00
            // während das Panel schon zählte (Rückmeldung 31.07.). Der Timer füttert
            // state.elapsed aus dem jeweils aktiven Recorder.
            let s = state.elapsed
            button.title = String(format: " %d:%02d", s / 60, s % 60)
        case .transcribing:
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: L.t("Transkribiere", "Transcribing"))
            button.contentTintColor = nil
            button.title = ""
        case .uploading:
            button.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: L.t("Wird gespeichert", "Saving"))
            button.contentTintColor = nil
            button.title = ""
        }
    }
}

// CLI-Testmodi, alle ohne Menüleisten-Icon und ohne Nebenwirkungen:
//   RecBlitz --transcribe <audio> [locale]   transkribiert und beendet sich
//   RecBlitz --render-panel <png> [state] [--light]
//       rendert Panel oder Einstellungen als Bild (Design-Check). state:
//       idle | recording | paused | armed | uploading | empty | settings[=N]
//   RecBlitz --selftest                      prüft reine Logik, Exit 1 bei Fehler
let cliArgs = CommandLine.arguments

// Gemeinsame Schalter fuer alle Test-Modi.
//   --lang=en|de   feste Sprache (ohne die gespeicherte Wahl anzufassen)
//   --demo-config  erfundene Daten statt der echten Konfiguration (PFLICHT fuer jedes Foto)
//   --light        helles Aussehen
//   --bg=gray|white|black|clear   Untergrund der Test-Bilder (Standard grau)
if let l = cliArgs.first(where: { $0.hasPrefix("--lang=") }) { L.override = String(l.dropFirst(7)) }
if cliArgs.contains("--demo-config") || cliArgs.contains("--demo-window") || cliArgs.contains("--check-panels") {
    ConfigStore.useDefaultsOnly = true
    Demo.on = true
}
if cliArgs.contains("--render-panel") || cliArgs.contains("--render-settings")
    || cliArgs.contains("--render-banner") || cliArgs.contains("--render-region") {
    Theme.flatGlass = true
}

func renderBackground() -> NSColor? {
    switch cliArgs.first(where: { $0.hasPrefix("--bg=") }).map({ String($0.dropFirst(5)) }) ?? "gray" {
    case "white": return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    case "black": return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    case "clear": return nil
    default: return NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    }
}

/// Rendert eine NSView ueber ein echtes, unsichtbares Fenster (zeichnet auch AppKit-Steuerelemente),
/// als sRGB-PNG, 2x (Retina). Offscreen gibt es kein Liquid Glass, siehe `Theme.flatGlass`.
@MainActor
func renderToPNG(_ host: NSView, size: CGSize, path: String, dark: Bool, bg: NSColor?) -> Bool {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.appearance = appearance
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.isOpaque = false
    window.backgroundColor = .clear
    let root = NSView(frame: CGRect(origin: .zero, size: size))
    root.wantsLayer = true
    root.layer?.backgroundColor = (bg ?? .clear).cgColor
    host.frame = root.bounds
    root.addSubview(host)
    window.contentView = root
    // SwiftUI misst Inhalte (Reiter-Hoehe, Klapp-Bereiche) erst nach dem ersten Layout: Runloop kurz laufen lassen.
    for _ in 0..<3 {
        root.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }
    root.displayIfNeeded()
    guard let raw = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return false }
    root.cacheDisplay(in: root.bounds, to: raw)
    let rep = raw.converting(to: .sRGB, renderingIntent: .default) ?? raw
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}

@MainActor
func renderToPNG<V: View>(_ view: V, path: String, dark: Bool, bg: NSColor? = renderBackground()) -> Bool {
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    // Erst in einem Hilfsfenster laufen lassen, damit SwiftUI seine Messungen (Reiter-Hoehe, Klapp-Bereiche)
    // abschliesst; danach erst die Groesse nehmen.
    let tmp = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 1600),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    tmp.appearance = host.appearance
    tmp.contentView = host
    for _ in 0..<3 {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }
    let size = host.fittingSize
    tmp.contentView = nil
    return renderToPNG(host, size: size, path: path, dark: dark, bg: bg)
}

// Banner-Design-Check: `--render-banner <png> [error] [--light]`
if cliArgs.count >= 3, cliArgs[1] == "--render-banner" {
    let isErr = cliArgs.contains("error")
    let ok: Bool = MainActor.assumeIsolated {
        renderToPNG(BannerView(title: isErr ? L.t("Aufnahme fehlgeschlagen", "Recording failed") : L.t("Video bereit · Link kopiert", "Video ready · link copied"),
                               subtitle: isErr ? L.t("Kein Mikrofon-Zugriff", "No microphone access")
                                               : L.t("Besprechung Onboarding und die zwei offenen Fragen", "Onboarding meeting and the two open questions"),
                               isError: isErr, hint: nil, hasLink: true, onTap: {}, onClose: {}),
                    path: cliArgs[2], dark: !cliArgs.contains("--light"))
    }
    print(ok ? "OK" : "ERROR"); exit(ok ? 0 : 1)
}

// Bereichsrahmen-Check: `--render-region <png>` (600x400, Loch 300x200 bei (150,100), Untergrund hellgrau)
if cliArgs.count >= 3, cliArgs[1] == "--render-region" {
    let ok: Bool = MainActor.assumeIsolated {
        let v = DimView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        v.hole = CGRect(x: 150, y: 100, width: 300, height: 200)
        return renderToPNG(v, size: v.frame.size, path: cliArgs[2], dark: true,
                           bg: NSColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1))
    }
    print(ok ? "OK" : "ERROR"); exit(ok ? 0 : 1)
}

// Einstellungen: `--render-settings <png> <reiter 0-3> [--light]`
if cliArgs.count >= 3, cliArgs[1] == "--render-settings" {
    let tab = cliArgs.count > 3 ? Int(cliArgs[3]) ?? 0 : 0
    let ok: Bool = MainActor.assumeIsolated {
        renderToPNG(SettingsPane(tab: tab), path: cliArgs[2], dark: !cliArgs.contains("--light"))
    }
    print(ok ? "OK \(cliArgs[2])" : "ERROR render"); exit(ok ? 0 : 1)
}

if cliArgs.count >= 3, cliArgs[1] == "--render-panel" {
    let mode = cliArgs.count > 3 && !cliArgs[3].hasPrefix("--") ? cliArgs[3] : "idle"
    let dark = !cliArgs.contains("--light")
    if let m = cliArgs.first(where: { $0.hasPrefix("--mode=") }) {
        ConfigStore.shared.screenMode = String(m.dropFirst(7))
    }
    let ok: Bool = MainActor.assumeIsolated {
        if mode.hasPrefix("settings") {   // alte Schreibweise, bleibt lesbar
            return renderToPNG(SettingsPane(tab: Int(mode.split(separator: "=").last ?? "") ?? 0),
                               path: cliArgs[2], dark: dark)
        }
        return renderToPNG(RecPanelView(state: Demo.state(mode: mode), onSize: { _ in }), path: cliArgs[2], dark: dark)
    }
    print(ok ? "OK \(cliArgs[2])" : "ERROR render")
    exit(ok ? 0 : 1)
}

if cliArgs.count >= 2, cliArgs[1] == "--selftest" {
    var failures: [String] = []
    func expect(_ cond: Bool, _ what: String) { if !cond { failures.append(what) } }
    expect(ConfigStore.folderID(from: "https://drive.google.com/drive/folders/1AbC-d_E9?usp=sharing") == "1AbC-d_E9",
           "folderID aus Drive-Link")
    expect(ConfigStore.folderID(from: "  1AbC-d_E9 ") == "1AbC-d_E9", "folderID aus nackter ID")
    expect(ConfigStore.folderID(from: "") == "", "folderID leer")
    expect(LastRow.displayTitle("Plan fürs Onboarding - 2026-09-26 10.29 - RecBlitz") == "Plan fürs Onboarding",
           "Titel ohne Datumsanhang")
    let sample = LastResult(title: "T", date: Date(timeIntervalSince1970: 0),
                            docURL: URL(string: "https://example.com"), videoURL: nil, markdownPath: "/tmp/x.md")
    let roundTrip = (try? JSONEncoder().encode(sample)).flatMap { try? JSONDecoder().decode(LastResult.self, from: $0) }
    expect(roundTrip == sample, "LastResult JSON-Rundreise")
    expect(FileManager.default.fileExists(atPath: PipelineRunner.scriptPath), "pipeline.py im Bundle")
    // Runde 18: Theme-Werte (Rotprobe: RB_SELFTEST_BREAK=1 dreht eine Erwartung um, der Test MUSS dann rot werden).
    let broken = ProcessInfo.processInfo.environment["RB_SELFTEST_BREAK"] != nil
    expect(Theme.windowRadius == 26 && Theme.radius == 10 && Theme.innerRadius == 8 && Theme.smallRadius == 4,
           "Theme-Ecken 26/10/8/4")
    expect(Theme.rowHeight == (broken ? 33 : 32) && Theme.rowGap == 4 && Theme.primaryHeight == 36 && Theme.stageInset == 16,
           "Theme-Zeilen 32/4, Hauptknopf 36, Buehne 16")
    do {
        let c = Theme.blueNS.usingColorSpace(.sRGB) ?? Theme.blueNS
        let rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        expect(rgb == [41, 107, 250], "Akzent #296BFA, war \(rgb)")
    }
    expect([Theme.size(.big), Theme.size(.title), Theme.size(.heading), Theme.size(.normal), Theme.size(.small)] == [44, 22, 15, 13, 11],
           "Schriftstufen 44/22/15/13/11")
    expect(Look.mode == .dark || UserDefaults.standard.string(forKey: Look.appearanceKey) != nil,
           "Aussehen ohne gespeicherte Wahl = Dunkel")
    do {   // Testmodus liefert nur erfundene Mikrofone
        Demo.on = true; defer { Demo.on = false }
        let names = Recorder.micList().map(\.name)
        expect(names == ["MacBook Pro Microphone", "USB Mic Demo"], "Demo-Mikrofone erfunden, war \(names)")
    }
    do {   // Testmodus schreibt keine config.json
        let path = ConfigStore.path
        let before = try? Data(contentsOf: URL(fileURLWithPath: path))
        let wasDemo = ConfigStore.useDefaultsOnly
        ConfigStore.useDefaultsOnly = true; defer { ConfigStore.useDefaultsOnly = wasDemo }
        ConfigStore.shared.save()
        let after = try? Data(contentsOf: URL(fileURLWithPath: path))
        expect(before == after, "save() im Testmodus laesst config.json unveraendert")
    }
    if failures.isEmpty {
        print("selftest OK")
        exit(0)
    }
    for f in failures { print("FAIL: \(f)") }
    exit(1)
}

// Engine-Test ohne UI: `--test-audio-only <out.m4a> <sekunden> <mic:0|1> <system:0|1>`
// nimmt über denselben Pfad wie „Nur Ton" auf (Mini-Video, mixdown, Ton ausziehen,
// Video löschen) und schreibt das Ergebnis nach <out.m4a>. Log: <out.m4a>.log
if cliArgs.count >= 6, cliArgs[1] == "--test-audio-only" {
    let out = URL(fileURLWithPath: cliArgs[2])
    let secs = Double(cliArgs[3]) ?? 8
    let mic = cliArgs[4] == "1", sys = cliArgs[5] == "1"
    func log(_ m: String) {
        let line = m + "\n"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: out.path + ".log")) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else { try? line.write(toFile: out.path + ".log", atomically: true, encoding: .utf8) }
    }
    try? FileManager.default.removeItem(atPath: out.path + ".log")
    Task { @MainActor in
        let rec = ScreenRecorder()
        let video = out.deletingPathExtension().appendingPathExtension("mp4")
        do {
            try await rec.start(to: video, options: ScreenRecorder.Options(
                scope: .fullScreen(displayID: nil), includeSystemAudio: sys, captureMicrophone: mic,
                microphoneDeviceID: Recorder.captureMicID(), maxDimension: 320, fps: 1))
            log("started")
            try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            guard let (v, d) = await rec.stop() else { log("ERROR stop nil"); exit(1) }
            log("stopped \(d)s video=\(AudioExtractor.fileSize(v))B")
            if mic && sys { log("mix=\(AudioMixdown.mixToSingleTrack(at: v))") }
            try await AudioExtractor.extractAudio(from: v, to: out)
            try? FileManager.default.removeItem(at: v)
            log("DONE m4a=\(AudioExtractor.fileSize(out))B videoLeft=\(FileManager.default.fileExists(atPath: v.path))")
            exit(0)
        } catch {
            log("ERROR \(error.localizedDescription)")
            exit(1)
        }
    }
    let a = NSApplication.shared
    a.setActivationPolicy(.accessory)
    a.run()
}

// Qualitaets-/Overlay-Test: `--test-region <out.mp4> <sek> <x> <y> <w> <h> [displayID]`
// nimmt einen Bereich (Punkte, Ursprung oben links) MIT sichtbarem Region-Rahmen auf.
// Log: <out.mp4>.log. Danach ffprobe/ffmpeg auf die Datei.
if cliArgs.count >= 8, cliArgs[1] == "--test-region" {
    let out = URL(fileURLWithPath: cliArgs[2])
    let secs = Double(cliArgs[3]) ?? 4
    let rect = CGRect(x: Double(cliArgs[4]) ?? 0, y: Double(cliArgs[5]) ?? 0,
                      width: Double(cliArgs[6]) ?? 800, height: Double(cliArgs[7]) ?? 500)
    let did = cliArgs.count > 8 ? CGDirectDisplayID(cliArgs[8]) ?? CGMainDisplayID() : CGMainDisplayID()
    func log(_ m: String) {
        let line = m + "\n"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: out.path + ".log")) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else { try? line.write(toFile: out.path + ".log", atomically: true, encoding: .utf8) }
    }
    try? FileManager.default.removeItem(atPath: out.path + ".log")
    Task { @MainActor in
        let rec = ScreenRecorder()
        let scope = CaptureScope.region(rect, displayID: did)
        RegionFrame.shared.show(for: scope)
        await Cue.playStart()
        log("cue done")
        do {
            try await rec.start(to: out, options: ScreenRecorder.Options(
                scope: scope, includeSystemAudio: false, captureMicrophone: true,
                microphoneDeviceID: Recorder.captureMicID(), maxDimension: nil, fps: 30))
            log("started mic=\(Recorder.captureMicID() ?? "default")")
            try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            guard let (v, d) = await rec.stop() else { log("ERROR stop nil"); exit(1) }
            RegionFrame.shared.hide()
            log("DONE \(d)s size=\(AudioExtractor.fileSize(v))B")
            exit(0)
        } catch { log("ERROR \(error.localizedDescription)"); exit(1) }
    }
    let a = NSApplication.shared
    a.setActivationPolicy(.accessory)
    a.run()
}

if cliArgs.count >= 3, cliArgs[1] == "--transcribe" {
    if #available(macOS 26.0, *) {
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let t0 = Date()
                let text = try await Transcriber.transcribe(
                    fileURL: URL(fileURLWithPath: cliArgs[2]),
                    localeIdentifier: cliArgs.count > 3 ? cliArgs[3] : "de-DE")
                print(String(format: "ELAPSED %.2fs", Date().timeIntervalSince(t0)))
                print(text)
            } catch {
                print("ERROR: \(error)")
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    } else {
        print("ERROR: macOS 26 nötig")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
