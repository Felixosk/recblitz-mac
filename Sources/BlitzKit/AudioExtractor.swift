import AVFoundation

/// Zieht die Tonspur aus einer Videodatei in eine eigene .m4a.
///
/// **Warum:** Die Transkriptions- und Google-Doc-Kette von RecBlitz erwartet eine
/// Audiodatei. Statt sie für Screencasts umzubauen, liefern wir ihr weiter genau
/// das, was sie kennt. Der Export läuft als Passthrough, kodiert also nicht neu
/// und ist entsprechend schnell.
public enum AudioExtractor {

    public enum ExtractError: LocalizedError {
        case msg(String)
        public var errorDescription: String? { if case .msg(let m) = self { return m }; return nil }
    }

    /// Schreibt die Tonspur von `videoURL` nach `destination` (.m4a).
    public static func extractAudio(from videoURL: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: videoURL)

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw ExtractError.msg("Die Aufnahme enthält keine Tonspur.")
        }

        try? FileManager.default.removeItem(at: destination)

        // NICHT Passthrough: das Preset nimmt ALLE Spuren mit, und eine .m4a kann
        // kein Video führen -> der Export bricht mit "Operation Stopped" ab
        // (verifiziert 31.07.). AppleM4A ist explizit audio-only.
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExtractError.msg("Audio-Export konnte nicht vorbereitet werden.")
        }
        export.outputURL = destination
        export.outputFileType = .m4a

        if #available(macOS 15.0, *) {
            try await export.export(to: destination, as: .m4a)
        } else {
            await export.export()
            if export.status != .completed {
                throw ExtractError.msg(export.error?.localizedDescription ?? "Audio-Export fehlgeschlagen.")
            }
        }
    }

    /// Dateigröße in Bytes, für Log- und Upload-Meldungen.
    public static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }
}
