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
    /// Video der gerade verarbeiteten Aufnahme; wird an pipeline.py durchgereicht,
    /// die es nach Drive lädt und den Link in Doc + Obsidian schreibt.
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

        // Verifikations-Hilfe: Meldung anzeigen, damit ihr Aussehen (u.a. das
        // Schließen-× in der Ecke) per Screenshot geprüft werden kann.
        if CommandLine.arguments.contains("--demo-banner") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Banner.show(title: L.t("Video bereit · Link kopiert", "Video ready · link copied"),
                            subtitle: L.t("Kurzer Rundgang durch das neue Dashboard und die offenen Punkte.",
                                          "A quick walkthrough of the new dashboard and the open items."),
                            url: URL(string: "https://example.com"),
                            seconds: 600,
                            hint: L.t("Klick öffnet das Video", "Click opens the video"),
                            screen: NSScreen.screens.count > 1
                                ? NSScreen.screens.first(where: { $0 !== NSScreen.main })
                                : nil)
            }
        }

        // Verifikations-Hilfe: Panel UND Einstellungen öffnen, damit die
        // Platzierung der Einstellungen relativ zum Panel prüfbar ist.
        if CommandLine.arguments.contains("--demo-settings") {
            let button = statusItem.button
            let appState = state
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    PanelController.shared.toggle(state: appState, statusButton: button)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    MainActor.assumeIsolated {
                        SettingsPanelController.shared.toggle(anchor: PanelController.shared.frame)
                    }
                }
            }
        }

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
                    RecordingControlBar.shared.hide()
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
                    let info = MainActor.assumeIsolated { SettingsPanelController.shared.debugInfo() }
                    try? info.write(toFile: NSTemporaryDirectory() + "recblitz_uitest.txt",
                                    atomically: true, encoding: .utf8)
                    exit(0)
                }
            }
        }
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
        switch phase {
        case .idle, .uploading: startRecording()
        case .armed:            startFromArmed()      // Kürzel = Play
        case .recording:        stopRecording()
        case .transcribing:     break
        }
    }

    private func startRecording() {
        guard !recorder.isRecording, !screenRecordingActive, phase != .armed else { return }
        let mode = ConfigStore.shared.screenMode
        if mode != "off" {
            startScreenRecording(mode: mode)
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
            RecordingControlBar.shared.hide()
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

    private func startCapture(scope: CaptureScope) {
        // Eigener Guard: seit es den Play-Knopf gibt, ist startRecording() nicht
        // mehr der einzige Weg hierher. Ohne das könnten zwei Recorder parallel
        // laufen und die App danach dauerhaft blockieren.
        guard !recorder.isRecording, !screenRecordingActive else { return }
        let cfg = ConfigStore.shared
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let url = Recorder.recordingsDir.appendingPathComponent("screen_\(df.string(from: Date())).mp4")

        let opts = ScreenRecorder.Options(
            scope: scope,
            includeSystemAudio: cfg.screenSystemAudio,
            // Die Mikrofon-Auswahl aus den Einstellungen gilt auch hier.
            microphoneDeviceID: Recorder.currentMic()?.uniqueID,
            maxDimension: cfg.screenMaxDimension > 0 ? cfg.screenMaxDimension : nil,
            fps: 30,
            // Die Blase gehört uns und wäre sonst mit ausgeschlossen — sie soll
            // aber gerade zu sehen sein.
            includeWindowIDs: MainActor.assumeIsolated {
                WebcamBubble.shared.windowID.map { [$0] } ?? []
            })

        Task { @MainActor in
            do {
                try await screenRecorder.start(to: url, options: opts)
                screenRecordingActive = true
                activeScope = scope
                phase = .recording
                state.elapsed = 0
                state.paused = false
                timer?.invalidate()          // alten Ticker nie doppelt laufen lassen
                // Leiste NICHT neu aufbauen: sie steht schon und wurde
                // vielleicht verschoben. Nur den Zustand umschalten.
                if RecordingControlBar.shared.isVisible {
                    RecordingControlBar.shared.setArmed(false)
                } else {
                    showControlBar(for: scope)
                }
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.state.elapsed = Int(self.screenRecorder.elapsed)
                    MainActor.assumeIsolated {
                        RecordingControlBar.shared.update(elapsed: self.screenRecorder.elapsed,
                                                          paused: self.screenRecorder.isPaused)
                    }
                    self.render()
                }
            } catch {
                Banner.show(title: L.t("Bildschirmaufnahme fehlgeschlagen", "Screen recording failed"),
                            subtitle: error.localizedDescription, url: nil, isError: true)
                RecordingControlBar.shared.hide()
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
            guard let (videoURL, seconds) = await screenRecorder.stop() else {
                screenRecordingActive = false
                phase = .idle
                return
            }
            screenRecordingActive = false

            if seconds < 2 {                       // Fehlklick-Schutz wie beim Mikro
                try? FileManager.default.removeItem(at: videoURL)
                phase = uploadsInFlight > 0 ? .uploading : .idle
                return
            }

            // Mit Systemton entstehen ZWEI Tonspuren (Mikro + System). Player
            // spielen meist nur die erste — vor allem die Drive-Vorschau. Also
            // vor dem Weiterreichen auf eine Spur mischen.
            if ConfigStore.shared.screenSystemAudio {
                if !AudioMixdown.mixToSingleTrack(at: videoURL) {
                    NSLog("RecBlitz: Tonspuren nicht gemischt (ffmpeg fehlt?), Video hat zwei Spuren")
                }
            }

            let audioURL = videoURL.deletingPathExtension().appendingPathExtension("m4a")
            do {
                try await AudioExtractor.extractAudio(from: videoURL, to: audioURL)
                pendingVideoURL = videoURL
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
        MainActor.assumeIsolated { RecordingControlBar.shared.hide() }
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
            RecordingControlBar.shared.hide()
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
            RecordingControlBar.shared.hide()
            WebcamBubble.shared.hide()
        }
        discarding = true
        if screenRecordingActive {
            Task { @MainActor in
                let result = await screenRecorder.stop()
                screenRecordingActive = false
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
                    // Erst löschen, wenn der Link WIRKLICH da ist und keine
                    // Fehlermeldung dranhängt, lieber Platz verbrauchen als
                    // eine Aufnahme verlieren.
                    if ConfigStore.shared.deleteLocalAfterUpload,
                       (result.video_error ?? "").isEmpty {
                        self.deleteLocalRecording(self.uploadingVideoPath)
                    }
                } else if let local = self.uploadingVideoPath,
                          FileManager.default.fileExists(atPath: local.path) {
                    // Ohne Drive bleibt das Video lokal. Die Zeile „Zuletzt"
                    // öffnet es dann direkt, statt ins Leere zu zeigen.
                    videoURL = local
                    self.uploadingVideoPath = nil
                }
                if let vErr = result.video_error, !vErr.isEmpty {
                    sub += "\n⚠️ \(vErr)"
                }
                self.state.last = LastResult(title: result.title ?? L.t("Sprachnotiz", "Voice note"),
                                             date: Date(), docURL: docURL, videoURL: videoURL,
                                             markdownPath: mdPath)
                self.state.last?.save()
                Banner.show(title: title, subtitle: sub, url: bannerURL)
            } else {
                Banner.show(title: L.t("Verarbeitung fehlgeschlagen", "Processing failed"),
                            subtitle: errorMessage ?? L.t("Unbekannter Fehler", "Unknown error"),
                            url: nil, isError: true, seconds: 20)
            }
        }
    }

    /// Löscht Video und die daneben liegende extrahierte Tonspur.
    private func deleteLocalRecording(_ video: URL?) {
        guard let video else { return }
        let audio = video.deletingPathExtension().appendingPathExtension("m4a")
        for url in [video, audio] where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                NSLog("RecBlitz: lokale Datei nach Upload gelöscht: %@", url.lastPathComponent)
            } catch {
                NSLog("RecBlitz: konnte %@ nicht löschen: %@", url.lastPathComponent,
                      error.localizedDescription)
            }
        }
        uploadingVideoPath = nil
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

/// Rendert eine SwiftUI-Ansicht über ein echtes, unsichtbares Fenster. Anders
/// als `ImageRenderer` zeichnet das auch AppKit-Steuerelemente (Schalter,
/// Segment-Picker, Textfelder) richtig, statt gelber Platzhalter.
@MainActor
func renderToPNG<V: View>(_ view: V, path: String, dark: Bool) -> Bool {
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = host.appearance
    // Grund ungefähr wie das Popover-Material im Dunkel- bzw. Hellmodus.
    let bg = NSView(frame: CGRect(origin: .zero, size: size))
    bg.wantsLayer = true
    bg.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.145, green: 0.153, blue: 0.180, alpha: 1)
                                      : NSColor(srgbRed: 0.945, green: 0.945, blue: 0.955, alpha: 1)).cgColor
    host.frame = bg.bounds
    bg.addSubview(host)
    window.contentView = bg
    bg.layoutSubtreeIfNeeded()
    bg.displayIfNeeded()
    guard let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds) else { return false }
    bg.cacheDisplay(in: bg.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}

if cliArgs.count >= 3, cliArgs[1] == "--render-panel" {
    let mode = cliArgs.count > 3 && !cliArgs[3].hasPrefix("--") ? cliArgs[3] : "idle"
    let dark = !cliArgs.contains("--light")
    // Doku-Bilder: feste Sprache und Voreinstellungen statt der echten Konfiguration.
    if let l = cliArgs.first(where: { $0.hasPrefix("--lang=") }) { L.override = String(l.dropFirst(7)) }
    if cliArgs.contains("--demo-config") { ConfigStore.useDefaultsOnly = true }
    if let m = cliArgs.first(where: { $0.hasPrefix("--mode=") }) {
        ConfigStore.shared.screenMode = String(m.dropFirst(7))
    }
    let ok: Bool = MainActor.assumeIsolated {
        if mode.hasPrefix("settings") {
            // Reiter vorwählen und danach zurückstellen, damit der Design-Check
            // nicht verändert, wo sich die Einstellungen das nächste Mal öffnen.
            let previous = UserDefaults.standard.object(forKey: "settingsTab")
            if let n = Int(mode.split(separator: "=").last ?? "") {
                UserDefaults.standard.set(n, forKey: "settingsTab")
            }
            defer { UserDefaults.standard.set(previous, forKey: "settingsTab") }
            return renderToPNG(SettingsPane(), path: cliArgs[2], dark: dark)
        }
        let dummy = AppState()
        // Beispieldaten für das Bild, nicht das echte letzte Ergebnis: ein
        // Design-Check darf keine privaten Titel zeigen.
        dummy.last = nil
        dummy.lastTranscript = nil
        if mode != "empty" {
            dummy.last = LastResult(title: L.t("Ablauf für das neue Onboarding und die zwei offenen Fragen - 2026-09-26 10.29 - RecBlitz",
                                                 "Onboarding flow walkthrough and the two open questions - 2026-09-26 10.29 - RecBlitz"),
                                    date: Date(), docURL: URL(string: "https://example.com/doc"),
                                    videoURL: mode == "idle" ? nil : URL(string: "https://example.com/video"),
                                    markdownPath: nil)
            dummy.lastTranscript = "…"
        }
        switch mode {
        case "recording": dummy.phase = .recording; dummy.elapsed = 42
        case "paused":    dummy.phase = .recording; dummy.elapsed = 42; dummy.paused = true
        case "armed":     dummy.phase = .armed
        case "uploading": dummy.phase = .uploading; dummy.uploading = true
                          dummy.uploadingVideo = true; dummy.uploadProgress = 64
        default: break
        }
        return renderToPNG(RecPanelView(state: dummy, onSize: { _ in }), path: cliArgs[2], dark: dark)
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
    if failures.isEmpty {
        print("selftest OK")
        exit(0)
    }
    for f in failures { print("FAIL: \(f)") }
    exit(1)
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
