import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import BlitzKit

/// Einstellungen als kompaktes Floating-Panel im MeetingBlitz-Stil:
/// utility NSPanel (nonactivating, aber sofort key für blaue Akzente),
/// NEBEN dem Panel platziert (PanelDock, wie MeetingBlitz), Live-Save ohne
/// Speichern-Button, gemerkte Position, sobald man es zieht.
@MainActor
final class SettingsPanelController {
    static let shared = SettingsPanelController()
    private var panel: NSPanel?
    /// Merkt sich, wohin das Panel gezogen wird. `window.delegate` ist weak,
    /// der Controller muss den Recorder halten.
    private var moveRecorder: PanelMoveRecorder?
    /// Anker vom Öffnen — fürs Nach-Platzieren im ersten resize.
    private var anchorRect: CGRect?

    func toggle(anchor: CGRect?) {
        if let p = panel, p.isVisible { close(); return }

        let hosting = SettingsHostingView(rootView: SettingsPane(onSize: { size in
            Task { @MainActor in SettingsPanelController.shared.resize(to: size) }
        }))
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        // fittingSize kann vor dem ersten Layout 0 liefern → Fallback,
        // der onSize-Resize zieht die echte Größe kurz danach nach.
        if size.width < 10 { size = CGSize(width: 328, height: 480) }

        NSLog("RecBlitz Settings: toggle, fittingSize=%@", "\(size)")
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = L.t("Einstellungen", "Settings")
        p.isReleasedWhenClosed = false
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        // Key von Anfang an: Controls rendern ihren blauen Akzent nur im Key-Fenster.
        p.becomesKeyOnlyIfNeeded = false
        p.contentView = hosting

        // Platzierung wie in MeetingBlitz (Rückmeldung 01.08.: "auch die selbe
        // Position"): NEBEN dem Panel und oben bündig, nicht mittig darunter.
        // Grund dort (Runde 47g): unter einem hohen Panel bleibt zu wenig Platz,
        // aufklappende Abschnitte rutschen unter den Bildschirmrand. Zusätzlich
        // merkt sich `PanelDock`, wohin das Fenster gezogen wird.
        anchorRect = anchor
        let wsize = p.frame.size
        p.setFrameOrigin(PanelDock.savedOrigin(panelSize: wsize, id: "recblitz-settings")
                         ?? PanelDock.origin(panelSize: wsize, anchor: anchor))
        p.makeKeyAndOrderFront(nil)
        // Kein Autofokus aufs Drive-Feld: sonst ist der Ordner-Text markiert und
        // wird beim ersten Tippen aus Versehen überschrieben.
        DispatchQueue.main.async { p.makeFirstResponder(nil) }

        // Position merken, sobald gezogen wird. Startet SUSPENDIERT: bis die
        // Erstplatzierung durch ist, ist jede Bewegung programmatisch.
        let recorder = PanelMoveRecorder(id: "recblitz-settings")
        recorder.suspended = true
        p.delegate = recorder
        moveRecorder = recorder
        panel = p

        // Endgültige Platzierung im NÄCHSTEN Runloop-Durchlauf: `fittingSize`
        // ist beim Erstellen oft noch ~0, die echte Größe kommt entweder über
        // AppKits Auto-Resize ODER über den onSize-Callback. Ein async-Hop
        // deckt beide Wege ab (MeetingBlitz Runde 47i).
        DispatchQueue.main.async { [weak self] in self?.finishInitialPlacement() }
        NSLog("RecBlitz Settings: geöffnet, visible=%d frame=%@",
              p.isVisible ? 1 : 0, "\(p.frame)")
    }

    /// Für den headless UI-Test (--ui-test-settings).
    func debugInfo() -> String {
        "visible=\(panel?.isVisible ?? false) frame=\(panel.map { "\($0.frame)" } ?? "nil")"
    }

    func resize(to contentSize: CGSize) {
        guard let p = panel, p.isVisible, contentSize.width > 1 else { return }
        let frameSize = p.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
        let old = p.frame
        // Erstplatzierung noch offen (Recorder suspendiert)? Dann mit der frischen
        // Größe direkt richtig platzieren, nicht warten.
        if moveRecorder?.suspended == true {
            let origin = PanelDock.savedOrigin(panelSize: frameSize, id: "recblitz-settings")
                ?? PanelDock.origin(panelSize: frameSize, anchor: anchorRect)
            p.setFrame(CGRect(origin: origin, size: frameSize), display: true)
            moveRecorder?.suspended = false
            return
        }
        if abs(frameSize.height - old.height) < 1, abs(frameSize.width - old.width) < 1 { return }
        // Oberkante bleibt stehen, Panel bleibt vollständig sichtbar.
        moveRecorder?.suspended = true
        var y = old.maxY - frameSize.height
        if let vf = PanelDock.visibleFrame(containing: old) {
            y = PanelDock.clampY(y, height: frameSize.height, vf: vf)
        }
        p.setFrame(CGRect(x: old.minX, y: y.rounded(), width: frameSize.width, height: frameSize.height),
                   display: true)
        moveRecorder?.suspended = false
    }

    /// Zweite Platzierungsstufe, siehe Kommentar in toggle().
    private func finishInitialPlacement() {
        guard let p = panel, p.isVisible, moveRecorder?.suspended == true else { return }
        let size = p.frame.size
        guard size.width > 10 else { return }        // noch Phantomgröße
        let origin = PanelDock.savedOrigin(panelSize: size, id: "recblitz-settings")
            ?? PanelDock.origin(panelSize: size, anchor: anchorRect)
        p.setFrameOrigin(origin)
        moveRecorder?.suspended = false
    }

    func close() {
        panel?.delegate = nil
        moveRecorder = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Fürs Dismiss-Monitoring des Widget-Panels: Klicks in die Settings
    /// dürfen das Widget nicht schließen.
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === panel }
}

private final class SettingsHostingView: NSHostingView<SettingsPane> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SettingsSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct SettingsPane: View {
    @ObservedObject var config = ConfigStore.shared
    @State private var micID: String = Recorder.selectedMicID ?? ""
    @State private var loginEnabled: Bool = SMAppService.mainApp.status == .enabled
    /// Gemerkt statt @State: beim erneuten Öffnen landet man dort, wo man
    /// zuletzt war, und für eine Sichtprüfung lässt sich der Reiter vorwählen.
    @AppStorage("settingsTab") private var tab = 0
    @State private var hoveredTab: Int?
    var onSize: (@Sendable (CGSize) -> Void)? = nil

    private var mics: [AVCaptureDevice] { Recorder.availableMics() }

    /// Belegter Platz im Aufnahme-Ordner, menschenlesbar.
    static func recordingsSize() -> String {
        let dir = Recorder.recordingsDir
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(Int64(0)) { sum, url in
            sum + (Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    /// Wo rclone liegt, falls installiert. Ohne rclone gibt es kein Google Doc,
    /// das soll der Reiter sagen, bevor man sich über fehlende Docs wundert.
    static var rclonePath: String? {
        ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabBar
            SectionLabel(text: title(for: tab))

            switch tab {
            case 1: transcriptTab
            case 2: screenTab
            case 3: driveTab
            default: generalTab
            }

            Divider()
            Text("RecBlitz \(Self.appVersion)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .frame(width: 300)
        .background(GeometryReader { g in
            Color.clear.preference(key: SettingsSizeKey.self, value: g.size)
        })
        .onPreferenceChange(SettingsSizeKey.self) { size in
            if size != .zero { onSize?(size) }
        }
        .onDisappear { config.save() }
    }

    // MARK: - Reiterleiste (wie MeetingBlitz)

    private static let tabs: [(id: Int, icon: String)] = [
        (0, "gearshape"), (1, "text.bubble"), (2, "rectangle.dashed.badge.record"), (3, "externaldrive"),
    ]

    private func title(for id: Int) -> String {
        switch id {
        case 1:  return L.t("Transkript & Notizen", "Transcript & notes")
        case 2:  return L.t("Bildschirmaufnahme", "Screen recording")
        case 3:  return "Google Drive"
        default: return L.t("Allgemein", "General")
        }
    }

    /// Eigene Reiterleiste statt `Picker(.segmented)`: größere Zeichen, echte
    /// Klickflächen, Hover-Rückmeldung, ein Tooltip je Seite. Dieselbe Bauform
    /// wie in MeetingBlitz.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Self.tabs, id: \.id) { t in
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { tab = t.id }
                } label: {
                    Image(systemName: t.icon)
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .foregroundStyle(tab == t.id ? Color.white
                                         : hoveredTab == t.id ? Color.primary : Color.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(tab == t.id ? Color.accentColor
                                      : hoveredTab == t.id ? Color.primary.opacity(0.10) : .clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .onHover { hoveredTab = $0 ? t.id : (hoveredTab == t.id ? nil : hoveredTab) }
                .help(title(for: t.id))
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
    }

    // MARK: - Allgemein

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L.t("Beim Login starten", "Launch at login"), isOn: $loginEnabled)
                .font(.system(size: 12))
                .onChange(of: loginEnabled) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        loginEnabled = SMAppService.mainApp.status == .enabled
                    }
                }

            HStack {
                Text(L.t("Sprache", "Language")).font(.system(size: 12))
                Spacer()
                Picker("", selection: $config.appLanguage) {
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }

            Divider()

            // Mikrofon als Radio-Liste: ein `.menu`-Picker hängt im
            // nonactivating Panel.
            Text(L.t("Mikrofon", "Microphone")).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 0) {
                micRow(id: "", name: L.t("Standard (System)", "Default (system)"))
                ForEach(mics, id: \.uniqueID) { d in
                    micRow(id: d.uniqueID, name: d.localizedName)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            Divider()

            HStack(spacing: 6) {
                Text(L.t("Lokale Aufnahmen", "Local recordings")).font(.system(size: 12))
                Spacer()
                // Größe mit dranschreiben: Videos wachsen schnell und man
                // merkt es sonst erst, wenn die Platte voll ist.
                Button(L.t("Öffnen", "Open") + " · \(SettingsPane.recordingsSize())") {
                    NSWorkspace.shared.open(Recorder.recordingsDir)
                }
                .font(.system(size: 12)).buttonStyle(.borderless)
            }
            HStack(spacing: 6) {
                Text(L.t("Panel-Position", "Panel position")).font(.system(size: 12))
                Spacer()
                Button(L.t("Zurücksetzen", "Reset")) { PanelDock.forgetPositions(ids: ["recblitz-settings"]) }
                    .font(.system(size: 12)).buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Transkript & Notizen

    private var transcriptTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L.t("Sprache", "Language")).font(.system(size: 12))
                Spacer()
                Picker("", selection: $config.language) {
                    Text("DE").tag("de-DE")
                    Text("EN").tag("en-US")
                    Text("ES").tag("es-ES")
                    Text("Auto").tag("auto")
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                .onChange(of: config.language) { _, _ in config.save() }
            }
            Text(L.t("Transkribiert wird auf dem Mac mit Apples Spracherkennung (macOS 26). „Auto“ braucht zusätzlich mlx-whisper.",
                     "Transcription runs on your Mac with Apple's speech recognition (macOS 26). “Auto” also needs mlx-whisper."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle(L.t("Zusammenfassung + Nächste Schritte", "Summary + next steps"), isOn: $config.summarize)
                .font(.system(size: 12))
                .onChange(of: config.summarize) { _, _ in config.save() }
            Text(L.t("Über die Claude-Befehlszeile, falls installiert. Ohne sie bleibt es beim Transkript.",
                     "Via the Claude command line, if installed. Without it you get the transcript only."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle(L.t("Notiz als Markdown speichern", "Save each note as Markdown"), isOn: $config.markdownEnabled)
                .font(.system(size: 12))
                .onChange(of: config.markdownEnabled) { _, _ in config.save() }
            HStack(spacing: 6) {
                TextField(ConfigStore.defaultNotesDir, text: $config.markdownDir)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { config.save() }
                Button(L.t("Wählen …", "Choose …")) { chooseNotesFolder() }
                    .font(.system(size: 11))
            }
            .disabled(!config.markdownEnabled)
            Text(L.t("Zum Beispiel ein Ordner in deinem Obsidian-Vault. Titel, Zusammenfassung und Transkript in einer Datei.",
                     "For example a folder in your Obsidian vault. Title, summary and transcript in one file."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Ordnerwahl. Der Dialog muss ÜBER dem Einstellungs-Panel liegen, das auf
    /// Menü-Ebene schwebt, sonst öffnet er sich unsichtbar dahinter.
    private func chooseNotesFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.prompt = L.t("Auswählen", "Choose")
        open.directoryURL = config.markdownDirURL
        open.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        if open.runModal() == .OK, let url = open.url {
            let home = NSHomeDirectory()
            config.markdownDir = url.path.hasPrefix(home)
                ? "~" + url.path.dropFirst(home.count) : url.path
            config.save()
        }
    }

    // MARK: - Bildschirmaufnahme

    private var screenTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L.t("Qualität", "Quality")).font(.system(size: 12))
                Spacer()
                Picker("", selection: $config.screenMaxDimension) {
                    Text("1080p").tag(1920)
                    Text("1440p").tag(2560)
                    Text(L.t("Original", "Native")).tag(0)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                .onChange(of: config.screenMaxDimension) { _, _ in config.save() }
            }
            HStack {
                Text(L.t("Vorlauf", "Countdown")).font(.system(size: 12))
                Spacer()
                Picker("", selection: $config.countdownSeconds) {
                    Text(L.t("Aus", "Off")).tag(0)
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                .onChange(of: config.countdownSeconds) { _, _ in config.save() }
            }
            Text(L.t("Zeit, um zum richtigen Fenster zu wechseln, bevor die Aufnahme läuft.",
                     "Time to switch to the right window before recording starts."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L.t("Systemton mitnehmen", "Include system audio"), isOn: $config.screenSystemAudio)
                .font(.system(size: 12))
                .onChange(of: config.screenSystemAudio) { _, _ in config.save() }
            Text(L.t("Dein Mikrofon läuft immer mit. Systemton nur nötig, wenn im gezeigten Bild Ton läuft.",
                     "Your mic is always recorded. System audio only matters if the screen plays sound."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle(L.t("Webcam-Blase einblenden", "Show webcam bubble"), isOn: $config.webcamEnabled)
                .font(.system(size: 12))
                .onChange(of: config.webcamEnabled) { _, _ in config.save() }
            HStack {
                Text(L.t("Größe", "Size")).font(.system(size: 12))
                Spacer()
                Picker("", selection: $config.webcamSize) {
                    Text(L.t("Klein", "Small")).tag(130)
                    Text(L.t("Mittel", "Medium")).tag(160)
                    Text(L.t("Groß", "Large")).tag(200)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                .onChange(of: config.webcamSize) { _, _ in config.save() }
            }
            .disabled(!config.webcamEnabled)
            Text(L.t("Landet mit im Video, lässt sich frei verschieben.",
                     "Recorded into the video, drag it anywhere."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Google Drive

    private var driveTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L.t("Google Doc + Video nach Drive", "Google Doc + video to Drive"), isOn: $config.driveEnabled)
                .font(.system(size: 12))
                .onChange(of: config.driveEnabled) { _, _ in config.save() }

            HStack(spacing: 5) {
                Image(systemName: Self.rclonePath != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Self.rclonePath != nil ? Color.green : Color.orange)
                Text(Self.rclonePath != nil
                     ? L.t("rclone gefunden", "rclone found")
                     : L.t("rclone fehlt: brew install rclone, dann rclone config", "rclone missing: brew install rclone, then rclone config"))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                labeledField(L.t("rclone-Remote", "rclone remote"), text: $config.driveRemote, placeholder: "gdrive:")
                labeledField(L.t("Ordner für Docs", "Folder for docs"), text: $config.driveFolderInput,
                             placeholder: L.t("Drive-Link oder Ordner-ID", "Drive link or folder ID"))
                labeledField(L.t("Ordner für Videos", "Folder for videos"), text: $config.videoFolderInput,
                             placeholder: L.t("leer = wie Docs", "empty = same as docs"))
                Text(L.t("Screencasts werden schnell hunderte MB groß, ein eigener Ordner hält die Docs übersichtlich.",
                         "Screencasts get large fast, a separate folder keeps the docs tidy."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(L.t("Video freigeben (Jeder mit dem Link)", "Share video (anyone with the link)"),
                       isOn: $config.videoPublic)
                    .font(.system(size: 12))
                    .onChange(of: config.videoPublic) { _, _ in config.save() }
                Toggle(L.t("Lokales Video nach Upload löschen", "Delete local video after upload"),
                       isOn: $config.deleteLocalAfterUpload)
                    .font(.system(size: 12))
                    .onChange(of: config.deleteLocalAfterUpload) { _, _ in config.save() }
                Text(L.t("Gelöscht wird erst, wenn der Drive-Link wirklich da ist.",
                         "Only deleted once the Drive link really exists."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!config.driveEnabled)
            .opacity(config.driveEnabled ? 1 : 0.55)
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit { config.save() }
        }
    }

    private func micRow(id: String, name: String) -> some View {
        let selected = micID == id
        return Button {
            micID = id
            Recorder.selectedMicID = id.isEmpty ? nil : id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(name).font(.system(size: 12)).lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
