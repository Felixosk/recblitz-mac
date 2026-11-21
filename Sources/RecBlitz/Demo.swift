import Foundation

/// Testmodus (`--demo-config`, `--demo-window`): nur erfundene Daten, nie echte Geraete,
/// Ordner oder Titel. Liest und schreibt keine config.json (siehe ConfigStore.useDefaultsOnly).
enum Demo {
    nonisolated(unsafe) static var on = false
    static let mics: [(id: String, name: String)] = [
        ("demo-builtin", "MacBook Pro Microphone"),
        ("demo-usb", "USB Mic Demo"),
    ]
    /// Erfundene Monitore (nur mit `--demo-displays`), damit die Monitor-Zeile fotografierbar ist.
    static let displays: [DisplayChoice] = [
        DisplayChoice(id: 1, name: "Built-in", pixels: "3024 × 1964 px", isMain: true),
        DisplayChoice(id: 2, name: "Studio", pixels: "2560 × 1440 px", isMain: false),
    ]
    static let defaultMicName = "MacBook Pro Microphone"
    static let notesFolder = "~/Documents/Arbeit"
    static let driveFolder = "1AbCdEfGhIjKlMnOpQrStUvWxYz"
    static let title = "Ablauf für das neue Onboarding und die zwei offenen Fragen - 2026-09-26 10.29 - RecBlitz"
    static let titleEN = "Onboarding flow walkthrough and the two open questions - 2026-09-26 10.29 - RecBlitz"
}

extension Demo {
    /// Beispiel-Zustand fuer Fotos und Demo-Fenster, nie das echte letzte Ergebnis.
    /// mode: idle | recording | paused | armed | uploading | empty | transcribing
    static func state(mode: String) -> AppState {
        let s = AppState()
        s.last = nil
        s.lastTranscript = nil
        if mode != "empty" {
            s.last = LastResult(title: L.t(title, titleEN), date: Date(),
                                docURL: URL(string: "https://example.com/doc"),
                                videoURL: mode == "idle" ? nil : URL(string: "https://example.com/video"),
                                markdownPath: nil,
                                localVideoPath: mode == "idle" ? nil : "/tmp/demo.mp4")
            s.lastTranscript = "…"
        }
        switch mode {
        case "recording": s.phase = .recording; s.elapsed = 42
        case "paused": s.phase = .recording; s.elapsed = 42; s.paused = true
        case "armed": s.phase = .armed
        case "transcribing": s.phase = .transcribing
        case "uploading": s.phase = .uploading; s.uploading = true; s.uploadingVideo = true; s.uploadProgress = 64
        default: break
        }
        return s
    }
}
