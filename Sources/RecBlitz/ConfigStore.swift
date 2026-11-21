import Foundation

/// Liest/schreibt config.json (geteilt mit pipeline.py).
///
/// Liegt in `~/Library/Application Support/RecBlitz/`, NICHT neben dem
/// Quelltext: eine App, die ihre Einstellungen im Bauordner sucht, läuft nur
/// auf dem Rechner, auf dem sie gebaut wurde.
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()
    static var path: String { PipelineRunner.supportDir + "/config.json" }

    /// Standardordner für die Markdown-Notizen. Liegt sichtbar in Dokumente,
    /// damit eine frische Installation ohne jede Einrichtung ein Ergebnis hat.
    static let defaultNotesDir = "~/Documents/RecBlitz"

    @Published var driveFolderInput: String = ""   // Link oder ID
    /// Transkriptionssprache. Ohne gespeicherte Wahl die Sprache der App,
    /// sonst transkribiert eine frische Installation Englisch als Deutsch.
    @Published var language: String = ConfigStore.defaultLanguage
    static var defaultLanguage: String { L.isDE ? "de-DE" : "en-US" }
    @Published var summarize: Bool = true
    /// Markdown-Kopie jeder Notiz in einen Ordner (z. B. einen Obsidian-Vault).
    /// Schlüssel heißt aus Kompatibilität weiter `obsidian_enabled`.
    @Published var markdownEnabled: Bool = true
    /// Zielordner der Markdown-Kopie (`vault_notes_dir`).
    @Published var markdownDir: String = ConfigStore.defaultNotesDir

    // MARK: - Google Drive (optional, über rclone)

    /// Google Doc + Video-Upload nach Drive. Aus, bis jemand es bewusst
    /// einschaltet: ohne eingerichtetes rclone würde jede Aufnahme mit einer
    /// Fehlermeldung enden, obwohl Transkript und Markdown längst da sind.
    @Published var driveEnabled: Bool = false
    /// Name des rclone-Remotes inklusive Doppelpunkt, z. B. "gdrive:".
    @Published var driveRemote: String = "gdrive:"

    // MARK: - Bildschirmaufnahme (31.07.)

    /// "off" | "screen" | "region". Default "off": der Normalfall bleibt die
    /// reine Sprachnotiz, Bildschirm ist eine bewusste Entscheidung.
    @Published var screenMode: String = "off"
    /// Mikrofon aufnehmen. Default an. Zusammen mit dem Systemton die Absicherung
    /// für Calls: ohne beide gibt es keine Aufnahme (05.10.).
    @Published var captureMicrophone: Bool = true
    /// Systemton mitnehmen (die andere Seite im Call, Videos). Default an,
    /// denn Telegram-Calls im „Nur Ton"-Modus hatten nur das Mikro (05.10.).
    @Published var screenSystemAudio: Bool = true
    /// Längste Kante des Videos. 0 = native Pixelauflösung (Default seit 03.11.,
    /// vorher 2560 und damit bei großen Retina-Bereichen heruntergerechnet).
    @Published var screenMaxDimension: Int = 0
    /// Gewähltes Mikrofon (`uniqueID`). Leer = System-Standard (03.11.).
    @Published var micDeviceID: String = ""
    /// Bildrate der Bildschirmaufnahme.
    @Published var screenFPS: Int = 30
    /// Eigener Drive-Ordner für Videos (leer = derselbe wie für die Docs).
    @Published var videoFolderInput: String = ""
    /// Welcher Bildschirm aufgenommen wird (CGDirectDisplayID). 0 = Hauptbildschirm.
    /// Bei mehreren Monitoren sonst immer der falsche (Rückmeldung 31.07.).
    @Published var screenDisplayID: Int = 0
    /// Lokales Video löschen, sobald der Drive-Upload nachweislich geklappt hat.
    /// 146 MB nach einem einzigen Testnachmittag (Rückmeldung 01.08.), ohne das
    /// läuft die Platte still voll.
    /// Seit 03.11. ohne Wirkung: das Originalvideo bleibt immer lokal in
    /// ~/Movies/RecBlitz. Das Feld bleibt nur, damit alte config.json lesbar ist.
    @Published var deleteLocalAfterUpload: Bool = false
    /// Webcam-Blase während der Bildschirmaufnahme einblenden.
    @Published var webcamEnabled: Bool = false
    /// Durchmesser der Blase in Punkten.
    @Published var webcamSize: Int = 160
    /// Vorlauf in Sekunden vor der Bildschirmaufnahme. 0 = aus.
    @Published var countdownSeconds: Int = 3
    /// Video nach dem Upload auf "Jeder mit dem Link" stellen. Default AN, weil
    /// der Sinn eines Screencasts das Verschicken ist, ohne Freigabe landet der
    /// Empfänger auf "Zugriff anfordern" (verifiziert 31.07.).
    @Published var videoPublic: Bool = true
    /// UI-Sprache (de/en), @Published, damit alle Views live umschalten.
    @Published var appLanguage: String = L.lang {
        didSet { UserDefaults.standard.set(appLanguage, forKey: "appLanguage") }
    }

    private var raw: [String: Any] = [:]

    /// Nur für den Design-Check: mit Voreinstellungen starten statt die echte
    /// config.json zu lesen. Sonst stünden in Doku-Bildern private Ordner-IDs
    /// und Pfade. Muss VOR dem ersten Zugriff auf `shared` gesetzt werden.
    nonisolated(unsafe) static var useDefaultsOnly = false

    init() {
        if !ConfigStore.useDefaultsOnly { load() } else if Demo.on {
            // Testmodus: erfundene Werte statt der echten Konfiguration.
            markdownDir = Demo.notesFolder
            driveEnabled = true
            driveFolderInput = Demo.driveFolder
        }
    }

    func load() {
        guard let data = FileManager.default.contents(atPath: ConfigStore.path),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        raw = dict
        driveFolderInput = dict["drive_folder_id"] as? String ?? ""
        language = dict["language"] as? String ?? ConfigStore.defaultLanguage
        summarize = dict["summarize"] as? Bool ?? true
        markdownEnabled = dict["obsidian_enabled"] as? Bool ?? true
        markdownDir = dict["vault_notes_dir"] as? String ?? ConfigStore.defaultNotesDir
        driveEnabled = dict["drive_enabled"] as? Bool ?? false
        driveRemote = dict["drive_remote"] as? String ?? "gdrive:"
        screenMode = dict["screen_mode"] as? String ?? "off"
        screenSystemAudio = dict["screen_system_audio"] as? Bool ?? true
        captureMicrophone = dict["capture_microphone"] as? Bool ?? true
        // Der alte Default 2560 wurde als Wert mitgespeichert und hat Retina-
        // Aufnahmen verkleinert: er zählt nur noch, wenn er bewusst anders ist.
        let storedMax = dict["screen_max_dimension"] as? Int ?? 0
        screenMaxDimension = storedMax == 2560 ? 0 : storedMax
        micDeviceID = dict["mic_device_id"] as? String
            ?? UserDefaults.standard.string(forKey: "selectedMicID") ?? ""
        screenFPS = dict["screen_fps"] as? Int ?? 30
        videoFolderInput = dict["video_folder_id"] as? String ?? ""
        videoPublic = dict["video_public"] as? Bool ?? true
        screenDisplayID = dict["screen_display_id"] as? Int ?? 0
        deleteLocalAfterUpload = false
        countdownSeconds = dict["countdown_seconds"] as? Int ?? 3
        webcamEnabled = dict["webcam_enabled"] as? Bool ?? false
        webcamSize = dict["webcam_size"] as? Int ?? 160
    }

    /// Extrahiert die Folder-ID aus einem Drive-Link (oder gibt die Eingabe zurück).
    static func folderID(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "/folders/") {
            let tail = trimmed[range.upperBound...]
            return String(tail.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }))
        }
        return trimmed
    }

    /// Drive-Ordner als Weblink, falls einer eingetragen ist.
    var driveFolderURL: URL? {
        let id = ConfigStore.folderID(from: driveFolderInput)
        guard driveEnabled, !id.isEmpty else { return nil }
        return URL(string: "https://drive.google.com/drive/folders/\(id)")
    }

    /// Markdown-Zielordner mit aufgelöster Tilde.
    var markdownDirURL: URL {
        URL(fileURLWithPath: (markdownDir as NSString).expandingTildeInPath, isDirectory: true)
    }

    func save() {
        guard !ConfigStore.useDefaultsOnly else { return }
        raw["drive_folder_id"] = ConfigStore.folderID(from: driveFolderInput)
        raw["language"] = language
        raw["summarize"] = summarize
        raw["obsidian_enabled"] = markdownEnabled
        raw["vault_notes_dir"] = markdownDir
        raw["drive_enabled"] = driveEnabled
        raw["drive_remote"] = driveRemote
        raw["screen_mode"] = screenMode
        raw["screen_system_audio"] = screenSystemAudio
        raw["capture_microphone"] = captureMicrophone
        raw["screen_max_dimension"] = screenMaxDimension
        raw["mic_device_id"] = micDeviceID
        raw["screen_fps"] = screenFPS
        raw["video_folder_id"] = ConfigStore.folderID(from: videoFolderInput)
        raw["video_public"] = videoPublic
        raw["screen_display_id"] = screenDisplayID
        raw["delete_local_after_upload"] = deleteLocalAfterUpload
        raw["countdown_seconds"] = countdownSeconds
        raw["webcam_enabled"] = webcamEnabled
        raw["webcam_size"] = webcamSize
        if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: ConfigStore.path))
        }
        driveFolderInput = raw["drive_folder_id"] as? String ?? driveFolderInput
    }
}
