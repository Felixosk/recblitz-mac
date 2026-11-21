import AVFoundation
import Foundation

/// Mic-Aufnahme über AVCaptureSession (erlaubt Geräteauswahl) → .m4a.
final class Recorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioFileOutput()
    private(set) var startedAt: Date?
    private(set) var fileURL: URL?
    /// Wird auf dem Main-Thread gerufen, sobald die Datei fertig geschrieben ist.
    var onFinished: ((URL, TimeInterval) -> Void)?
    private var stopping = false

    static var recordingsDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecBlitz/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Dauerhafter Ort der Original-Videos. Wird nie automatisch geleert.
    static var moviesDir: URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecBlitz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Verschiebt das fertige Video nach ~/Movies/RecBlitz und liefert den neuen
    /// Pfad. Klappt das Verschieben nicht, bleibt das Video, wo es ist.
    static func keepOriginalVideo(_ video: URL) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        var dest = moviesDir.appendingPathComponent("RecBlitz \(df.string(from: Date())).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = moviesDir.appendingPathComponent("RecBlitz \(df.string(from: Date())) \(n).mp4"); n += 1
        }
        do { try FileManager.default.moveItem(at: video, to: dest); return dest }
        catch { NSLog("RecBlitz: Video nicht nach Movies verschoben: %@", error.localizedDescription); return video }
    }

    var isRecording: Bool { startedAt != nil }
    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    // MARK: - Mikrofon-Auswahl

    static func availableMics() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    /// Eingaenge als (id, Name). Im Testmodus nur erfundene Geraete.
    static func micList() -> [(id: String, name: String)] {
        if Demo.on { return Demo.mics }
        return availableMics().map { ($0.uniqueID, $0.localizedName) }
    }

    /// Name des System-Standards (nil, wenn keiner da ist).
    static func defaultMicName() -> String? {
        Demo.on ? Demo.defaultMicName : AVCaptureDevice.default(for: .audio)?.localizedName
    }

    /// Gewählte Mikrofon-ID aus der Config (nil = System-Standard).
    static var selectedMicID: String? {
        get { let v = ConfigStore.shared.micDeviceID; return v.isEmpty ? nil : v }
        set { ConfigStore.shared.micDeviceID = newValue ?? ""; ConfigStore.shared.save() }
    }

    /// ID fürs Aufnehmen: das gewählte Gerät, solange es angesteckt ist, sonst nil
    /// (= System-Standard). Ein abgezogenes Headset darf die Aufnahme nicht
    /// blockieren.
    static func captureMicID() -> String? {
        guard let id = selectedMicID, availableMics().contains(where: { $0.uniqueID == id }) else { return nil }
        return id
    }

    static func currentMic() -> AVCaptureDevice? {
        if let id = captureMicID(), let d = availableMics().first(where: { $0.uniqueID == id }) {
            return d
        }
        return AVCaptureDevice.default(for: .audio)
    }

    // MARK: - Aufnahme

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default: completion(false)
        }
    }

    func start() throws {
        guard let device = Recorder.currentMic() else {
            throw NSError(domain: "RecBlitz", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Kein Mikrofon gefunden"])
        }
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(domain: "RecBlitz", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Mikrofon nicht nutzbar: \(device.localizedName)"])
        }
        session.addInput(input)
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw NSError(domain: "RecBlitz", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Audio-Output nicht nutzbar"])
            }
            session.addOutput(output)
        }
        session.commitConfiguration()
        session.startRunning()

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let url = Recorder.recordingsDir.appendingPathComponent("rec_\(df.string(from: Date())).m4a")
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
        fileURL = url
        startedAt = Date()
        stopping = false
    }

    /// Stoppt; das Ergebnis kommt asynchron über onFinished (Datei muss finalisiert werden).
    func stop() {
        guard isRecording, !stopping else { return }
        stopping = true
        output.stopRecording()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let seconds = elapsed
        session.stopRunning()
        startedAt = nil
        DispatchQueue.main.async { [weak self] in
            self?.onFinished?(outputFileURL, seconds)
        }
    }
}
