import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import BlitzKit

/// Merkt sich, wohin das Einstellungs-Fenster gezogen wird (und ob der Nutzer es bewegt hat).
/// `window.delegate` ist weak, der Controller haelt den Recorder.
@MainActor
final class SettingsMoveRecorder: NSObject, NSWindowDelegate {
    private let id: String
    /// Waehrend wir das Fenster SELBST verschieben darf nichts gespeichert werden.
    var suspended = false
    var onUserMove: (() -> Void)?
    init(id: String) { self.id = id }
    func windowDidMove(_ notification: Notification) {
        guard !suspended, let w = notification.object as? NSWindow else { return }
        if !Demo.on { PanelDock.storeTopLeft(NSPoint(x: w.frame.minX, y: w.frame.maxY), id: id) }
        onUserMove?()
    }
}

/// Einstellungs-Fenster im MeetingBlitz-Design: `ThemePanel` (titled, Ampel aus), Glas + ✕ + durchsichtige
/// Buehne, Ebene `.floating`, dockt Glas an Glas neben dem Panel an (links, sonst rechts), gezogen = gemerkt.
@MainActor
final class SettingsPanelController {
    static let shared = SettingsPanelController()
    private var panel: NSPanel?
    private var moveRecorder: SettingsMoveRecorder?
    /// Glas-Rahmen des Menueleisten-Panels, an dem dieses Fenster andockt.
    private var anchorGlass: CGRect?
    private var userMoved = false
    private var pendingShrink: DispatchWorkItem?
    /// Oberkante, an der das Fenster "wohnt": beim Reiterwechsel wird immer von DIESER Kante aus geklemmt.
    private var restTop: CGFloat?
    private let dockID = "recblitz-settings-v2"

    var frame: CGRect? { panel?.frame }
    var glassFrame: CGRect? { panel?.frame.insetBy(dx: Theme.stageInset, dy: Theme.stageInset) }
    var isOpen: Bool { panel?.isVisible ?? false }

    /// `anchor` = Glas-Rahmen des Menueleisten-Panels.
    func toggle(anchor: CGRect?, screen: NSScreen? = nil) {
        if let p = panel, p.isVisible { close(); return }

        let hosting = SettingsHostingView(rootView: SettingsPane(
            onClose: { Task { @MainActor in SettingsPanelController.shared.close() } },
            onSize: { size in
                // Am GLAS vor dem Buehnen-Padding gemessen, ein Runloop-Hop (keine Layout-Rekursion).
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { SettingsPanelController.shared.resize(to: size) }
                }
            }))
        hosting.sizingOptions = []   // Groesse setzt allein der Controller
        hosting.safeAreaRegions = []
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 10 { size = CGSize(width: Theme.widgetWidth + 2 * Theme.stageInset, height: 480) }

        // `.titled` bleibt (Falle 13: randlose Glas-Panels koennen die App unklickbar machen), Ampel/Titel aus.
        let p = ThemePanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                           backing: .buffered, defer: false)
        p.title = L.t("Einstellungen", "Settings")
        p.contentFillsFrame = true
        p.controllerOwnsSize = true
        p.setContentSize(size)
        p.titlebarAppearsTransparent = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.onEscape = { [weak p] in p?.close() }
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false   // sofort key: Fokus im Textfeld, blaue Akzente von Anfang an
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = hosting
        Theme.installStage(in: p, movableByBackground: false)
        p.level = .floating   // NACH allem anderen (Falle 11)

        anchorGlass = anchor
        let panelSize = p.frame.size
        p.setFrameOrigin(origin(for: panelSize))
        p.makeKeyAndOrderFront(nil)
        // Kein Autofokus aufs Textfeld: sonst ist der Ordner-Text markiert und wird beim ersten Tippen ueberschrieben.
        for delay in [0.0, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak p] in
                guard let p, p.isVisible, p.firstResponder is NSText else { return }
                p.makeFirstResponder(nil)
            }
        }

        let recorder = SettingsMoveRecorder(id: dockID)
        userMoved = false
        recorder.onUserMove = { [weak self] in
            self?.userMoved = true
            self?.restTop = self?.panel?.frame.maxY
            self?.updateScreenHeight()
        }
        recorder.suspended = true   // bis die Erstplatzierung durch ist, ist jede Bewegung programmatisch
        p.delegate = recorder
        moveRecorder = recorder
        panel = p
        DispatchQueue.main.async { [weak self] in self?.finishInitialPlacement() }
    }

    // MARK: Platzierung

    /// Ursprung (Fenster samt Buehne) fuer ein Fenster dieser Groesse: gemerkte Position, sonst Glas an Glas neben dem Panel.
    private func origin(for size: CGSize) -> NSPoint {
        if !Demo.on, let saved = PanelDock.savedOrigin(panelSize: size, id: dockID) { return saved }
        guard let a = anchorGlass else {
            let m = NSEvent.mouseLocation
            return NSPoint(x: (m.x - size.width / 2).rounded(), y: (m.y - size.height - 24).rounded())
        }
        let stage = Theme.stageInset
        let vf = PanelDock.visibleFrame(containing: a) ?? a
        let glassW = size.width - 2 * stage
        let gap = Theme.s8
        var gx = a.minX - gap - glassW                       // links neben dem Panel
        if gx < vf.minX + 8 {
            let right = a.maxX + gap                          // sonst rechts daneben
            gx = (right + glassW <= vf.maxX - 8) ? right : a.midX - glassW / 2
        }
        gx = min(max(gx, vf.minX + 8), vf.maxX - glassW - 8)
        // Oberkante des Glases = Oberkante des Panel-Glases, nur unten in den Bildschirm klemmen.
        let glassH = size.height - 2 * stage
        let gy = max(a.maxY - glassH, vf.minY + 8)
        return NSPoint(x: (gx - stage).rounded(), y: (gy - stage).rounded())
    }

    private func finishInitialPlacement() {
        guard let p = panel, p.isVisible, moveRecorder?.suspended == true else { return }
        let size = p.frame.size
        guard size.width > 50 else { return }   // noch Phantomgroesse: resize() uebernimmt
        updateScreenHeight()
        p.setFrameOrigin(origin(for: size))
        moveRecorder?.suspended = false
    }

    /// Das Menueleisten-Panel hat sich bewegt oder seine Hoehe geaendert: dockt neu an (Oberkante gleich, Abstand 8).
    /// Vom Nutzer gezogene Position gewinnt.
    func alignToPanel(_ glass: CGRect) {
        anchorGlass = glass
        guard let p = panel, p.isVisible, !userMoved else { return }
        restTop = nil
        moveRecorder?.suspended = true
        p.setFrameOrigin(origin(for: p.frame.size))
        moveRecorder?.suspended = false
    }

    /// Glas-Groesse hat sich geaendert (Reiterwechsel, Inhalt): Fenster ist um die Buehne groesser. Wachsen sofort,
    /// Schrumpfen erst nach der Klapp-Feder, Oberkante bleibt.
    func resize(to glassSize: CGSize) {
        guard glassSize.width > 1, glassSize.height > 100 else { return }
        let stage = 2 * Theme.stageInset
        let frameSize = CGSize(width: glassSize.width + stage, height: glassSize.height + stage)
        guard let p = panel as? ThemePanel, p.isVisible else { return }
        updateScreenHeight()
        let old = p.frame
        if moveRecorder?.suspended == true {   // Erstplatzierung noch offen
            restTop = nil
            p.pinnedHeight = frameSize.height
            SettingsLayout.shared.set(frameSize.height)
            p.setFrameFromController(CGRect(origin: origin(for: frameSize), size: frameSize), display: true)
            moveRecorder?.suspended = false
            return
        }
        if abs(frameSize.height - old.height) < 1, abs(frameSize.width - old.width) < 1 {
            pendingShrink?.cancel(); pendingShrink = nil
            p.pinnedHeight = frameSize.height
            return
        }
        if frameSize.height < old.height - 0.5, abs(frameSize.width - old.width) < 1 {
            pendingShrink?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.applyFrame(frameSize) }
            pendingShrink = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.foldSettle, execute: w)
            return
        }
        pendingShrink?.cancel(); pendingShrink = nil
        applyFrame(frameSize)
    }

    /// Deckel fuer den Reiter-Inhalt kommt vom Bildschirm unter dem Fenster (nicht NSScreen.main).
    private func updateScreenHeight() {
        guard let p = panel else { return }
        let vf = PanelDock.visibleFrame(containing: p.frame) ?? (p.screen ?? NSScreen.main)?.visibleFrame
        SettingsLayout.shared.setScreen(vf?.height)
    }

    private func applyFrame(_ frameSize: CGSize) {
        guard let p = panel as? ThemePanel, p.isVisible else { return }
        updateScreenHeight()
        let old = p.frame
        p.pinnedHeight = frameSize.height
        SettingsLayout.shared.set(frameSize.height)
        moveRecorder?.suspended = true
        if restTop == nil { restTop = old.maxY }
        var y = restTop! - frameSize.height
        if let vf = PanelDock.visibleFrame(containing: old) {
            // Glas-Unterkante bleibt im Bildschirm (Bühne darf unten hinausragen).
            y = max(y, vf.minY + 8 - Theme.stageInset)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0; ctx.allowsImplicitAnimation = false
            CATransaction.begin(); CATransaction.setDisableActions(true)
            p.setFrameFromController(CGRect(x: old.minX, y: y.rounded(), width: frameSize.width, height: frameSize.height), display: true)
            p.contentView?.layoutSubtreeIfNeeded()
            CATransaction.commit(); CATransaction.flush()
        }
        moveRecorder?.suspended = false
    }

    func close() {
        pendingShrink?.cancel(); pendingShrink = nil
        SettingsLayout.shared.set(nil)
        panel?.delegate = nil
        moveRecorder = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Fuers Dismiss-Monitoring des Menueleisten-Panels: Klicks in die Einstellungen schliessen es nicht.
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === panel }

    /// Fuer den Selbsttest (`--check-panels`).
    var debugInfo: String { "visible=\(isOpen) frame=\(panel.map { "\($0.frame)" } ?? "nil") level=\(panel?.level.rawValue ?? -1)" }
}

private final class SettingsHostingView: NSHostingView<SettingsPane> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    required init(rootView: SettingsPane) { super.init(rootView: rootView) }
    @objc required dynamic init?(coder: NSCoder) { fatalError("not used") }
}

/// Hoehe des Einstellungs-Fensters fuer die SwiftUI-Wurzel (oben verankert, ohne Animation gesetzt).
@MainActor
final class SettingsLayout: ObservableObject {
    static let shared = SettingsLayout()
    @Published var height: CGFloat?
    /// Sichtbare Hoehe des Bildschirms, auf dem das Fenster steht.
    @Published var screenHeight: CGFloat?
    func setScreen(_ h: CGFloat?) {
        guard screenHeight != h else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { screenHeight = h }
    }
    func set(_ h: CGFloat?) {
        guard height != h else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { height = h }
    }
}

struct SettingsPane: View {
    @ObservedObject var config = ConfigStore.shared
    @ObservedObject private var layout = SettingsLayout.shared
    @State private var loginEnabled: Bool = Demo.on ? false : SMAppService.mainApp.status == .enabled
    @State private var tab: Int
    @State private var contentH: CGFloat = 0
    @AppStorage(Look.appearanceKey) private var lookAppearance = Look.Mode.dark.rawValue
    @AppStorage(Look.glassKey) private var lookGlass = Look.Glass.normal.rawValue
    var onClose: (@Sendable () -> Void)? = nil
    var onSize: (@Sendable (CGSize) -> Void)? = nil

    /// Zuletzt gemessene Inhaltshoehe je Reiter: das Fenster oeffnet gleich in der richtigen Hoehe.
    @MainActor private static var cachedHeights: [Int: CGFloat] = [:]

    init(tab: Int? = nil, onClose: (@Sendable () -> Void)? = nil, onSize: (@Sendable (CGSize) -> Void)? = nil) {
        let t = tab ?? (Demo.on ? 0 : UserDefaults.standard.integer(forKey: "settingsTab"))
        _tab = State(initialValue: t)
        _contentH = State(initialValue: MainActor.assumeIsolated { Self.cachedHeights[t] } ?? 0)
        self.onClose = onClose
        self.onSize = onSize
    }

    /// Belegter Platz im Aufnahme-Ordner, menschenlesbar.
    static func recordingsSize() -> String {
        if Demo.on { return "42 MB" }   // Fotos: nie die echte Groesse zeigen
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
        VStack(alignment: .leading, spacing: Theme.s16) {
            ThemeWindowHeader(title: title(for: tab))   // Kopf = Name des Reiters (wie Systemeinstellungen)
            tabBar

            // Passt der Reiter auf den Bildschirm, wächst das Fenster mit dem Inhalt; sonst scrollt der Reiter und
            // Kopf, Fuss und ✕ bleiben stehen. Natuerliche Hoehe im Inhalt gemessen, Deckel = Bildschirm.
            let cap = max(300, (layout.screenHeight ?? NSScreen.main?.visibleFrame.height ?? 800) - 16 - 200)
            let shown = min(contentH, cap)
            ScrollView {
                tabContent
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                        contentH = max(0, h)
                        Self.cachedHeights[tab] = contentH
                    }
            }
            .scrollIndicators(.automatic)
            .scrollDisabled(contentH <= cap)
            .themeScrollFade(enabled: contentH > cap)
            .frame(height: shown, alignment: .top)
            .clipped()
            .animation(Theme.fold, value: shown)

            ThemeDivider()
            HStack(spacing: Theme.s8) {
                Text("RecBlitz \(Self.appVersion)").font(.theme(.small)).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(ThemeToggleStyle())
        .padding(Theme.s16)
        .frame(width: Theme.widgetWidth)
        .background(ThemeGlass())
        .themeDragHeader()
        .themeCloseCorner { onClose?() }
        // Am Glas (vor dem Buehnen-Padding) messen, dann oben festnageln auf die Fensterhoehe.
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            if size.width > 1 { onSize?(size) }
        }
        .padding(Theme.stageInset)
        .frame(height: layout.height, alignment: .top)
        .ignoresSafeArea()
        .onChange(of: tab) { _, new in
            if !Demo.on { UserDefaults.standard.set(new, forKey: "settingsTab") }
        }
        .onDisappear { config.save() }
    }

    // MARK: - Reiterleiste

    private static let tabs: [(id: Int, icon: String)] = [
        (0, "gearshape"), (1, "text.bubble"), (2, "rectangle.dashed.badge.record"), (3, "externaldrive"),
    ]

    private func title(for id: Int) -> String {
        switch id {
        case 1:  return L.t("Transkript", "Transcript")
        case 2:  return L.t("Bildschirm", "Screen")
        case 3:  return "Drive"
        default: return L.t("Allgemein", "General")
        }
    }

    /// Beschriftete Reiter: Symbol über kurzem Wort, gewählt = blau hinterlegt.
    private var tabBar: some View {
        HStack(spacing: Theme.s4) {
            ForEach(Self.tabs, id: \.id) { t in
                SettingsTabButton(symbol: t.icon, label: title(for: t.id), selected: tab == t.id) { tab = t.id }
            }
        }
        .padding(Theme.s4)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case 1: transcriptTab
        case 2: screenTab
        case 3: driveTab
        default: generalTab
        }
    }

    // MARK: - Allgemein

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            Toggle(L.t("Beim Login starten", "Launch at login"), isOn: $loginEnabled)
                .onChange(of: loginEnabled) { _, on in
                    guard !Demo.on else { return }
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        loginEnabled = SMAppService.mainApp.status == .enabled
                    }
                }
            ThemeChoiceRow(title: L.t("Sprache", "Language"), options: [("English", "en"), ("Deutsch", "de")],
                           selection: $config.appLanguage)
            ThemeChoiceRow(title: L.t("Aussehen", "Appearance"),
                           options: [(L.t("System", "System"), Look.Mode.system.rawValue),
                                     (L.t("Hell", "Light"), Look.Mode.light.rawValue),
                                     (L.t("Dunkel", "Dark"), Look.Mode.dark.rawValue)],
                           selection: Binding(get: { lookAppearance }, set: { lookAppearance = $0; Look.apply() }))
            ThemeChoiceRow(title: L.t("Glas", "Glass"),
                           options: [(L.t("Normal", "Normal"), Look.Glass.normal.rawValue),
                                     (L.t("Klarer", "Clearer"), Look.Glass.clear.rawValue)],
                           selection: $lookGlass)

            ThemeSectionDivider()
            ThemeFormRow(title: L.t("Lokale Aufnahmen", "Local recordings")) {
                // Größe mit dranschreiben: Videos wachsen schnell und man merkt es sonst erst, wenn die Platte voll ist.
                Button(L.t("Öffnen", "Open") + " · \(SettingsPane.recordingsSize())") {
                    NSWorkspace.shared.open(Recorder.recordingsDir)
                }
                .buttonStyle(ThemeLinkStyle())
            }
            ThemeFormRow(title: L.t("Panel-Position", "Panel position")) {
                Button(L.t("Zurücksetzen", "Reset")) { PanelDock.forgetPositions(ids: ["recblitz-settings-v2"]) }
                    .buttonStyle(ThemeLinkStyle())
            }
        }
    }

    // MARK: - Transkript & Notizen

    private var transcriptTab: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            // Sprache, Mikrofon, Systemton und Webcam stehen NUR im Fenster unter dem Symbol (Runde 18, Frage 2).
            ThemeNote(L.t("Die Sprache wählst du im Fenster unter dem Symbol. Transkribiert wird auf dem Mac mit Apples Spracherkennung (macOS 26). „Auto“ braucht zusätzlich mlx-whisper.",
                          "Pick the language in the window under the icon. Transcription runs on your Mac with Apple's speech recognition (macOS 26). “Auto” also needs mlx-whisper."))

            ThemeSectionDivider()
            Toggle(L.t("Zusammenfassung + Nächste Schritte", "Summary + next steps"), isOn: $config.summarize)
                .onChange(of: config.summarize) { _, _ in config.save() }
            ThemeNote(L.t("Über die Claude-Befehlszeile, falls installiert. Ohne sie bleibt es beim Transkript.",
                          "Via the Claude command line, if installed. Without it you get the transcript only."))

            ThemeSectionDivider()
            Toggle(L.t("Notiz als Markdown speichern", "Save each note as Markdown"), isOn: $config.markdownEnabled)
                .onChange(of: config.markdownEnabled) { _, _ in config.save() }
            HStack(spacing: Theme.s8) {
                TextField(ConfigStore.defaultNotesDir, text: $config.markdownDir)
                    .textFieldStyle(ThemeFieldStyle())
                    .onSubmit { config.save() }
                Button(L.t("Wählen …", "Choose …")) { chooseNotesFolder() }
                    .buttonStyle(ThemeLinkStyle())
            }
            .disabled(!config.markdownEnabled)
            ThemeNote(L.t("Zum Beispiel ein Ordner in deinem Obsidian-Vault. Titel, Zusammenfassung und Transkript in einer Datei.",
                          "For example a folder in your Obsidian vault. Title, summary and transcript in one file."))
        }
    }

    /// Ordnerwahl. Der Dialog muss ÜBER dem Einstellungs-Panel liegen (`.floating`), sonst öffnet er sich unsichtbar dahinter.
    private func chooseNotesFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.prompt = L.t("Auswählen", "Choose")
        open.directoryURL = config.markdownDirURL
        open.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
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
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            ThemeChoiceRow(title: L.t("Qualität", "Quality"),
                           options: [("1080p", 1920), ("1440p", 2560), (L.t("Original", "Native"), 0)],
                           selection: Binding(get: { config.screenMaxDimension }, set: { config.screenMaxDimension = $0; config.save() }))
            ThemeChoiceRow(title: L.t("Vorlauf", "Countdown"),
                           options: [(L.t("Aus", "Off"), 0), ("3 s", 3), ("5 s", 5)],
                           selection: Binding(get: { config.countdownSeconds }, set: { config.countdownSeconds = $0; config.save() }))
            ThemeNote(L.t("Zeit, um zum richtigen Fenster zu wechseln, bevor die Aufnahme läuft.",
                          "Time to switch to the right window before recording starts."))

            ThemeSectionDivider()
            ThemeChoiceRow(title: L.t("Webcam-Größe", "Webcam size"),
                           options: [(L.t("Klein", "Small"), 130), (L.t("Mittel", "Medium"), 160), (L.t("Groß", "Large"), 200)],
                           selection: Binding(get: { config.webcamSize }, set: { config.webcamSize = $0; config.save() }))
            ThemeNote(L.t("Die Webcam schaltest du im Fenster unter dem Symbol ein. Die Blase landet mit im Video und lässt sich frei verschieben.",
                          "Switch the webcam on in the window under the icon. The bubble is recorded into the video and can be dragged anywhere."))
        }
    }

    // MARK: - Google Drive

    private var driveTab: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            Toggle(L.t("Google Doc + Video nach Drive", "Google Doc + video to Drive"), isOn: $config.driveEnabled)
                .onChange(of: config.driveEnabled) { _, _ in config.save() }

            HStack(spacing: Theme.s8) {
                Image(systemName: Self.rclonePath != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.theme(.small))
                    .foregroundStyle(Self.rclonePath != nil ? Theme.ok : Theme.warn)
                Text(Self.rclonePath != nil
                     ? L.t("rclone gefunden", "rclone found")
                     : L.t("rclone fehlt: brew install rclone, dann rclone config", "rclone missing: brew install rclone, then rclone config"))
                    .font(.theme(.small)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: Theme.rowHeight)

            VStack(alignment: .leading, spacing: Theme.s8) {
                labeledField(L.t("rclone-Remote", "rclone remote"), text: $config.driveRemote, placeholder: "gdrive:")
                labeledField(L.t("Ordner für Docs", "Folder for docs"), text: $config.driveFolderInput,
                             placeholder: L.t("Drive-Link oder Ordner-ID", "Drive link or folder ID"))
                labeledField(L.t("Ordner für Videos", "Folder for videos"), text: $config.videoFolderInput,
                             placeholder: L.t("leer = wie Docs", "empty = same as docs"))
                ThemeNote(L.t("Screencasts werden schnell hunderte MB groß, ein eigener Ordner hält die Docs übersichtlich.",
                              "Screencasts get large fast, a separate folder keeps the docs tidy."))

                Toggle(L.t("Video freigeben (Jeder mit dem Link)", "Share video (anyone with the link)"),
                       isOn: $config.videoPublic)
                    .onChange(of: config.videoPublic) { _, _ in config.save() }
                ThemeNote(L.t("Das Originalvideo bleibt immer lokal in ~/Movies/RecBlitz und wird nie automatisch gelöscht.",
                              "The original video always stays local in ~/Movies/RecBlitz and is never deleted automatically."))
            }
            .disabled(!config.driveEnabled)
            .opacity(config.driveEnabled ? 1 : 0.55)
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Text(label).font(.theme(.small)).foregroundStyle(Theme.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(ThemeFieldStyle())
                .onSubmit { config.save() }
        }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
