import AppKit

/// Zieh-Auswahl für "Bereich aufnehmen": legt ein halbtransparentes Panel über
/// jeden Bildschirm, der Nutzer zieht ein Rechteck auf, Escape bricht ab.
///
/// **Warum selbst gebaut und nicht `SCContentSharingPicker`:** Apples System-Picker
/// kann Bildschirm, Fenster und App auswählen, aber KEINEN freien Ausschnitt.
/// Für "wie groß soll die Aufnahme sein" braucht es genau das.
@MainActor
public enum RegionPicker {

    /// Zeigt die Auswahl. `completion` bekommt das Rechteck in Punkten relativ
    /// zum Ursprung des gewählten Bildschirms (so erwartet es `sourceRect`)
    /// **plus die displayID dieses Bildschirms**, oder nil bei Abbruch.
    ///
    /// Die displayID muss mit zurück: sonst würde ein auf Screen 2 aufgezogener
    /// Bereich später vom Hauptbildschirm aufgenommen (Rückmeldung 31.07.).
    public static func pick(completion: @escaping ((rect: CGRect, displayID: CGDirectDisplayID)?) -> Void) {
        var panels: [OverlayPanel] = []

        let finish: ((rect: CGRect, displayID: CGDirectDisplayID)?) -> Void = { result in
            panels.forEach { $0.orderOut(nil) }
            panels.removeAll()
            completion(result)
        }

        for screen in NSScreen.screens {
            let p = OverlayPanel(screen: screen, onResult: finish)
            panels.append(p)
            p.orderFrontRegardless()
        }
        // Ohne aktivierte App kommen keine Key-Events (Escape) an.
        NSApp.activate(ignoringOtherApps: true)
        panels.first?.makeKey()
    }
}

private final class OverlayPanel: NSPanel {
    private let onResult: ((rect: CGRect, displayID: CGDirectDisplayID)?) -> Void
    private let view: SelectionView

    init(screen: NSScreen, onResult: @escaping ((rect: CGRect, displayID: CGDirectDisplayID)?) -> Void) {
        self.onResult = onResult
        self.view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = view

        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                         as? CGDirectDisplayID) ?? CGMainDisplayID()

        view.onFinish = { localRect in
            guard let r = localRect, r.width > 8, r.height > 8 else { onResult(nil); return }
            // Panel-lokal (y unten) → bildschirm-lokal in Punkten mit y OBEN,
            // denn genau so erwartet SCStreamConfiguration.sourceRect den Wert.
            let flipped = CGRect(x: r.minX,
                                 y: screen.frame.height - r.maxY,
                                 width: r.width, height: r.height)
            onResult((rect: flipped, displayID: displayID))
        }
        view.onCancel = { onResult(nil) }
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onResult(nil) } else { super.keyDown(with: event) }
    }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    var onCancel: (() -> Void)?

    private var origin: CGPoint?
    private var current: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        current = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let o = origin else { return }
        let p = convert(event.locationInWindow, from: nil)
        current = CGRect(x: min(o.x, p.x), y: min(o.y, p.y),
                         width: abs(p.x - o.x), height: abs(p.y - o.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { origin = nil }
        onFinish?(current)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard current.width > 0, current.height > 0 else {
            drawHint()
            return
        }
        // Auswahl freistellen, damit man sieht was man aufnimmt.
        NSColor.clear.setFill()
        current.fill(using: .copy)

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: current)
        border.lineWidth = 2
        border.stroke()

        let label = "\(Int(current.width)) × \(Int(current.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let box = CGRect(x: current.minX, y: max(0, current.minY - size.height - 8),
                         width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        (label as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }

    private func drawHint() {
        let hint = "Bereich aufziehen · Escape bricht ab"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let size = (hint as NSString).size(withAttributes: attrs)
        (hint as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2,
                                            y: bounds.midY - size.height / 2),
                                withAttributes: attrs)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}
