import AppKit
import AVFoundation
import SwiftUI

/// Runde Webcam-Blase, die während der Bildschirmaufnahme mitläuft.
///
/// **Der Trick, warum das billig ist:** Die Blase wird NICHT ins Video
/// hineingerechnet. Wir schließen ohnehin alle eigenen Fenster aus der Aufnahme
/// aus; für dieses eine Fenster machen wir per `exceptingWindows` eine Ausnahme.
/// ScreenCaptureKit nimmt es dadurch ganz normal mit auf. Kein Compositing,
/// kein zweiter Videostream, keine zwei Uhren, die auseinanderlaufen können.
///
/// **Optik, dritter Anlauf (01.08.):** Das Kamerabild sitzt als Kreis AUF einer
/// Glasscheibe, so war es gewünscht. Die ersten beiden Versuche scheiterten an
/// AppKit: `NSGlassEffectView` als Container mit eingerücktem Inhalt ergab einen
/// grauen Donut, und als Subview deckt Glas den eigenen Inhalt zu. In SwiftUI
/// ist `.glassEffect` ein Hintergrund-Modifier — damit stimmt die Schichtung.
@MainActor
public final class WebcamBubble {
    public static let shared = WebcamBubble()

    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private let model = BubbleModel()
    /// Verfolgt den Mauszeiger app-übergreifend. Nötig, weil ein
    /// nonactivating-Panel einer Hintergrund-App keine verlässlichen
    /// Hover-Ereignisse bekommt — das × erschien deshalb nie (Rückmeldung 01.08.).
    private var hoverMonitor: Any?

    /// Wird gerufen, wenn der Nutzer die Blase über ihr × schließt — die App schaltet
    /// darüber auch den Schalter aus, sonst käme sie sofort wieder.
    public var onClose: (() -> Void)?

    private init() {}

    public var isVisible: Bool { panel?.isVisible ?? false }

    /// Fenster-ID der Blase, damit der Recorder sie in die Aufnahme
    /// hineinnehmen kann. nil wenn sie nicht läuft.
    public var windowID: CGWindowID? {
        guard let p = panel, p.isVisible, p.windowNumber > 0 else { return nil }
        return CGWindowID(p.windowNumber)
    }

    /// Gehört dieses Fenster der Blase? Klicks darauf (Verschieben!) dürfen das
    /// Menüleisten-Panel nicht schließen.
    public func owns(_ window: NSWindow?) -> Bool {
        window != nil && window === panel
    }

    public static func cameraAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    public static func requestCameraAccess() async -> Bool {
        if cameraAuthorized() { return true }
        return await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Zeigt die Blase unten rechts auf `screen`. Wirft nicht — ohne Kamera oder
    /// ohne Erlaubnis passiert schlicht nichts, die Aufnahme läuft trotzdem.
    @discardableResult
    public func show(on screen: NSScreen?, diameter: CGFloat = 160) async -> Bool {
        hide()
        guard await Self.requestCameraAccess() else {
            NSLog("WebcamBubble: keine Kamera-Erlaubnis")
            return false
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
            NSLog("WebcamBubble: keine Kamera gefunden")
            return false
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            NSLog("WebcamBubble: Kamera '%@' nicht nutzbar: %@",
                  device.localizedName, error.localizedDescription)
            return false
        }

        let s = AVCaptureSession()
        s.beginConfiguration()
        s.sessionPreset = .high
        guard s.canAddInput(input) else {
            s.commitConfiguration()
            NSLog("WebcamBubble: Eingang nicht hinzufuegbar (%@)", device.localizedName)
            return false
        }
        s.addInput(input)
        s.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: s)
        preview.videoGravity = .resizeAspectFill      // füllt den Kreis randlos
        // Spiegeln: man erwartet sich selbst wie im Spiegel, nicht seitenverkehrt.
        if let conn = preview.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }

        model.hovering = false
        model.onClose = { [weak self] in
            self?.hide()
            self?.onClose?()
        }

        // Glasrand rundum: Gesamtgröße = Kamerakreis + 2 × Rand.
        // Nur ein schmaler Glassaum, kein Ring (Rückmeldung 01.08.: "dass der Rand
        // wirklich nur ein paar mm ist").
        let rim: CGFloat = 5
        let total = diameter + rim * 2
        let size = CGSize(width: total, height: total)

        let host = OverlayHosting(rootView: BubbleView(model: model,
                                                       preview: preview,
                                                       camera: diameter,
                                                       rim: rim))
        host.frame = CGRect(origin: .zero, size: size)

        let p = BubblePanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        // Kein Fensterschatten: der zeichnete auf hellem Untergrund einen harten
        // dunklen Ring um das Glas, genau der "sieht nicht nach Glas aus"-Effekt.
        p.hasShadow = false
        p.level = .screenSaver
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true      // frei verschiebbar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = host

        // Unten rechts — gegenüber der Steuerleiste, die unten links sitzt.
        let vf = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        p.setFrameOrigin(NSPoint(x: (vf.maxX - total - 28).rounded(),
                                 y: (vf.minY + 28).rounded()))
        p.orderFrontRegardless()

        panel = p
        session = s
        installHoverMonitor()

        // startRunning blockiert — gehört NICHT auf den Main-Actor, sonst
        // ruckelt die UI beim Einblenden.
        let sessionRef = s
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                sessionRef.startRunning()
                c.resume()
            }
        }
        return true
    }

    /// Globaler Mausmonitor statt NSTrackingArea: eine Hintergrund-App bekommt
    /// für ein nonactivating-Panel keine verlässlichen Enter/Exit-Ereignisse,
    /// das × wäre sonst nie zu sehen.
    private func installHoverMonitor() {
        removeHoverMonitor()
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]) { _ in
                Task { @MainActor in WebcamBubble.shared.updateHover() }
            }
    }

    private func removeHoverMonitor() {
        if let m = hoverMonitor { NSEvent.removeMonitor(m) }
        hoverMonitor = nil
    }

    private func updateHover() {
        guard let p = panel, p.isVisible else { return }
        let inside = p.frame.contains(NSEvent.mouseLocation)
        if inside != model.hovering { model.hovering = inside }
    }

    public func hide() {
        removeHoverMonitor()
        session?.stopRunning()
        session = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

@MainActor
private final class BubbleModel: ObservableObject {
    @Published var hovering = false
    var onClose: () -> Void = {}
}

/// Der Kamerakreis auf einer Glasscheibe, plus × zum Schließen.
private struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    let preview: AVCaptureVideoPreviewLayer
    let camera: CGFloat
    let rim: CGFloat

    var body: some View {
        PreviewRepresentable(layer: preview)
            .frame(width: camera, height: camera)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .padding(rim)
            .modifier(GlassBackground(corner: (camera + rim * 2) / 2, clear: true))
            .overlay(alignment: .topTrailing) {
                if model.hovering {
                    Button(action: model.onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.black.opacity(0.68)))
                            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Webcam ausblenden")
                }
            }
    }
}

/// Bringt den AVCaptureVideoPreviewLayer nach SwiftUI. Der Layer skaliert nicht
/// von selbst mit seiner View, deshalb wird sein Frame in `layout()` gesetzt.
private struct PreviewRepresentable: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView { PreviewHost(layer: layer) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class PreviewHost: NSView {
        private let preview: AVCaptureVideoPreviewLayer
        init(layer: AVCaptureVideoPreviewLayer) {
            preview = layer
            super.init(frame: .zero)
            wantsLayer = true
            self.layer?.backgroundColor = NSColor.black.cgColor
            self.layer?.addSublayer(preview)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
        }
    }
}
