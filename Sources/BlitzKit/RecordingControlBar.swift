import AppKit
import SwiftUI

/// Schwebende Steuerleiste während der Bildschirmaufnahme (Rückmeldung 01.08.:
/// "ein Button an der Seite, wo ich pausieren, abbrechen oder neu starten kann,
/// so wie Loom").
///
/// **Warum nicht einfach das Menüleisten-Panel:** das muss man erst mit einem
/// Klick oben aufklappen, während man mitten in der Erklärung ist. Die Leiste
/// liegt dagegen die ganze Zeit sichtbar unten links.
///
/// Sie gehört der aufnehmenden App und ist damit automatisch aus der Aufnahme
/// ausgeschlossen (`excludingApplications` im ScreenRecorder) — sie steht also
/// nicht im fertigen Video.
@MainActor
public final class RecordingControlBar {
    public static let shared = RecordingControlBar()

    private var panel: NSPanel?
    /// Für das Nachmessen beim Zustandswechsel — der Bereit-Zustand ist
    /// schmaler als der Aufnahme-Zustand.
    private var hosting: NSView?
    private let model = ControlBarModel()

    private init() {}

    public var isVisible: Bool { panel?.isVisible ?? false }

    /// `armed` = Vorbereitungs-Zustand: alles steht (Ausschnitt gewählt, Webcam
    /// platziert), aber es wird noch NICHT aufgenommen. Erst der Play-Knopf
    /// löst den Vorlauf aus. Rückmeldung 01.08.: "dass ich dann noch play drücke und
    /// dann kommt der Timer, damit ich mich ready machen kann".
    public func show(on screen: NSScreen?,
                     armed: Bool = false,
                     onStart: @escaping () -> Void = {},
                     onTogglePause: @escaping () -> Void,
                     onRestart: @escaping () -> Void,
                     onDiscard: @escaping () -> Void,
                     onStop: @escaping () -> Void) {
        hide()
        model.elapsed = 0
        model.paused = false
        model.armed = armed
        model.onStart = onStart
        model.onTogglePause = onTogglePause
        model.onRestart = onRestart
        model.onDiscard = onDiscard
        model.onStop = onStop

        let host = OverlayHosting(rootView: ControlBarView(model: model))
        host.layoutSubtreeIfNeeded()
        let size = CGSize(width: max(260, host.fittingSize.width), height: 52)
        host.frame = CGRect(origin: .zero, size: size)
        hosting = host

        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        // Kein Fensterschatten: er zeichnete auf hellem Untergrund einen harten
        // dunklen Ring um die Leiste, die dadurch nach Plastik statt Glas aussah
        // (Rückmeldung 01.08.: "das ist beides nicht liquid glass").
        p.hasShadow = false
        p.level = .screenSaver              // auch über Vollbild-Apps sichtbar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true   // aus dem Weg schiebbar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = host

        // Unten links auf dem aufgenommenen Bildschirm, wie bei Loom.
        let vf = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        p.setFrameOrigin(NSPoint(x: (vf.minX + 24).rounded(), y: (vf.minY + 24).rounded()))
        p.orderFrontRegardless()
        panel = p
    }

    /// Jede Sekunde vom Timer der App gefüttert.
    public func update(elapsed: TimeInterval, paused: Bool) {
        model.elapsed = elapsed
        model.paused = paused
    }

    /// Vom Vorbereitungs- in den Aufnahme-Zustand wechseln, ohne die Leiste neu
    /// aufzubauen — sie soll dort stehen bleiben, wo der Nutzer sie hingeschoben hat.
    /// Wechselt den Zustand und passt die BREITE an. Ohne das Nachmessen blieb
    /// das Fenster auf der Breite des Bereit-Zustands stehen und schnitt im
    /// Aufnahme-Zustand den Fertig-Knopf ab (Rückmeldung 01.08.: "der Stopp-Button
    /// schaut komisch aus").
    public func setArmed(_ armed: Bool) {
        model.armed = armed
        guard let p = panel, let host = hosting else { return }
        // Erst im nächsten Durchlauf messen: SwiftUI hat das neue Layout sonst
        // noch nicht gerechnet.
        DispatchQueue.main.async {
            host.layoutSubtreeIfNeeded()
            let w = max(260, host.fittingSize.width)
            guard abs(w - p.frame.width) > 1 else { return }
            // Linke Kante bleibt stehen, die Leiste soll nicht wegspringen.
            p.setFrame(CGRect(x: p.frame.minX, y: p.frame.minY, width: w, height: 52),
                       display: true)
            host.frame = CGRect(x: 0, y: 0, width: w, height: 52)
        }
    }

    /// Gehört dieses Fenster der Leiste? Klicks darauf dürfen das Menüleisten-
    /// Panel nicht schließen.
    public func owns(_ window: NSWindow?) -> Bool {
        window != nil && window === panel
    }

    public func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

@MainActor
private final class ControlBarModel: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var paused = false
    @Published var armed = false
    var onStart: () -> Void = {}
    var onTogglePause: () -> Void = {}
    var onRestart: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onStop: () -> Void = {}
}

private struct ControlBarView: View {
    @ObservedObject var model: ControlBarModel

    private var timeString: String {
        let s = Int(model.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        Group {
            if model.armed { readyBar } else { recordingBar }
        }
        .padding(.horizontal, 13)
        .frame(height: 52)
        .modifier(GlassBackground(corner: 26))
        .compositingGroup()
    }

    /// Bereit-Zustand: nichts läuft, alles ist platziert.
    private var readyBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Bereit")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Divider().frame(height: 20).overlay(Color.primary.opacity(0.2))

            BarButton(icon: "xmark", help: "Abbrechen",
                      tint: .primary, action: model.onDiscard)

            Button(action: model.onStart) {
                HStack(spacing: 5) {
                    Image(systemName: "record.circle.fill").font(.system(size: 12, weight: .bold))
                    Text("Aufnehmen").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.red))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var recordingBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.paused ? Color.orange : Color.red)
                .frame(width: 9, height: 9)
                // Blinken nur beim Aufnehmen, in Pause steht der Punkt still.
                .opacity(model.paused ? 1 : 0.95)
            Text(timeString)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                // .primary statt .white: Glas nimmt den Hintergrund auf, auf
                // hellem Untergrund war weiße Schrift unlesbar (01.08.).
                .foregroundStyle(.primary)
                .frame(minWidth: 42, alignment: .leading)

            Divider().frame(height: 20).overlay(Color.primary.opacity(0.2))

            BarButton(icon: model.paused ? "play.fill" : "pause.fill",
                      help: model.paused ? "Weiter" : "Pause",
                      tint: model.paused ? .orange : .primary,
                      action: model.onTogglePause)
            BarButton(icon: "arrow.counterclockwise", help: "Neu starten",
                      tint: .primary, action: model.onRestart)
            BarButton(icon: "trash", help: "Verwerfen",
                      tint: .primary, action: model.onDiscard)

            Button(action: model.onStop) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                    Text("Fertig").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.red))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct BarButton: View {
    let icon: String
    let help: String
    let tint: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hovered ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
