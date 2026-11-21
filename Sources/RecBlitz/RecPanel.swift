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

/// Fenster ohne Rand: die durchsichtige Bühne darf ueber die Menueleiste ragen (das Glas steht darunter),
/// und es kann auf Klick Tastaturfokus bekommen (Esc schliesst). Falle 13 + Runde 110b.
final class StagePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
}

/// Fensterhoehe des Panels fuer die SwiftUI-Wurzel (oben verankert, ohne Animation gesetzt).
@MainActor
final class PanelLayout: ObservableObject {
    static let shared = PanelLayout()
    @Published var height: CGFloat?
    func set(_ h: CGFloat?) {
        guard height != h else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { height = h }
    }
}

/// Dropdown-Panel unterm Menüleisten-Icon: Liquid Glass als SwiftUI-Hintergrund IM Inhalt, rundum eine
/// durchsichtige Buehne (`Theme.stageInset`), Ebene `.floating`, nonactivating, schliesst bei Klick ausserhalb
/// des Glases. Architektur wie MeetingBlitz `WidgetPanel` (Runde 110-118).
@MainActor
final class PanelController {
    static let shared = PanelController()
    private var panel: NSPanel?
    private var anchorX: CGFloat = 0
    private var topY: CGFloat = 0
    private var dismissMonitors: [Any] = []
    private weak var statusWindow: NSWindow?
    private var lastNatural: CGSize?
    private var pendingShrink: DispatchWorkItem?

    static var stage: CGFloat { Theme.stageInset }
    var isOpen: Bool { panel?.isVisible ?? false }
    /// Fensterrahmen samt Buehne.
    var frame: CGRect? { panel?.frame }
    /// Glas-Rahmen (Andockmass fuer die Einstellungen).
    var glassFrame: CGRect? { frame?.insetBy(dx: Self.stage, dy: Self.stage) }

    func toggle(state: AppState, statusButton: NSStatusBarButton?, screen demoScreen: NSScreen? = nil) {
        if isOpen { close(); return }

        let host = FirstMouseHostingView(rootView: RecPanelView(state: state, onSize: { size in
            DispatchQueue.main.async { MainActor.assumeIsolated { PanelController.shared.resize(to: size) } }
        }))
        host.safeAreaRegions = []   // die Buehne ragt ueber die Menueleiste
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let p = StagePanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = Theme.systemShadow
        p.isFloatingPanel = true
        p.level = .floating          // NACH isFloatingPanel: das setzt die Ebene still zurueck (Falle 11)
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host

        if let bf = statusButton?.window?.frame {
            anchorX = bf.midX
            topY = bf.minY - 5
        } else {
            let vf = (demoScreen ?? NSScreen.main)?.visibleFrame ?? .zero
            anchorX = vf.maxX - 220
            topY = vf.maxY - 5
        }
        statusWindow = statusButton?.window
        panel = p
        lastNatural = size
        place(size: size)
        // Einblenden erst nach dem ersten Zeichnen (sonst ein Bild in falscher Groesse).
        p.alphaValue = 0
        p.orderFrontRegardless()
        installDismissMonitors()
        p.contentView?.layoutSubtreeIfNeeded()
        p.displayIfNeeded()
        DispatchQueue.main.async { [weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .linear)
                p.animator().alphaValue = 1
            }
        }
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        // Globaler Monitor: Klicks in FREMDE Apps schliessen das Panel. Klicks in eigene Fenster (Glas) und in
        // unsere schwebenden Elemente (Webcam-Blase, Steuerleiste, Vorlauf) nicht. Geprueft wird gegen den
        // GLAS-Rahmen (Fenster minus Buehne), nicht gegen den Fensterrahmen.
        let measuring = Demo.on
        let g = measuring ? nil : NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                let m = NSEvent.mouseLocation
                let own = [PanelController.shared.panel?.frame, SettingsPanelController.shared.frame]
                if own.contains(where: { $0.map { $0.insetBy(dx: Theme.stageInset, dy: Theme.stageInset).contains(m) } ?? false }) { return }
                guard !PanelController.ownsFloatingElement(under: m) else { return }
                PanelController.shared.close()
            }
        }
        let l = measuring ? nil : NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
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
        // Esc schliesst, solange das Panel Tastaturfokus hat (nach einem Klick hinein).
        let esc = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            var hit = false
            MainActor.assumeIsolated {
                if event.keyCode == 53, event.window === PanelController.shared.panel {
                    PanelController.shared.close(); hit = true
                }
            }
            return hit ? nil : event
        }
        dismissMonitors = [g, l, esc].compactMap { $0 }
    }

    /// Liegt an dieser Bildschirmposition eines unserer schwebenden Elemente?
    /// Der GLOBALE Monitor bekommt kein `event.window` geliefert (das Ereignis
    /// gehoert einer fremden App), deshalb ueber die Fensterrahmen pruefen.
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

    /// Inhalt hat eine neue natuerliche Groesse gemeldet (am Glas samt Buehne gemessen).
    func resize(to size: CGSize) {
        guard let p = panel, p.isVisible, size.width > 1, size.height > 1 else { return }
        lastNatural = size
        place(size: size)
    }

    /// Oberkante des Glases bleibt fest, gewachsen wird nach unten. Wachsen sofort, Schrumpfen erst nach der
    /// Klapp-Feder (`Theme.foldSettle`): abgeschnitten wird nur Luft.
    private func place(size: CGSize) {
        guard let p = panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchorX, y: topY - 1)) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchorX - size.width / 2
        x = min(max(x, vf.minX + 4 - Self.stage), vf.maxX - size.width - 4 + Self.stage)
        let y = topY + Self.stage - size.height
        let rect = CGRect(x: x.rounded(), y: y.rounded(),
                          width: size.width.rounded(.up), height: size.height.rounded(.up))
        pendingShrink?.cancel(); pendingShrink = nil
        if rect.height < p.frame.height - 0.5, rect.width == p.frame.width {
            let w = DispatchWorkItem { [weak self, weak p] in
                guard let self, let p else { return }
                p.setFrame(rect, display: true)
                PanelLayout.shared.set(rect.height)
                p.invalidateShadow()
                self.alignSettings()
            }
            pendingShrink = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.foldSettle, execute: w)
        } else {
            p.setFrame(rect, display: true)
            PanelLayout.shared.set(rect.height)
            p.invalidateShadow()
            alignSettings()
        }
    }

    private func alignSettings() {
        if let g = glassFrame { SettingsPanelController.shared.alignToPanel(g) }
    }

    func close(fade: Double = 0.15) {
        removeDismissMonitors()
        pendingShrink?.cancel(); pendingShrink = nil
        lastNatural = nil
        PanelLayout.shared.set(nil)
        SettingsPanelController.shared.close()   // Settings nicht verwaisen lassen
        if let p = panel {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fade
                ctx.timingFunction = CAMediaTimingFunction(name: .linear)
                p.animator().alphaValue = 0
            } completionHandler: {
                p.orderOut(nil)
                p.contentView = nil
            }
        }
        panel = nil
    }
}
