import AppKit
import SwiftUI
import BlitzKit

/// Inhalt des Menüleisten-Panels. Aufbau wie das MeetingBlitz-Widget:
/// Kopfzeile mit Status rechts, eine Kartenfläche, die große Aktionspille,
/// die letzte Aufnahme als Listenzeile mit Symbolknöpfen, Fußzeile.
struct RecPanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var config = ConfigStore.shared
    @State private var mainHovered = false
    @State private var displays: [CaptureDisplay] = []
    var onSize: (CGSize) -> Void

    static let width: CGFloat = 360

    /// Während Vorbereitung oder Aufnahme sind die Optionen gesperrt: ein
    /// Wechsel mitten in der Aufnahme hätte keine Wirkung mehr.
    private var locked: Bool { state.phase == .recording || state.phase == .armed }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            options
            actionRow
            if state.uploading { uploadRow }
            lastSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: Self.width)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { onSize(g.size) }
                .onChange(of: g.size) { _, new in onSize(new) }
        })
        .task {
            // Monitore beim Öffnen frisch holen, angesteckt und abgezogen wird
            // zwischen zwei Aufnahmen.
            displays = await ScreenRecorder.availableDisplays()
        }
    }

    // MARK: - Kopf

    private var headerTitle: String {
        switch config.screenMode {
        case "screen": return L.t("Bildschirmaufnahme", "Screen recording")
        case "region": return L.t("Bereichsaufnahme", "Region recording")
        default:       return L.t("Sprachnotiz", "Voice note")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(headerTitle)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Spacer()
            status
        }
    }

    /// Rechts oben steht, was gerade passiert, in Akzentfarbe, wie der
    /// Countdown „in 5 min" im MeetingBlitz-Widget. Die Aufnahmezeit steht NUR
    /// hier, nicht zusätzlich auf dem Knopf (Rückmeldung 31.07.: „brauche nicht
    /// zweimal sehen, wie lange das Ding geht").
    @ViewBuilder private var status: some View {
        switch state.phase {
        case .recording:
            HStack(spacing: 5) {
                Circle().fill(state.paused ? Color.orange : Color.red).frame(width: 7, height: 7)
                Text((state.paused ? L.t("Pausiert · ", "Paused · ") : "") + timeString(state.elapsed))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(state.paused ? Color.orange : Color.red)
            }
        case .armed:
            Text(L.t("Bereit", "Ready"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange)
        case .transcribing:
            Text(L.t("Transkribiert …", "Transcribing …"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
        default:
            Text("⌥⌘R")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                .help(L.t("Tastenkürzel: startet und stoppt ohne das Panel",
                          "Shortcut: starts and stops without opening the panel"))
        }
    }

    // MARK: - Optionen

    private var languageItems: [PillSegment<String>.Item] {
        [.init(id: "de-DE", label: "DE", help: L.t("Deutsch", "German")),
         .init(id: "en-US", label: "EN", help: L.t("Englisch", "English")),
         .init(id: "es-ES", label: "ES", help: L.t("Spanisch", "Spanish")),
         .init(id: "auto", label: "Auto", help: L.t("Sprache automatisch erkennen", "Detect the language automatically"))]
    }

    /// Mikrofon und Systemton sind in JEDEM Modus wählbar (beide Default an), damit
    /// bei einem Call nie nur eine Seite aufgenommen wird (05.10.).
    private var modeItems: [PillSegment<String>.Item] {
        [.init(id: "off", label: L.t("Nur Ton", "Audio only"),
               help: L.t("Nur Ton, kein Video: die schnelle Sprachnotiz, auch für Calls",
                         "Sound only, no video: the quick voice note, also for calls")),
         .init(id: "screen", label: L.t("Bildschirm", "Screen"),
               help: L.t("Ganzer Bildschirm mit Ton", "Whole screen with sound")),
         .init(id: "region", label: L.t("Bereich", "Region"),
               help: L.t("Einen Ausschnitt aufziehen, mit Ton", "Drag out a region, with sound"))]
    }

    private var options: some View {
        Card {
            optionRow(L.t("Sprache", "Language")) {
                PillSegment(items: languageItems, selection: config.language) { code in
                    config.language = code
                    config.save()
                }
            }
            optionRow(L.t("Aufnahme", "Capture")) {
                PillSegment(items: modeItems, selection: config.screenMode, disabled: locked) { mode in
                    config.screenMode = mode
                    config.save()
                }
            }
            // Monitor-Auswahl NUR bei mehreren Bildschirmen, sonst ist sie
            // sinnlose Fläche. Bei „Bereich" bestimmt die Zieh-Auswahl selbst,
            // welcher Monitor gemeint ist.
            if config.screenMode == "screen", displays.count > 1 {
                optionRow(L.t("Monitor", "Display")) {
                    PillSegment(items: displays.map { d in
                                    PillSegment<Int>.Item(id: Int(d.id), label: d.name,
                                                          help: "\(d.pixelWidth) × \(d.pixelHeight) px") },
                                selection: selectedDisplay, disabled: locked) { id in
                        config.screenDisplayID = id
                        config.save()
                    }
                }
            }
            // Systemton und Webcam betreffen nur den Bildschirm. Die Webcam-
            // Zeile bleibt aber sichtbar, solange die Blase an ist, sonst ließe
            // sie sich nach dem Wechsel auf „Nur Ton" hier nicht mehr abschalten.
            optionRow("") {
                HStack(spacing: 6) {
                    // Ein Knopf: Klick (und Rechtsklick) oeffnet das Geraete-Menue,
                    // dort steht auch "Mikrofon aufnehmen" zum Ein-/Ausschalten.
                    ChipToggle(icon: "mic.fill", offIcon: "mic.slash",
                               label: L.t("Mikro", "Mic"),
                               isOn: config.captureMicrophone, disabled: locked, chevron: true,
                               help: L.t("Mikrofon wählen oder ein-/ausschalten", "Choose or toggle the microphone")) {
                        MicMenu.shared.show()
                    }
                    .overlay(RightClickCatcher { MicMenu.shared.show() })
                    ChipToggle(icon: "speaker.wave.2.fill", offIcon: "speaker.slash",
                               label: L.t("Systemton", "System"),
                               isOn: config.screenSystemAudio, disabled: locked,
                               help: L.t("Was der Mac abspielt: die andere Seite im Call, Videos, Musik",
                                         "What the Mac plays: the other side of a call, videos, music")) {
                        config.screenSystemAudio.toggle()
                        config.save()
                    }
                    // Webcam nur bei Bildschirm/Bereich. Bleibt sichtbar, solange die
                    // Blase an ist, sonst ließe sie sich nach dem Wechsel auf „Nur Ton"
                    // hier nicht mehr abschalten.
                    if config.screenMode != "off" || config.webcamEnabled {
                        ChipToggle(icon: "person.crop.circle.fill", offIcon: "person.crop.circle",
                                   label: "Webcam", isOn: config.webcamEnabled, disabled: locked,
                                   help: L.t("Runde Kamerablase, landet mit im Video und lässt sich verschieben",
                                             "Round camera bubble, recorded into the video and draggable")) {
                            config.webcamEnabled.toggle()
                            config.save()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if !config.captureMicrophone && !config.screenSystemAudio {
                optionRow("") {
                    Text(L.t("Mikrofon oder Systemton einschalten", "Turn on microphone or system audio"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.red)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var selectedDisplay: Int {
        if config.screenDisplayID != 0 { return config.screenDisplayID }
        return Int(displays.first(where: \.isMain)?.id ?? 0)
    }

    private func optionRow<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            content()
        }
    }

    // MARK: - Aktionen

    private var actionRow: some View {
        HStack(spacing: 8) {
            mainButton
            if state.phase == .recording, config.screenMode != "off" {
                SquarePill(icon: state.paused ? "play.fill" : "pause.fill", active: state.paused,
                           help: state.paused ? L.t("Weiter aufnehmen", "Resume") : L.t("Pause", "Pause")) {
                    state.onTogglePause?()
                }
            }
            // Verwerfen: nur während Vorbereitung oder Aufnahme, bewusst klein
            // neben der Hauptaktion. Seltener, aber nicht versteckt.
            if locked {
                SquarePill(icon: "trash", help: L.t("Aufnahme verwerfen", "Discard recording")) {
                    state.onDiscardRecording?()
                    PanelController.shared.close()
                }
            }
        }
    }

    private var mainButton: some View {
        let armed = state.phase == .armed
        let recording = state.phase == .recording
        let transcribing = state.phase == .transcribing
        let title = armed ? L.t("Aufnahme beginnen", "Start capture")
                  : recording ? L.t("Aufnahme stoppen", "Stop recording")
                  : transcribing ? L.t("Transkribiere …", "Transcribing …")
                  : L.t("Aufnahme starten", "Start recording")
        let icon = armed ? "record.circle.fill"
                 : recording ? "stop.fill"
                 : (config.screenMode == "off" ? "mic.fill" : "record.circle")
        return Button {
            guard !transcribing else { return }
            state.onToggleRecording?()
            PanelController.shared.close()
        } label: {
            ActionPill(title: title, icon: icon,
                       tint: (recording || armed) ? .red : Theme.accent,
                       hovered: mainHovered, dimmed: transcribing)
        }
        .buttonStyle(.plain)
        .onHover { mainHovered = $0 }
    }

    /// Upload-Zeile. Ein Screencast lädt deutlich länger hoch als ein
    /// Textdokument, man soll sehen, worauf man wartet (Rückmeldung 31.07.).
    private var uploadRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if state.uploadProgress == nil { ProgressView().controlSize(.mini) }
                Text(state.uploadingVideo ? L.t("Video wird hochgeladen", "Uploading video")
                     : config.driveEnabled ? L.t("Google Doc wird erstellt", "Creating Google Doc")
                     : L.t("Notiz wird gespeichert", "Saving note"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let pct = state.uploadProgress {
                    Text("\(pct) %")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.primary)
                }
            }
            if let pct = state.uploadProgress {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Theme.accent)
                            .frame(width: max(4, g.size.width * CGFloat(pct) / 100))
                    }
                }
                .frame(height: 4)
            }
        }
    }

    // MARK: - Zuletzt

    private var lastSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel(text: L.t("Zuletzt", "Latest"))
                Spacer()
                folderButton
            }
            if let last = state.last {
                LastRow(result: last, transcript: state.lastTranscript)
            } else {
                Text(L.t("Noch keine Aufnahme. ⌥⌘R startet sofort.",
                         "No recording yet. ⌥⌘R starts right away."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 5)
            }
        }
    }

    /// Öffnet den Ort, an dem die Ergebnisse landen: Drive, wenn eingerichtet,
    /// sonst den Markdown-Ordner.
    private var folderButton: some View {
        let drive = config.driveFolderURL
        return Button {
            if let drive {
                NSWorkspace.shared.open(drive)
            } else {
                let dir = config.markdownDirURL
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            }
        } label: {
            Label(drive != nil ? "Drive" : L.t("Ordner", "Folder"),
                  systemImage: drive != nil ? "externaldrive" : "folder")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.10)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(drive != nil ? L.t("Öffnet den Drive-Ordner mit allen Docs", "Opens the Drive folder with all docs")
                           : L.t("Öffnet den Ordner mit allen Notizen", "Opens the folder with all notes"))
    }

    // MARK: - Fuß

    private var footer: some View {
        HStack {
            FooterButton(icon: "gearshape", label: L.t("Einstellungen", "Settings")) {
                // Panel bleibt offen, die Einstellungen docken daneben an.
                SettingsPanelController.shared.toggle(anchor: PanelController.shared.frame)
            }
            Spacer()
            FooterButton(label: L.t("Beenden", "Quit")) { NSApp.terminate(nil) }
        }
        .padding(.horizontal, -6)
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Die letzte Aufnahme als Zeile, gebaut wie eine MeetingBlitz-Terminzeile:
/// Symbol, Uhrzeit, Titel, rechts die Aktionen. Klick auf die Zeile öffnet das
/// beste vorhandene Ergebnis (Video, Doc, Notiz).
struct LastRow: View {
    let result: LastResult
    let transcript: String?
    @State private var hovering = false

    private var timeLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.isDE ? "de_DE" : "en_US")
        f.dateFormat = Calendar.current.isDateInToday(result.date) ? "HH:mm" : (L.isDE ? "dd.MM." : "MMM d")
        return f.string(from: result.date)
    }

    static func displayTitle(_ raw: String) -> String {
        raw.replacingOccurrences(of: #" - \d{4}-\d{2}-\d{2} \d{2}\.\d{2} - RecBlitz$"#,
                                 with: "", options: .regularExpression)
    }

    private var markdownURL: URL? { result.markdownPath.map { URL(fileURLWithPath: $0) } }

    private var primaryURL: URL? { result.videoURL ?? result.docURL ?? markdownURL }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: result.videoURL != nil ? "play.rectangle.fill" : "waveform")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 14)
            Text(timeLabel)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            // Ohne den Anhang „ - 2026-09-26 10.29 - RecBlitz": die Uhrzeit steht
            // schon links, und der Anhang frisst genau den Platz, der dem Titel
            // fehlt. Zwei Zeilen statt „…" (Rückmeldung 26.09.).
            Text(Self.displayTitle(result.title))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let video = result.videoURL {
                RowIconButton(icon: "link", help: video.isFileURL
                              ? L.t("Kopiert das Video als Datei", "Copies the video as a file")
                              : L.t("Kopiert den Video-Link", "Copies the video link"),
                              confirms: true) {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    if video.isFileURL { pb.writeObjects([video as NSURL]) }
                    else { pb.setString(video.absoluteString, forType: .string) }
                }
            }
            if let local = result.localVideoPath {
                RowIconButton(icon: "film", help: L.t("Video: zeigt das Originalvideo im Finder",
                                                      "Video: shows the original video in Finder")) {
                    if FileManager.default.fileExists(atPath: local) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: local)])
                    } else {
                        NSWorkspace.shared.open(Recorder.moviesDir)   // verschoben: Ordner zeigen
                    }
                }
            }
            if let transcript, !transcript.isEmpty {
                RowIconButton(icon: "doc.on.doc", help: L.t("Kopiert das ganze Transkript",
                                                           "Copies the full transcript"),
                              confirms: true) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript, forType: .string)
                }
            }
            if let doc = result.docURL {
                RowIconButton(icon: "doc.text", help: L.t("Öffnet das Google Doc", "Opens the Google Doc")) {
                    NSWorkspace.shared.open(doc)
                }
            } else if let md = markdownURL {
                RowIconButton(icon: "doc.text", help: L.t("Öffnet die Notiz", "Opens the note")) {
                    NSWorkspace.shared.open(md)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(hovering ? Color.primary.opacity(0.08) : Theme.accent.opacity(0.10)))
        .contentShape(Rectangle())
        .onTapGesture { if let url = primaryURL { NSWorkspace.shared.open(url) } }
        .onHover { hovering = $0 }
        .help(L.t("Klick öffnet die Aufnahme", "Click opens the recording"))
    }
}
