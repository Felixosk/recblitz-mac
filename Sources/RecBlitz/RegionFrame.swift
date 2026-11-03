import AppKit
import BlitzKit

/// Dauerhafter Rahmen um den gewählten Aufnahme-Bereich (Armed + Aufnahme).
///
/// Der Rest des Bildschirms wird leicht abgedunkelt, der Bereich selbst bleibt
/// klar. Das Overlay ist click-through (`ignoresMouseEvents`) und darf NICHT im
/// Video landen: Die eigene App ist im ScreenRecorder per `excludingApplications`
/// ausgeschlossen, zusätzlich `sharingType = .none` als zweiter Gurt. Der Rahmen
/// liegt außerhalb des Bereichs, selbst ein Rest davon käme nicht ins Bild.
@MainActor
final class RegionFrame {
    static let shared = RegionFrame()
    private var panels: [NSPanel] = []

    var isVisible: Bool { !panels.isEmpty }

    /// Zeigt den Rahmen nur für einen Bereich (`.region`), sonst nichts.
    func show(for scope: CaptureScope) {
        hide()
        guard case .region(let rect, let displayID) = scope else { return }
        for screen in NSScreen.screens {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            let view = DimView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.hole = (id == displayID) ? rect : nil
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            // Eine Stufe unter Steuerleiste, Blase und Vorlauf (.screenSaver),
            // damit die nicht mit abgedunkelt werden.
            p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.sharingType = .none
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.contentView = view
            p.setFrame(screen.frame, display: false)
            p.orderFrontRegardless()
            panels.append(p)
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

private final class DimView: NSView {
    /// Bereich in Punkten, Ursprung oben links (wie `sourceRect`).
    var hole: CGRect?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let h = hole { dim.append(NSBezierPath(rect: h)) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(hole == nil ? 0.22 : 0.34).setFill()
        dim.fill()
        guard let h = hole else { return }
        // Rahmen komplett AUSSERHALB des Bereichs.
        let line: CGFloat = 2
        let ring = NSBezierPath(rect: h.insetBy(dx: -line, dy: -line))
        ring.append(NSBezierPath(rect: h))
        ring.windingRule = .evenOdd
        Theme.accentNS.withAlphaComponent(0.95).setFill()
        ring.fill()
    }
}
