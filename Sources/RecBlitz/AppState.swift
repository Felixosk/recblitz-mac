import Foundation

/// Das zuletzt verarbeitete Ergebnis. Wird als JSON gemerkt, damit die Zeile
/// „Zuletzt" im Panel auch nach einem App-Neustart noch auf Doc, Video und
/// Notiz zeigt, statt leer zu sein.
struct LastResult: Codable, Equatable {
    var title: String
    var date: Date
    var docURL: URL?
    var videoURL: URL?
    var markdownPath: String?

    static var fileURL: URL {
        URL(fileURLWithPath: PipelineRunner.supportDir).appendingPathComponent("last_result.json")
    }

    static func load() -> LastResult? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(LastResult.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: LastResult.fileURL) }
    }
}

/// Zentraler UI-State fürs Panel (gefüttert vom AppDelegate).
final class AppState: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var elapsed: Int = 0
    @Published var lastTranscript: String?
    @Published var uploading = false
    /// Läuft gerade ein Video-Upload? Eigenes Flag, weil ein Screencast deutlich
    /// länger hochlädt als ein Textdokument und man sehen will, worauf man wartet.
    @Published var uploadingVideo = false
    /// Upload-Fortschritt in Prozent, nil solange nichts läuft.
    @Published var uploadProgress: Int?
    /// Letztes fertiges Ergebnis (Titel, Doc, Video, Markdown). Gespeichert
    /// wird ausdrücklich an der einen Stelle, die ein echtes Ergebnis setzt,
    /// nicht per didSet: sonst überschriebe der Design-Check mit seinen
    /// Beispieldaten das echte letzte Ergebnis.
    @Published var last: LastResult? = LastResult.load()

    var lastDocURL: URL? { last?.docURL }
    var lastVideoURL: URL? { last?.videoURL }

    /// Vom AppDelegate gesetzt: startet/stoppt die Aufnahme.
    var onToggleRecording: (() -> Void)?
    /// Läuft die Aufnahme gerade pausiert? Nur bei Bildschirmaufnahme möglich.
    @Published var paused = false
    /// Pause umschalten.
    var onTogglePause: (() -> Void)?
    /// Aufnahme abbrechen und die Datei wegwerfen, ohne Transkription, ohne
    /// Upload. Bei einem verhaspelten 5-Minuten-Screencast will man nicht die
    /// ganze Pipeline durchlaufen lassen (Rückmeldung 31.07.).
    var onDiscardRecording: (() -> Void)?
}
