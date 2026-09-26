import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit
import CoreGraphics

/// Was aufgenommen wird.
///
/// **Die displayID ist Pflicht, nicht Kosmetik:** vorher nahm der Recorder stur
/// `content.displays.first`. Bei mehreren Monitoren wurde damit ein auf Screen 2
/// aufgezogener Bereich vom FALSCHEN Bildschirm aufgenommen (Rückmeldung 31.07.).
public enum CaptureScope: Sendable {
    /// Ganzer Bildschirm. nil = der Hauptbildschirm.
    case fullScreen(displayID: CGDirectDisplayID?)
    /// Ein einzelnes Fenster (per Picker gewählt).
    case window(CGWindowID)
    /// Ausschnitt, in Punkten relativ zum Ursprung des angegebenen Bildschirms.
    case region(CGRect, displayID: CGDirectDisplayID)
}

/// Ein auswählbarer Bildschirm für die UI.
public struct CaptureDisplay: Identifiable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let isMain: Bool
    public let pixelWidth: Int
    public let pixelHeight: Int
}

/// Nimmt den Bildschirm auf, **immer mit Mikrofon**, optional zusätzlich mit
/// Systemton.
///
/// Anforderung (31.07.): beim Bildschirm-Aufnehmen läuft das Mikro mit, wie bei
/// der Sprachnotiz. Der ganze Zweck ist, dass man erklärt, was man zeigt, und das
/// Transkript danach aus der eigenen Stimme entsteht.
///
/// **Warum Mikro IM Stream und nicht als zweite AVCaptureSession:** zwei parallele
/// Aufnahmen laufen auf zwei Uhren und driften über Minuten sichtbar auseinander.
/// `SCStreamConfiguration.captureMicrophone` (macOS 15+) hängt das Mikro in
/// denselben Stream, damit teilen sich Bild, Systemton und Mikro eine Zeitbasis
/// und die Spuren bleiben synchron. Preis: Bildschirmaufnahme braucht macOS 15+.
///
/// **Threading (teuer gelernt, MeetingBlitz Runde 45):** SCStream-Callbacks kommen
/// auf der `sampleHandlerQueue`, NICHT auf main. `MainActor.assumeIsolated` dort
/// ist eine Falle. Deshalb besitzt `AVWriter` den AVAssetWriter, ist selbst der
/// Stream-Output und wird ausschließlich auf dieser Queue angefasst.
@MainActor
public final class ScreenRecorder {

    public struct Options: Sendable {
        public var scope: CaptureScope
        /// Zusätzlich zum Mikro auch den Systemton aufnehmen (z.B. wenn im
        /// gezeigten Bildschirm ein Video läuft). Default aus.
        public var includeSystemAudio: Bool
        /// `uniqueID` des gewünschten Mikrofons; nil = Systemstandard.
        public var microphoneDeviceID: String?
        /// Längste Kante des Videos in Pixeln. nil = native Auflösung.
        public var maxDimension: Int?
        public var fps: Int
        /// Weitere Apps, die nicht im Bild auftauchen sollen. Die eigene App wird
        /// IMMER ausgeschlossen, unabhängig von dieser Liste.
        public var excludeBundleIDs: [String]
        /// Eigene Fenster, die TROTZ des App-Ausschlusses im Bild landen sollen —
        /// die Webcam-Blase soll ja gerade zu sehen sein.
        public var includeWindowIDs: [CGWindowID]

        public init(scope: CaptureScope,
                    includeSystemAudio: Bool = false,
                    microphoneDeviceID: String? = nil,
                    maxDimension: Int? = 1920,
                    fps: Int = 30,
                    excludeBundleIDs: [String] = [],
                    includeWindowIDs: [CGWindowID] = []) {
            self.scope = scope
            self.includeSystemAudio = includeSystemAudio
            self.microphoneDeviceID = microphoneDeviceID
            self.maxDimension = maxDimension
            self.fps = fps
            self.excludeBundleIDs = excludeBundleIDs
            self.includeWindowIDs = includeWindowIDs
        }
    }

    public enum RecError: LocalizedError {
        case msg(String)
        public var errorDescription: String? { if case .msg(let m) = self { return m }; return nil }
    }

    private var stream: SCStream?
    private var writer: AVWriter?
    private let sampleQueue = DispatchQueue(label: "app.blitzkit.screen")

    private(set) public var startedAt: Date?
    private(set) public var fileURL: URL?

    public var isRecording: Bool { startedAt != nil }

    /// Pausiert (01.08.). ScreenCaptureKit kennt kein Pause — der Stream läuft
    /// weiter, der Writer verwirft die Samples und verschiebt danach alle
    /// Zeitstempel um die Pausendauer. Sonst klafft im fertigen Video eine
    /// Lücke in Länge der Pause.
    private(set) public var isPaused = false
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    /// Aufgenommene Dauer OHNE die Pausen — das ist die Länge, die am Ende in
    /// der Datei steht, und die gehört in die Anzeige.
    public var elapsed: TimeInterval {
        guard let s = startedAt else { return 0 }
        let gross = Date().timeIntervalSince(s)
        let inPause = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        return max(0, gross - pausedTotal - inPause)
    }

    public func setPaused(_ paused: Bool) {
        guard isRecording, paused != isPaused else { return }
        isPaused = paused
        if paused {
            pausedAt = Date()
        } else if let p = pausedAt {
            pausedTotal += Date().timeIntervalSince(p)
            pausedAt = nil
        }
        writer?.setPaused(paused)
    }

    /// `nonisolated`, damit die Klasse auch als Property eines nicht
    /// main-actor-isolierten AppDelegate angelegt werden kann. Der Init fasst
    /// keinen isolierten Zustand an, alles andere bleibt @MainActor.
    public nonisolated init() {}

    // MARK: - Berechtigungen

    public static func hasScreenAccess() -> Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult
    public static func requestScreenAccess() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: - Start / Stop

    /// Startet die Aufnahme in `url` (.mp4). Wirft mit einer für den Nutzer
    /// lesbaren Meldung, wenn etwas fehlt.
    public func start(to url: URL, options: Options) async throws {
        guard !isRecording else { return }

        guard #available(macOS 15.0, *) else {
            throw RecError.msg("Bildschirmaufnahme mit Mikrofon braucht macOS 15 oder neuer.")
        }
        guard Self.hasScreenAccess() else {
            Self.requestScreenAccess()
            throw RecError.msg("Bildschirmaufnahme muss erlaubt werden. Nach dem Erlauben die App einmal neu starten.")
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized,
           await !AVCaptureDevice.requestAccess(for: .audio) {
            throw RecError.msg("Kein Mikrofon-Zugriff. Systemeinstellungen → Datenschutz → Mikrofon.")
        }

        let (filter, pixelSize) = try await makeFilter(for: options.scope,
                                                       alsoExcluding: options.excludeBundleIDs,
                                                       butKeeping: options.includeWindowIDs)

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = options.includeSystemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, options.fps)))
        cfg.showsCursor = true
        cfg.queueDepth = 6

        // Mikro in denselben Stream (siehe Doku oben).
        cfg.captureMicrophone = true
        cfg.microphoneCaptureDeviceID = options.microphoneDeviceID

        // Ausschnitt: sourceRect erwartet Punkte relativ zum Display-Ursprung.
        if case .region(let rect, _) = options.scope { cfg.sourceRect = rect }

        let scaled = Self.scaled(pixelSize, maxDimension: options.maxDimension)
        cfg.width = scaled.width
        cfg.height = scaled.height

        let w = try AVWriter(url: url,
                             width: scaled.width,
                             height: scaled.height,
                             withSystemAudio: options.includeSystemAudio)
        writer = w

        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(w, type: .screen, sampleHandlerQueue: sampleQueue)
        try s.addStreamOutput(w, type: .microphone, sampleHandlerQueue: sampleQueue)
        if options.includeSystemAudio {
            try s.addStreamOutput(w, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        try await s.startCapture()

        stream = s
        fileURL = url
        startedAt = Date()
        isPaused = false
        pausedAt = nil
        pausedTotal = 0
    }

    /// Stoppt und finalisiert die Datei. Liefert (Datei, Dauer).
    @discardableResult
    public func stop() async -> (URL, TimeInterval)? {
        guard isRecording, let url = fileURL else { return nil }
        let seconds = elapsed
        startedAt = nil
        isPaused = false
        pausedAt = nil
        let s = stream, w = writer
        stream = nil; writer = nil
        try? await s?.stopCapture()
        await w?.finish()
        return (url, seconds)
    }

    // MARK: - Filter / Größe

    private func makeFilter(for scope: CaptureScope,
                            alsoExcluding extraBundleIDs: [String] = [],
                            butKeeping keepWindowIDs: [CGWindowID] = []) async throws -> (SCContentFilter, CGSize) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Eigene Fenster aus der Aufnahme nehmen. Sonst filmt sich die App beim
        // Stoppen selbst mit: man klickt oben aufs Icon, das Panel klappt auf
        // und steht im fertigen Video (Feedback 31.07.). Der Zuschauer soll nur
        // den Bildschirm sehen, nicht das Aufnahme-Werkzeug.
        let ownBundleID = Bundle.main.bundleIdentifier
        let hidden = Set(extraBundleIDs + [ownBundleID].compactMap { $0 })
        let ownApps = content.applications.filter { hidden.contains($0.bundleIdentifier) }
        // Ausnahmen vom App-Ausschluss (Webcam-Blase).
        let keep = content.windows.filter { keepWindowIDs.contains($0.windowID) }

        // ⚠️ PUNKTE vs PIXEL — hier lag ein echter Qualitätsbug (31.07.):
        // `SCDisplay.width/height` und `contentRect` sind in PUNKTEN. Auf einem
        // Retina-Display sind das nur die HALBEN Pixel. Wer sie als Pixelmaße an
        // die Stream-Config gibt, nimmt in halber Auflösung auf. Der Testbildschirm
        // hat 3600x2338 Pixel, aufgenommen wurde 1800x1170, entsprechend matschig
        // war die Schrift. Die echte Pixelgröße ist contentRect * pointPixelScale.
        switch scope {
        case .window(let id):
            guard let win = content.windows.first(where: { $0.windowID == id }) else {
                throw RecError.msg("Das gewählte Fenster gibt es nicht mehr.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            return (filter, pixelSize(of: filter.contentRect.size, filter))

        case .fullScreen(let wanted):
            let display = try pick(wanted, from: content)
            let filter = SCContentFilter(display: display,
                                         excludingApplications: ownApps,
                                         exceptingWindows: keep)
            return (filter, pixelSize(of: filter.contentRect.size, filter))

        case .region(let r, let wanted):
            // Der Bildschirm MUSS der sein, auf dem der Bereich aufgezogen wurde.
            let display = try pick(wanted, from: content)
            let filter = SCContentFilter(display: display,
                                         excludingApplications: ownApps,
                                         exceptingWindows: keep)
            // sourceRect ist in Punkten, die Ausgabe braucht Pixel.
            return (filter, pixelSize(of: r.size, filter))
        }
    }

    /// Sucht den gewünschten Bildschirm; fällt auf den Hauptbildschirm zurück,
    /// wenn er nicht mehr da ist (Monitor abgezogen, Konfiguration geändert).
    private func pick(_ wanted: CGDirectDisplayID?,
                      from content: SCShareableContent) throws -> SCDisplay {
        if let wanted, let match = content.displays.first(where: { $0.displayID == wanted }) {
            return match
        }
        let main = CGMainDisplayID()
        if let m = content.displays.first(where: { $0.displayID == main }) { return m }
        guard let any = content.displays.first else {
            throw RecError.msg("Kein Bildschirm gefunden.")
        }
        return any
    }

    /// Alle aufnehmbaren Bildschirme, für die Auswahl in der UI.
    /// Bildschirme für die Auswahl im Panel. Bewusst über `NSScreen` statt
    /// `SCShareableContent`: Letzteres braucht die Bildschirmaufnahme-Freigabe,
    /// und weil das Panel die Liste bei JEDEM Öffnen holt, kam sonst schon beim
    /// bloßen Aufklappen die macOS-Abfrage „möchte den Bildschirm aufnehmen"
    /// (Rückmeldung 26.09.). Gefragt wird erst, wenn wirklich aufgenommen wird.
    @MainActor
    public static func availableDisplays() async -> [CaptureDisplay] {
        let main = CGMainDisplayID()
        return NSScreen.screens.enumerated().compactMap { idx, screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            let scale = screen.backingScaleFactor
            return CaptureDisplay(
                id: id,
                name: screen.localizedName.isEmpty ? "Display \(idx + 1)" : screen.localizedName,
                isMain: id == main,
                pixelWidth: Int(screen.frame.width * scale),
                pixelHeight: Int(screen.frame.height * scale))
        }
    }

    private func pixelSize(of pointSize: CGSize, _ filter: SCContentFilter) -> CGSize {
        let scale = CGFloat(filter.pointPixelScale)
        guard scale > 0 else { return pointSize }
        return CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
    }

    /// Skaliert auf die gewünschte längste Kante und rundet auf GERADE Zahlen —
    /// H.264 kann keine ungeraden Kantenlängen kodieren.
    static func scaled(_ size: CGSize, maxDimension: Int?) -> (width: Int, height: Int) {
        var w = max(2, Int(size.width.rounded()))
        var h = max(2, Int(size.height.rounded()))
        if let maxDim = maxDimension, max(w, h) > maxDim {
            let f = Double(maxDim) / Double(max(w, h))
            w = Int((Double(w) * f).rounded())
            h = Int((Double(h) * f).rounded())
        }
        if w % 2 != 0 { w += 1 }
        if h % 2 != 0 { h += 1 }
        return (max(2, w), max(2, h))
    }
}

// MARK: - AVWriter

/// Besitzt den AVAssetWriter und IST der Stream-Output. Läuft ausschließlich auf
/// der `sampleHandlerQueue` (seriell), `finish()` erst nachdem `stopCapture()`
/// die Zustellung beendet hat — damit ist @unchecked Sendable hier korrekt.
private final class AVWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput
    private let systemInput: AVAssetWriterInput?
    private var sessionStarted = false

    // MARK: Pause (01.08.)
    //
    // Der Stream laeuft waehrend der Pause weiter, wir verwerfen die Samples nur.
    // Danach muessen ALLE folgenden Zeitstempel um die Pausendauer nach vorn
    // gezogen werden, sonst steht im Video eine Luecke (eingefrorenes Bild) in
    // Laenge der Pause. Video und beide Tonspuren bekommen denselben Versatz,
    // damit sie synchron bleiben.
    private let lock = NSLock()
    private var paused = false
    private var pauseBeganAt: CMTime?
    private var timeOffset: CMTime = .zero

    func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard value != paused else { return }
        paused = value
        if value {
            pauseBeganAt = CMClockGetTime(CMClockGetHostTimeClock())
        } else if let began = pauseBeganAt {
            let gap = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), began)
            timeOffset = CMTimeAdd(timeOffset, gap)
            pauseBeganAt = nil
        }
    }

    init(url: URL, width: Int, height: Int, withSystemAudio: Bool) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // AVVideoProfileLevelKey MUSS in die CompressionProperties, auf der
            // obersten Ebene wirft AVAssetWriter eine NSException.
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // Grosszuegig: Bildschirminhalt ist ueberwiegend statisch, der
                // Encoder verbraucht das Budget ohnehin nur bei Bewegung (die
                // 1800er-Testaufnahme kam trotz 6 Mbit/s Ziel bei 1 Mbit/s raus).
                // Zu knapp wird dagegen sofort als matschige Schrift sichtbar.
                AVVideoAverageBitRateKey: max(4_000_000, width * height * 5),
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        micInput.expectsMediaDataInRealTime = true

        var sys: AVAssetWriterInput?
        if withSystemAudio {
            var s = audioSettings
            s[AVNumberOfChannelsKey] = 2
            s[AVEncoderBitRateKey] = 128_000
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: s)
            i.expectsMediaDataInRealTime = true
            sys = i
        }
        systemInput = sys

        super.init()
        if writer.canAdd(videoInput) { writer.add(videoInput) }
        if writer.canAdd(micInput) { writer.add(micInput) }
        if let sys, writer.canAdd(sys) { writer.add(sys) }
        guard writer.startWriting() else {
            throw ScreenRecorder.RecError.msg("Aufnahme konnte nicht gestartet werden: \(writer.error?.localizedDescription ?? "unbekannt")")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .screen:
            // Die Session MUSS am ersten Videoframe starten, sonst steht am
            // Anfang der Datei ein schwarzer Block in Länge des Audio-Vorlaufs.
            guard isCompleteFrame(sampleBuffer) else { return }
            append(sampleBuffer, to: videoInput, mayStartSession: true)
        case .audio:
            if let systemInput { append(sampleBuffer, to: systemInput, mayStartSession: false) }
        default:
            if #available(macOS 15.0, *), type == .microphone {
                append(sampleBuffer, to: micInput, mayStartSession: false)
            }
        }
    }

    /// SCStream liefert auch Frames ohne neuen Bildinhalt (z.B. nur Cursor-Bewegung
    /// oder verdeckte Bereiche). Die haben einen Status != .complete und würden
    /// als leere Frames in die Datei laufen.
    private func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false),
              let first = (arr as NSArray).firstObject as? NSDictionary,
              let raw = first[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput, mayStartSession: Bool) {
        guard writer.status == .writing else { return }

        lock.lock()
        let isPaused = paused
        let offset = timeOffset
        lock.unlock()
        guard !isPaused else { return }             // Pause: Sample verwerfen

        let sample: CMSampleBuffer
        if offset == .zero {
            sample = buffer
        } else if let shifted = Self.shift(buffer, by: offset) {
            sample = shifted
        } else {
            return                                   // lieber auslassen als verzerren
        }

        if !sessionStarted {
            guard mayStartSession else { return }   // Audio vor dem ersten Frame verwerfen
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(sample) }
    }

    /// Kopie des Samples mit um `offset` nach vorn gezogenem Zeitstempel.
    private static func shift(_ buffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0,
                                                     arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: .init(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count,
                                                     arrayToFill: &timings,
                                                     entriesNeededOut: &count) == noErr
        else { return nil }
        for i in 0..<count {
            timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                    sampleBuffer: buffer,
                                                    sampleTimingEntryCount: count,
                                                    sampleTimingArray: &timings,
                                                    sampleBufferOut: &out) == noErr
        else { return nil }
        return out
    }

    func finish() async {
        guard writer.status == .writing else { return }
        videoInput.markAsFinished()
        micInput.markAsFinished()
        systemInput?.markAsFinished()
        await writer.finishWriting()
    }
}
