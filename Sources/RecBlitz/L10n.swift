import Foundation

/// App-Sprachumschaltung nach dem MeetingBlitz-Muster: jeder sichtbare String
/// läuft durch `L.t(de, en)`. Sprache liegt in UserDefaults ("appLanguage"),
/// gesetzt über ConfigStore.appLanguage (@Published → Views rendern live neu).
/// Ohne gespeicherte Wahl folgt die App der Systemsprache: Deutsch auf einem
/// deutschen Mac, sonst Englisch.
enum L {
    /// Nur für den Design-Check (`--render-panel … --lang=en`): Bilder für die
    /// Doku in einer festen Sprache, ohne die gespeicherte Wahl anzufassen.
    nonisolated(unsafe) static var override: String?

    static var lang: String {
        if let override { return override }
        if let saved = UserDefaults.standard.string(forKey: "appLanguage") { return saved }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("de") ? "de" : "en"
    }

    static var isDE: Bool { lang == "de" }

    static func t(_ de: String, _ en: String) -> String { isDE ? de : en }
}
