import AppKit
import SwiftUI

/// Kurzer Vorlauf vor der Bildschirmaufnahme.
///
/// **Warum:** Ohne Vorlauf beginnt die Aufnahme in dem Moment, in dem der Button
/// gedrückt wird — das schließende Panel und das Navigieren zum richtigen
/// Fenster stehen dann im Video.
///
/// **Warum SwiftUI und nicht selbst gezeichnet:** Der erste Versuch malte Zahl
/// und Beschriftung in `draw(_:)` und legte `NSGlassEffectView`s als Subviews
/// dazu. In AppKit zeichnen Subviews IMMER über dem eigenen `draw()` — das Glas
/// hat den Text also zugedeckt, sichtbar blieb ein grauer Kreis ohne Zahl
/// (Rückmeldung 01.08.). Mit `.glassEffect` als Hintergrund-Modifier liegt die
/// Schrift garantiert oben.
@MainActor
public enum CountdownOverlay {

    private static var panels: [NSPanel] = []
    /// Der laufende Timer. MUSS hier liegen, nicht nur lokal in `run`:
    /// `dismiss()` von außen (Abbrechen während des Vorlaufs) hat den Timer
    /// sonst NICHT gestoppt — er lief weiter und startete danach eine Aufnahme,
    /// die niemand mehr wollte und die auch keine Steuerleiste mehr hatte.
    private static var timer: Timer?
    private static let model = CountdownModel()

    /// Zählt `seconds` herunter und ruft dann `completion`. Escape bricht ab
    /// (`onCancel`), Klick/Leertaste/Return überspringt (`completion`).
    public static func run(seconds: Int,
                           on screen: NSScreen? = nil,
                           onCancel: (() -> Void)? = nil,
                           completion: @escaping () -> Void) {
        guard seconds > 0 else { completion(); return }
        dismiss()

        let target = screen ?? NSScreen.main
        guard let target else { completion(); return }

        model.value = seconds

        let size = CGSize(width: 220, height: 252)
        let f = target.frame
        let p = CountdownPanel(contentRect: CGRect(x: f.midX - size.width / 2,
                                                   y: f.midY - size.height / 2,
                                                   width: size.width, height: size.height),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        p.level = .screenSaver          // über allem, auch über Vollbild-Apps
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = false    // Überspringen ist anklickbar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = OverlayHosting(rootView: CountdownView(model: model))
        host.frame = CGRect(origin: .zero, size: size)
        p.contentView = host
        p.orderFrontRegardless()
        panels = [p]

        var remaining = seconds
        // `.common` mode: sonst steht der Timer, sobald irgendwo ein Menü offen ist.
        let t0 = Timer(timeInterval: 1.0, repeats: true) { t in
            Task { @MainActor in
                remaining -= 1
                if remaining <= 0 {
                    t.invalidate()
                    dismiss()
                    completion()
                } else {
                    model.value = remaining
                }
            }
        }
        timer = t0
        RunLoop.main.add(t0, forMode: .common)

        let skip = { dismiss(); completion() }       // dismiss stoppt den Timer mit
        model.onSkip = skip
        p.onSkip = skip
        p.onEscape = { dismiss(); onCancel?() }
        p.makeKeyAndOrderFront(nil)
    }

    /// Blendet aus UND stoppt den Vorlauf. Beides gehört zusammen.
    public static func dismiss() {
        timer?.invalidate()
        timer = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    /// Läuft gerade ein Vorlauf?
    public static var isRunning: Bool { timer != nil }

    /// Gehört dieses Fenster dem Vorlauf? Fürs Dismiss-Monitoring der App.
    public static func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return panels.contains { $0 === window }
    }
}

private final class CountdownPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onSkip: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:            onEscape?()          // Escape = abbrechen
        case 49, 36, 76:    onSkip?()            // Leertaste / Return = sofort los
        default:            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class CountdownModel: ObservableObject {
    @Published var value: Int = 3
    var onSkip: () -> Void = {}
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        VStack(spacing: 14) {
            Text("\(model.value)")
                .font(.system(size: 76, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 168, height: 168)
                .modifier(GlassBackground(corner: 84))
                .contentShape(Circle())
                .onTapGesture(perform: model.onSkip)

            Button(action: model.onSkip) {
                Text("Überspringen ⏎")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .modifier(GlassBackground(corner: 16))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
