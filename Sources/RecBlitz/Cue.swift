import AppKit

/// Kurze Hoerzeichen fuer Start und Stopp (03.11.). Der Startton laeuft VOR der
/// Aufnahme und wird abgewartet: so kann er weder ueber das Mikrofon noch ueber
/// den Systemton in die Datei geraten.
@MainActor
enum Cue {
    /// Tink dauert 0,56 s; etwas Luft fuer den Nachhall des Lautsprechers.
    private static let startWait: UInt64 = 750_000_000

    /// Spielt den Startton und kehrt erst danach zurueck.
    static func playStart() async {
        guard let s = NSSound(named: "Tink") else { return }
        s.volume = 0.6
        s.play()
        try? await Task.sleep(nanoseconds: startWait)
    }

    /// Leiser Stopp-Ton, NACH dem Beenden der Aufnahme (nichts mehr, was ihn hoert).
    static func playStop() {
        guard let s = NSSound(named: "Pop") else { return }
        s.volume = 0.35
        s.play()
    }
}
