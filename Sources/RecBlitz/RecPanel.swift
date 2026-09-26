import AppKit
import SwiftUI
import BlitzKit

/// Erster Klick zählt sofort (auch wenn die App nicht aktiv ist) und die
/// Hosting-View malt nie einen eigenen opaken Hintergrund. (MeetingBlitz-Muster)
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

/// Dropdown-Panel unterm Menüleisten-Icon im MeetingBlitz-Stil:
/// NSVisualEffectView (.popover, .active) + Masken-Ecken, nonactivating,
/// schließt bei Klick außerhalb. (Architektur aus MeetingBlitz WidgetPanel)
@MainActor
final class PanelController {
    static let shared = PanelController()
    private var panel: NSPanel?
    private var anchorX: CGFloat = 0
    private var topY: CGFloat = 0
    private var dismissMonitors: [Any] = []
    private weak var statusWindow: NSWindow?

    var isOpen: Bool { panel?.isVisible ?? false }
    var frame: CGRect? { panel?.frame }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func toggle(state: AppState, statusButton: NSStatusBarButton?) {
        if isOpen { close(); return }

        let host = FirstMouseHostingView(rootView: RecPanelView(state: state, onSize: { size in
            Task { @MainActor in PanelController.shared.resize(to: size) }
        }))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        // Dasselbe Material wie das MeetingBlitz-Widget: echtes
        // NSVisualEffectView, auf `.active` festgenagelt. Die App ist nie die
        // aktive, ohne das fiele das Material auf seinen flachen inaktiven Look
        // zurück. Ecken per Maskenbild, sonst bleiben helle Säume an den Ecken.
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.maskImage = Self.roundedMask(radius: 13)
        v.frame = CGRect(origin: .zero, size: size)
        host.frame = v.bounds
        host.autoresizingMask = [.width, .height]
        v.addSubview(host)
        let effect: NSView = v

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = effect

        if let bf = statusButton?.window?.frame {
            anchorX = bf.midX
            topY = bf.minY - 5
        } else {
            let vf = NSScreen.main?.visibleFrame ?? .zero
            anchorX = vf.maxX - 220
            topY = vf.maxY - 5
        }
        statusWindow = statusButton?.window
        panel = p
        place(size: size)
        p.orderFrontRegardless()
        installDismissMonitors()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        // Globaler Monitor: Klicks in FREMDE Apps schließen das Panel. Klicks in
        // unsere eigenen schwebenden Elemente (Webcam-Blase verschieben,
        // Steuerleiste bedienen, Vorlauf überspringen) dürfen das NICHT — das
        // Panel ging sonst beim Platzieren der Blase zu (01.08.).
        let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                guard !PanelController.ownsFloatingElement(under: NSEvent.mouseLocation) else { return }
                PanelController.shared.close()
            }
        }
        let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                let w = event.window
                let keepOpen = w === PanelController.shared.panel
                    || SettingsPanelController.shared.owns(w)
                    || w === PanelController.shared.statusWindow
                    || WebcamBubble.shared.owns(w)
                    || RecordingControlBar.shared.owns(w)
                    || CountdownOverlay.owns(w)
                if !keepOpen { PanelController.shared.close() }
            }
            return event
        }
        dismissMonitors = [g, l].compactMap { $0 }
    }

    /// Liegt an dieser Bildschirmposition eines unserer schwebenden Elemente?
    /// Der GLOBALE Monitor bekommt kein `event.window` geliefert (das Ereignis
    /// gehört einer fremden App), deshalb über die Fensterrahmen prüfen.
    static func ownsFloatingElement(under point: CGPoint) -> Bool {
        for w in NSApp.windows where w.isVisible {
            guard WebcamBubble.shared.owns(w)
                    || RecordingControlBar.shared.owns(w)
                    || CountdownOverlay.owns(w) else { continue }
            if w.frame.contains(point) { return true }
        }
        return false
    }

    private func removeDismissMonitors() {
        for m in dismissMonitors { NSEvent.removeMonitor(m) }
        dismissMonitors = []
    }

    func resize(to size: CGSize) {
        guard let p = panel, p.isVisible else { return }
        place(size: size)
    }

    private func place(size: CGSize) {
        guard let p = panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchorX, y: topY - 1)) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchorX - size.width / 2
        x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        let y = topY - size.height
        p.setFrame(CGRect(x: x.rounded(), y: y.rounded(),
                          width: size.width.rounded(.up), height: size.height.rounded(.up)),
                   display: true)
        p.invalidateShadow()
    }

    func close() {
        removeDismissMonitors()
        SettingsPanelController.shared.close()   // Settings nicht verwaisen lassen
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

