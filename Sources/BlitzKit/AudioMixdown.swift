import Foundation

/// Mischt Mikrofon- und Systemton-Spur einer Aufnahme in EINE Tonspur.
///
/// **Warum das nötig ist:** `SCStream` liefert Mikro und Systemton als getrennte
/// Ausgänge, der AVAssetWriter schreibt sie folglich als zwei Tonspuren in die
/// MP4. Die meisten Player, darunter die Google-Drive-Vorschau und QuickTime,
/// spielen aber nur die ERSTE Tonspur — der Zuschauer hört dann entweder nur die
/// Stimme oder nur die Musik. Verifiziert 31.07.: beide Spuren enthielten Signal,
/// nur eben getrennt.
///
/// Live mischen ginge nur mit eigener Audio-Engine über den Sample-Buffern. Das
/// ist deutlich mehr Angriffsfläche als ein Remux nach der Aufnahme, bei dem das
/// Video unangetastet durchkopiert wird.
public enum AudioMixdown {

    public static var isAvailable: Bool { ffmpegPath != nil }

    private static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Mischt die Tonspuren von `url` in eine und ersetzt die Datei.
    /// Best effort: passiert etwas Unerwartetes, bleibt die Originaldatei stehen
    /// und die Funktion liefert `false` — eine Aufnahme mit zwei Tonspuren ist
    /// immer noch besser als keine.
    @discardableResult
    public static func mixToSingleTrack(at url: URL, micGain: Double = 1.0,
                                        systemGain: Double = 0.7) -> Bool {
        guard let ffmpeg = ffmpegPath else { return false }

        let tmp = url.deletingPathExtension()
            .appendingPathExtension("mix.mp4")
        try? FileManager.default.removeItem(at: tmp)

        // Explizite volume-Filter statt amix-weights: die weights-Option gibt es
        // erst in neueren ffmpeg-Versionen. normalize=0, damit amix die Pegel
        // nicht pauschal halbiert.
        let filter = "[0:a:0]volume=\(micGain)[m];[0:a:1]volume=\(systemGain)[s];" +
                     "[m][s]amix=inputs=2:duration=longest:normalize=0[a]"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-y", "-i", url.path,
                       "-filter_complex", filter,
                       "-map", "0:v:0", "-map", "[a]",
                       // -ac 2: amix liefert sonst die Kanalzahl der Mono-Mikrospur,
                       // Musik wuerde also in Mono landen.
                       "-c:v", "copy", "-c:a", "aac", "-b:a", "160k", "-ac", "2",
                       tmp.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()

        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }

        guard p.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tmp.path),
              let size = try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int64,
              size > 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}
