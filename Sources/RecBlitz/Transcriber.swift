import AVFoundation
import Foundation
import Speech

/// On-device Transkription über Apples SpeechAnalyzer (macOS 26+).
/// Deutlich schneller als Whisper (Sekunden statt zig Sekunden), OS-verwaltetes Modell.
@available(macOS 26.0, *)
enum Transcriber {
    static func transcribe(fileURL: URL, localeIdentifier: String = "de-DE") async throws -> String {
        let locale = Locale(identifier: localeIdentifier)
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [])

        // Sprachmodell sicherstellen (einmaliger OS-Download, danach lokal).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: fileURL)

        async let collected: String = {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }()

        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let text = try await collected
        return text.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
