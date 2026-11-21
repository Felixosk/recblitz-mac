import AppKit
import SwiftUI
import BlitzKit

/// Ein Monitor in der Auswahl (eigene Struktur, damit der Testmodus erfundene Monitore zeigen kann).
struct DisplayChoice: Identifiable {
    let id: Int
    let name: String
    let pixels: String
    let isMain: Bool
}

/// Inhalt des Menüleisten-Panels im MeetingBlitz-Design (Theme.swift): Kopf mit Titel und Status, Formularzeilen
/// ohne Karte, Hauptknopf, Upload, "Latest", Fuß. Alles ueber Theme-Bausteine, keine losen Zahlen.
struct RecPanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var config = ConfigStore.shared
    @State private var displays: [DisplayChoice] = []
    @ObservedObject private var layout = PanelLayout.shared
    @State private var micAnchor = AnchorBox()
    var onSize: (CGSize) -> Void

    static let width: CGFloat = Theme.widgetWidth

    /// Während Vorbereitung oder Aufnahme sind die Optionen gesperrt: ein
    /// Wechsel mitten in der Aufnahme hätte keine Wirkung mehr.
    private var locked: Bool { state.phase == .recording || state.phase == .armed }
    private var showsDisplayRow: Bool { config.screenMode == "screen" && displays.count > 1 }
    private var showsWebcamRow: Bool { config.screenMode != "off" || config.webcamEnabled }
    private var noSoundSource: Bool { !config.captureMicrophone && !config.screenSystemAudio }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            options.padding(.top, Theme.rowGap)
            actionRow.padding(.top, Theme.s8)
            ThemeFold(isOpen: state.uploading, gap: Theme.s8) { uploadRow }
            lastSection.padding(.top, Theme.s8)
            ThemeSectionDivider()
            footer
        }
        .padding(EdgeInsets(top: Theme.s16, leading: Theme.s16, bottom: Theme.s16, trailing: Theme.s16))
        .frame(width: Self.width)
        .background(ThemeGlass())
        .themeDragHeader()   // Ziehflaeche UNTER dem ✕ (Reihenfolge wichtig)
        .themeCloseCorner { PanelController.shared.close() }
        .padding(Theme.stageInset)   // durchsichtige Buehne rund ums Glas; gemeldet wird die Fenstergroesse
        .fixedSize(horizontal: false, vertical: true)   // natuerliche Hoehe messen, nicht die vom Fenster vorgeschlagene
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            if size.width > 1 { onSize(size) }
        }
        .frame(height: layout.height, alignment: .top)   // feste Fensterhoehe vom Controller, Inhalt oben verankert
        .ignoresSafeArea()
        .task {
            // Monitore beim Öffnen frisch holen, angesteckt und abgezogen wird zwischen zwei Aufnahmen.
            if Demo.on {
                displays = CommandLine.arguments.contains("--demo-displays") ? Demo.displays : []
                return
            }
            displays = await ScreenRecorder.availableDisplays().map {
                DisplayChoice(id: Int($0.id), name: $0.name, pixels: "\($0.pixelWidth) × \($0.pixelHeight) px", isMain: $0.isMain)
            }
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
        HStack(spacing: Theme.s8) {
            Text(headerTitle).font(.theme(.heading, .semibold)).lineLimit(1)
            Spacer(minLength: Theme.s4)
            status
        }
        .frame(height: Theme.iconButton)
    }

    /// Rechts oben steht, was gerade passiert. Die Aufnahmezeit steht NUR hier, nicht zusätzlich auf dem Knopf.
    @ViewBuilder private var status: some View {
        switch state.phase {
        case .recording:
            HStack(spacing: Theme.s4) {
                Circle().fill(state.paused ? Theme.warn : Theme.danger).frame(width: Theme.s8, height: Theme.s8)
                Text((state.paused ? L.t("Pausiert · ", "Paused · ") : "") + timeString(state.elapsed))
                    .font(.theme(.normal, .semibold).monospacedDigit())
                    .foregroundStyle(state.paused ? Theme.warn : Theme.danger)
            }
        case .armed:
            Text(L.t("Bereit", "Ready")).font(.theme(.normal, .semibold)).foregroundStyle(Theme.warn)
        case .transcribing:
            Text(L.t("Transkribiert …", "Transcribing …")).font(.theme(.normal, .semibold)).foregroundStyle(Theme.blue)
        default:
            Text("⌥⌘R")
                .font(.theme(.small, .semibold)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous).fill(Theme.fill))
                .help(L.t("Tastenkürzel: startet und stoppt ohne das Panel",
                          "Shortcut: starts and stops without opening the panel"))
        }
    }

    // MARK: - Optionen

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThemeChoiceRow(title: L.t("Sprache", "Language"),
                           options: [("DE", "de-DE"), ("EN", "en-US"), ("ES", "es-ES"), ("Auto", "auto")],
                           selection: Binding(get: { config.language },
                                              set: { config.language = $0; config.save() }))
            ThemeChoiceRow(title: L.t("Aufnahme", "Capture"),
                           options: [(L.t("Nur Ton", "Audio only"), "off"),
                                     (L.t("Bildschirm", "Screen"), "screen"),
                                     (L.t("Bereich", "Region"), "region")],
                           selection: Binding(get: { config.screenMode },
                                              set: { mode in
                                                  withAnimation(Theme.fold) { config.screenMode = mode }
                                                  config.save()
                                              }))
                .disabled(locked).opacity(locked ? 0.5 : 1)
                .padding(.top, Theme.rowGap)
            // Monitor-Auswahl NUR bei mehreren Bildschirmen und im Modus "Bildschirm". Bei "Bereich" bestimmt die
            // Zieh-Auswahl selbst, welcher Monitor gemeint ist. Bleibt im Baum (ThemeFold).
            ThemeFold(isOpen: showsDisplayRow) {
                ThemeChoiceRow(title: L.t("Monitor", "Display"),
                               options: displays.map { ($0.name, $0.id) },
                               selection: Binding(get: { selectedDisplay },
                                                  set: { config.screenDisplayID = $0; config.save() }))
                    .disabled(locked).opacity(locked ? 0.5 : 1)
            }
            // Ton: Mikro und Systemton in JEDEM Modus waehlbar (beide Default an), damit bei einem Call nie nur
            // eine Seite aufgenommen wird. Der ⌄-Knopf oeffnet das Geraete-Menue (Rechtsklick auf die Leiste auch).
            ThemeFormRow(title: L.t("Ton", "Sound")) {
                HStack(spacing: Theme.s8) {
                    ThemeMultiSegmented(options: [(L.t("Mikro", "Mic"), "mic"), (L.t("Systemton", "System"), "system")],
                                        selection: Binding(get: { soundSet },
                                                           set: { setSound($0) }),
                                        fill: false)
                        .overlay(RightClickCatcher { MicMenu.shared.show(below: micAnchor.view) })
                        .help(L.t("Mikro = deine Stimme. Systemton = was der Mac abspielt: die andere Seite im Call, Videos, Musik.",
                                  "Mic = your voice. System = what the Mac plays: the other side of a call, videos, music."))
                    ThemeIconButton(systemName: "chevron.down") { MicMenu.shared.show(below: micAnchor.view) }
                        .background(ViewAnchor(box: micAnchor))
                }
                .disabled(locked).opacity(locked ? 0.5 : 1)
            }
            .padding(.top, Theme.rowGap)
            // Webcam nur bei Bildschirm/Bereich. Bleibt sichtbar, solange die Blase an ist, sonst liesse sie sich
            // nach dem Wechsel auf "Nur Ton" hier nicht mehr abschalten.
            ThemeFold(isOpen: showsWebcamRow) {
                Toggle("Webcam", isOn: Binding(get: { config.webcamEnabled },
                                               set: { config.webcamEnabled = $0; config.save() }))
                    .toggleStyle(ThemeToggleStyle())
                    .disabled(locked).opacity(locked ? 0.5 : 1)
                    .help(L.t("Runde Kamerablase, landet mit im Video und lässt sich verschieben",
                              "Round camera bubble, recorded into the video and draggable"))
            }
            ThemeFold(isOpen: noSoundSource) {
                ErrorLine(text: L.t("Mikrofon oder Systemton einschalten", "Turn on microphone or system audio"))
            }
        }
    }

    private var soundSet: Set<String> {
        var s = Set<String>()
        if config.captureMicrophone { s.insert("mic") }
        if config.screenSystemAudio { s.insert("system") }
        return s
    }

    private func setSound(_ new: Set<String>) {
        withAnimation(Theme.fold) {
            config.captureMicrophone = new.contains("mic")
            config.screenSystemAudio = new.contains("system")
        }
        config.save()
    }

    private var selectedDisplay: Int {
        if config.screenDisplayID != 0 { return config.screenDisplayID }
        return displays.first(where: \.isMain)?.id ?? 0
    }

    // MARK: - Aktionen

    private var actionRow: some View {
        HStack(spacing: Theme.s8) {
            mainButton
            if state.phase == .recording, config.screenMode != "off" {
                ThemeIconButton(systemName: state.paused ? "play.fill" : "pause.fill", active: state.paused) {
                    state.onTogglePause?()
                }
            }
            // Verwerfen: nur während Vorbereitung oder Aufnahme, bewusst klein neben der Hauptaktion.
            if locked {
                ThemeIconButton(systemName: "trash") {
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
        return ThemePrimaryButton(title: title, tint: (recording || armed) ? Theme.danger : nil, icon: icon) {
            guard !transcribing else { return }
            state.onToggleRecording?()
            PanelController.shared.close()
        }
        .opacity(transcribing ? 0.55 : 1)
    }

    /// Upload-Zeile. Ein Screencast lädt deutlich länger hoch als ein Textdokument, man soll sehen, worauf man wartet.
    private var uploadRow: some View {
        VStack(alignment: .leading, spacing: Theme.s8) {
            HStack(spacing: Theme.s8) {
                if state.uploadProgress == nil { ProgressView().controlSize(.mini) }
                Text(state.uploadingVideo ? L.t("Video wird hochgeladen", "Uploading video")
                     : config.driveEnabled ? L.t("Google Doc wird erstellt", "Creating Google Doc")
                     : L.t("Notiz wird gespeichert", "Saving note"))
                    .font(.theme(.small)).foregroundStyle(Theme.muted)
                Spacer(minLength: Theme.s8)
                if let pct = state.uploadProgress {
                    Text("\(pct) %").font(.theme(.small, .semibold).monospacedDigit()).foregroundStyle(Theme.label)
                }
            }
            if let pct = state.uploadProgress {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fill)
                        Capsule().fill(Theme.blue).frame(width: max(Theme.s4, g.size.width * CGFloat(pct) / 100))
                    }
                }
                .frame(height: Theme.s4)
            }
        }
    }

    // MARK: - Zuletzt

    private var lastSection: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            HStack {
                ThemeSectionTitle(L.t("Zuletzt", "Latest"))
                Spacer()
                folderButton
            }
            if let last = state.last {
                LastRow(result: last, transcript: state.lastTranscript).themeRowList()
            } else {
                Text(L.t("Noch keine Aufnahme. ⌥⌘R startet sofort.", "No recording yet. ⌥⌘R starts right away."))
                    .font(.theme(.small)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Öffnet den Ort, an dem die Ergebnisse landen: Drive, wenn eingerichtet, sonst den Markdown-Ordner.
    private var folderButton: some View {
        let drive = config.driveFolderURL
        return ThemeIconButton(systemName: drive != nil ? "externaldrive" : "folder",
                               label: drive != nil ? L.t("Öffnet den Drive-Ordner mit allen Docs", "Opens the Drive folder with all docs")
                                                   : L.t("Öffnet den Ordner mit allen Notizen", "Opens the folder with all notes")) {
            if let drive {
                NSWorkspace.shared.open(drive)
            } else {
                let dir = config.markdownDirURL
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            }
        }
    }

    // MARK: - Fuß

    private var footer: some View {
        HStack(spacing: Theme.s8) {
            Text("RecBlitz").font(.theme(.small)).foregroundStyle(Theme.muted)
            Spacer()
            ThemeIconButton(systemName: "gearshape") {
                // Panel bleibt offen, die Einstellungen docken daneben an.
                SettingsPanelController.shared.toggle(anchor: PanelController.shared.glassFrame)
            }
            ThemeIconButton(systemName: "power") { NSApp.terminate(nil) }
        }
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Symbol-Knopf, der nach dem Klick kurz ein Häkchen zeigt (Kopieren).
struct ConfirmIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    @State private var done = false

    var body: some View {
        ThemeIconButton(systemName: done ? "checkmark" : systemName, label: label, tint: done ? Theme.ok : nil) {
            action()
            withAnimation(.easeInOut(duration: 0.14)) { done = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.2)) { done = false }
            }
        }
    }
}

/// Die letzte Aufnahme als Zeile: Titel (hoechstens 2 Zeilen), darunter Uhrzeit, rechts runde Symbol-Knoepfe.
/// Klick auf die Zeile öffnet das beste vorhandene Ergebnis (Video, Doc, Notiz). Keine Dauer-Toenung,
/// nur Hover-Flaeche.
struct LastRow: View {
    let result: LastResult
    let transcript: String?
    @State private var hovering = false

    private var timeLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.isDE ? "de_DE" : "en_US")
        f.dateFormat = Calendar.current.isDateInToday(result.date) ? "HH:mm" : (L.isDE ? "dd.MM." : "MMM d")
        return f.string(from: result.date) + (result.videoURL != nil ? " · Video" : "")
    }

    static func displayTitle(_ raw: String) -> String {
        raw.replacingOccurrences(of: #" - \d{4}-\d{2}-\d{2} \d{2}\.\d{2} - RecBlitz$"#,
                                 with: "", options: .regularExpression)
    }

    private var markdownURL: URL? { result.markdownPath.map { URL(fileURLWithPath: $0) } }

    private var primaryURL: URL? { result.videoURL ?? result.docURL ?? markdownURL }

    var body: some View {
        HStack(spacing: Theme.s8) {
            // Ohne den Anhang " - 2026-09-26 10.29 - RecBlitz": die Uhrzeit steht darunter. Hoechstens 2 Zeilen,
            // der volle Titel steht im Tooltip.
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.displayTitle(result.title))
                    .font(.theme(.normal)).foregroundStyle(Theme.label)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(Self.displayTitle(result.title))
                Text(timeLabel).font(.theme(.small).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: Theme.s8)
            HStack(spacing: Theme.s8) {
                if let video = result.videoURL {
                    ConfirmIconButton(systemName: "link",
                                      label: video.isFileURL ? L.t("Kopiert das Video als Datei", "Copies the video as a file")
                                                             : L.t("Kopiert den Video-Link", "Copies the video link")) {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        if video.isFileURL { pb.writeObjects([video as NSURL]) }
                        else { pb.setString(video.absoluteString, forType: .string) }
                    }
                }
                if let local = result.localVideoPath {
                    ThemeIconButton(systemName: "film", label: L.t("Video: zeigt das Originalvideo im Finder",
                                                                   "Video: shows the original video in Finder")) {
                        if FileManager.default.fileExists(atPath: local) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: local)])
                        } else {
                            NSWorkspace.shared.open(Recorder.moviesDir)   // verschoben: Ordner zeigen
                        }
                    }
                }
                if let transcript, !transcript.isEmpty {
                    ConfirmIconButton(systemName: "doc.on.doc",
                                      label: L.t("Kopiert das ganze Transkript", "Copies the full transcript")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                    }
                }
                if let doc = result.docURL {
                    ThemeIconButton(systemName: "doc.text", label: L.t("Öffnet das Google Doc", "Opens the Google Doc")) {
                        NSWorkspace.shared.open(doc)
                    }
                } else if let md = markdownURL {
                    ThemeIconButton(systemName: "doc.text", label: L.t("Öffnet die Notiz", "Opens the note")) {
                        NSWorkspace.shared.open(md)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.s8).padding(.vertical, Theme.s4)
        .frame(minHeight: Theme.rowHeight)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(hovering ? Theme.fill : .clear))
        .contentShape(Rectangle())
        .onTapGesture { if let url = primaryURL, !Demo.on { NSWorkspace.shared.open(url) } }
        .onHover { hovering = $0 }
    }
}
