import Foundation

struct PipelineResult: Decodable {
    let ok: Bool
    let title: String?
    let doc_url: String?
    /// Pfad der Markdown-Kopie (Schlüsselname historisch).
    let obsidian_path: String?
    let obsidian_error: String?
    /// Warum kein Google Doc entstand (Drive aus, rclone fehlt, Upload-Fehler).
    let doc_error: String?
    /// Drive-Link der Bildschirmaufnahme (nur bei Screencasts gesetzt).
    let video_url: String?
    let video_error: String?
    let preview: String?
    let text: String?
    let error: String?
}

/// Sammelt die stdout-Bytes des Kindprozesses und schneidet sie in Zeilen.
///
/// Eigener Typ, weil der `readabilityHandler` auf einer fremden Queue läuft und
/// der `terminationHandler` auf einer anderen — ohne Sperre wäre der Puffer ein
/// Datenrennen.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var pending = ""

    /// Hängt an und liefert die dadurch VOLLSTÄNDIG gewordenen Zeilen.
    func append(_ data: Data) -> [String] {
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        lock.lock(); defer { lock.unlock() }
        text += s
        pending += s
        var lines: [String] = []
        while let nl = pending.firstIndex(of: "\n") {
            lines.append(String(pending[pending.startIndex..<nl]))
            pending = String(pending[pending.index(after: nl)...])
        }
        return lines
    }

    func everything() -> String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}

/// Runs pipeline.py (Titel/Zusammenfassung -> Markdown -> optional Google Doc)
/// as a child process.
enum PipelineRunner {
    /// Arbeitsordner der App: config.json, Logs, Aufnahmen, letztes Ergebnis.
    static let supportDir: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("RecBlitz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()

    /// pipeline.py liegt im App-Bundle (build.sh kopiert es nach Resources).
    /// Der Rückfall neben der Binärdatei hält `swift run` aus dem Quellordner
    /// lauffähig, wo es kein Bundle gibt.
    static var scriptPath: String {
        if let p = Bundle.main.path(forResource: "pipeline", ofType: "py") { return p }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("pipeline.py").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return supportDir + "/pipeline.py"
    }

    /// Umgebung für den Kindprozess: Homebrew im PATH (rclone, ffmpeg), dazu
    /// Arbeitsordner und UI-Sprache, damit Doc-Überschriften und Zusammenfassung
    /// in derselben Sprache kommen wie die App.
    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["RECBLITZ_HOME"] = supportDir
        env["RECBLITZ_LANG"] = L.lang
        return env
    }

    /// Schnelle Sprach-Erkennung via pipeline.py --detect-lang (whisper-tiny).
    /// completion (main queue) bekommt "de"/"en"/… oder nil bei Fehler.
    static func detectLanguage(audioPath: String, completion: @escaping (String?) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", scriptPath, "--detect-lang", audioPath]
        proc.environment = environment
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        proc.terminationHandler = { _ in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: data, encoding: .utf8) ?? ""
            var code: String?
            if let line = stdout.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                code = obj["language"] as? String
            }
            DispatchQueue.main.async { completion(code) }
        }
        do { try proc.run() } catch {
            DispatchQueue.main.async { completion(nil) }
        }
    }

    /// Calls completion on the main queue with (result, errorMessage) — exactly one is non-nil.
    /// `onProgress` bekommt zwischendurch die Upload-Prozente (0…100).
    static func run(arguments: [String],
                    onProgress: ((Int) -> Void)? = nil,
                    completion: @escaping (PipelineResult?, String?) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", scriptPath] + arguments
        proc.environment = environment

        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        // stdout LAUFEND lesen, nicht erst am Ende: pipeline.py schickt während
        // des Video-Uploads Zeilen wie {"progress": 42}. Deshalb sammeln wir
        // hier selbst — `readDataToEndOfFile()` im terminationHandler bekäme
        // nichts mehr, weil der readabilityHandler die Daten schon abholt.
        let buffer = OutputBuffer()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for line in buffer.append(chunk) {
                guard line.hasPrefix("{"), line.contains("\"progress\"") else { continue }
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let pct = obj["progress"] as? Int {
                    DispatchQueue.main.async { onProgress?(pct) }
                }
            }
        }

        proc.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            // Rest einsammeln, den der Handler nicht mehr erwischt hat.
            let tailData = out.fileHandleForReading.readDataToEndOfFile()
            if !tailData.isEmpty { _ = buffer.append(tailData) }
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                // Last stdout line starting with "{" is the result JSON.
                let stdout = buffer.everything()
                if let line = stdout.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
                   let result = try? JSONDecoder().decode(PipelineResult.self, from: Data(line.utf8)) {
                    if result.ok {
                        completion(result, nil)
                    } else {
                        completion(nil, result.error ?? L.t("Pipeline-Fehler", "Pipeline error"))
                    }
                } else {
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    let tail = stderr.split(separator: "\n").suffix(3).joined(separator: " · ")
                    completion(nil, L.t("Pipeline abgestürzt", "Pipeline crashed") + " (Exit \(p.terminationStatus)): \(tail)")
                }
            }
        }

        do {
            try proc.run()
        } catch {
            DispatchQueue.main.async { completion(nil, L.t("Pipeline-Start fehlgeschlagen", "Could not start the pipeline") + ": \(error.localizedDescription)") }
        }
    }
}
