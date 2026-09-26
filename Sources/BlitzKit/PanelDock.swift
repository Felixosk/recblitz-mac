import AppKit

// Aus MeetingBlitz (Runde 47g-47i) nach BlitzKit gezogen, damit RecBlitz
// dieselbe Platzierung benutzt statt einer zweiten Kopie (01.08.).

/// Wo die Begleit-Panels (Einstellungen, „Neues Meeting") landen (Runde 47g).
///
/// **Vorher:** mittig UNTER dem Widget. Das Widget hängt an der Menüleiste und
/// ist mit Timeline, Agenda und Erinnerungen selbst schnell ~500pt hoch —
/// darunter bleiben von ~1140pt sichtbarer Höhe nur noch ~600pt. Sobald im
/// „Neues Meeting"-Panel ein Abschnitt aufklappte (benutzerdefinierte
/// Wiederholung, Kalenderliste), rutschte der Erstellen-Button unter den
/// Bildschirmrand. Genau das wurde dreimal gemeldet — die Höhe des Formulars
/// war nie das eigentliche Problem, sondern der Platz, den wir ihm gegeben haben.
///
/// **Jetzt:** NEBEN dem Widget, oben bündig — dort steht die volle
/// Bildschirmhöhe zur Verfügung. Links zuerst (das Widget klebt oben rechts),
/// sonst rechts daneben, sonst wie früher mittig darunter. Zusätzlich klemmt
/// `clampY` das Panel immer vollständig in den sichtbaren Bereich, auch beim
/// Wachsen.
public enum PanelDock {

    /// Ursprung (unten links, AppKit-Koordinaten) für ein Panel dieser Größe.
    public static func origin(panelSize: CGSize, anchor: CGRect?, gap: CGFloat = 10) -> NSPoint {
        guard let a = anchor else {
            let m = NSEvent.mouseLocation
            return NSPoint(x: (m.x - panelSize.width / 2).rounded(),
                           y: (m.y - panelSize.height - 24).rounded())
        }
        let vf = visibleFrame(containing: a) ?? a

        var x = a.minX - panelSize.width - gap                 // links daneben
        if x < vf.minX + 8 {
            let right = a.maxX + gap                            // sonst rechts daneben
            x = (right + panelSize.width <= vf.maxX - 8) ? right : a.midX - panelSize.width / 2
        }
        x = min(max(x, vf.minX + 8), vf.maxX - panelSize.width - 8)

        // Oben bündig mit dem Widget, dann in den sichtbaren Bereich klemmen.
        let y = clampY(a.maxY - panelSize.height, height: panelSize.height, vf: vf)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    /// Hält das Panel vollständig im sichtbaren Bereich. Ist es höher als der
    /// Bildschirm (Notfall), gewinnt die Unterkante — dort sitzt der Button.
    public static func clampY(_ y: CGFloat, height: CGFloat, vf: CGRect) -> CGFloat {
        let lo = vf.minY + 8
        let hi = vf.maxY - height - 8
        return hi < lo ? lo : min(max(y, lo), hi)
    }

    public static func visibleFrame(containing rect: CGRect) -> CGRect? {
        (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame
    }

    // MARK: - Gemerkte Position (Runde 47h)

    /// Gemeldet mit zwei Screenshots: „so ist es" (neben dem Widget) und
    /// „so sollte es sein" (weiter links, tiefer). Die zweite Position war von
    /// Hand hingezogen — die kann keine Formel raten. Also merkt sich die App
    /// jetzt, wohin er ein Panel schiebt: einmal ziehen, danach öffnet es immer
    /// dort. Der Automatik-Platz neben dem Widget bleibt nur die Vorgabe fürs
    /// erste Mal.
    ///
    /// Gespeichert wird die OBERE linke Ecke, nicht der AppKit-Ursprung: die
    /// Panelhöhe ändert sich beim Auf- und Zuklappen, die Oberkante ist das,
    /// was optisch stehen bleiben soll.
    private static func key(_ id: String) -> String { "panelTopLeft_\(id)" }

    public static func storeTopLeft(_ p: NSPoint, id: String) {
        UserDefaults.standard.set(["x": Double(p.x), "y": Double(p.y)], forKey: key(id))
    }

    /// Gemerkter Ursprung für diese Panelgröße — oder nil, wenn es nichts
    /// Gemerktes gibt oder die Position auf keinem angeschlossenen Bildschirm
    /// mehr liegt (Monitor abgesteckt, Auflösung geändert).
    public static func savedOrigin(panelSize: CGSize, id: String) -> NSPoint? {
        guard let d = UserDefaults.standard.dictionary(forKey: key(id)),
              let storedX = d["x"] as? Double, let storedTop = d["y"] as? Double
        else { return nil }
        let x = CGFloat(storedX), top = CGFloat(storedTop)

        // Die Titelleiste muss sichtbar bleiben, sonst ist das Panel nicht mehr
        // greifbar — deshalb gegen die Oberkante prüfen, nicht gegen den Rahmen.
        let probe = CGRect(x: x, y: top - 20, width: min(panelSize.width, 120), height: 20)
        guard let vf = visibleFrame(containing: probe), vf.intersects(probe) else { return nil }

        let clampedX = min(max(x, vf.minX + 8), vf.maxX - panelSize.width - 8)
        let y = clampY(top - panelSize.height, height: panelSize.height, vf: vf)
        return NSPoint(x: clampedX.rounded(), y: y.rounded())
    }

    /// Notausgang, falls ein Panel doch mal unerreichbar liegt: nächstes Öffnen
    /// nimmt wieder den Automatik-Platz neben dem Widget.
    public static func forgetPositions(ids: [String] = ["create", "settings"]) {
        for id in ids { UserDefaults.standard.removeObject(forKey: key(id)) }
    }
}

/// Schreibt die Position weg, sobald das Panel bewegt wurde.
///
/// Als NSWindowDelegate statt NotificationCenter-Observer: Delegate-Methoden
/// laufen garantiert auf dem Main-Actor, ein `@Sendable` Observer-Closure dagegen
/// darf das `Notification`-Objekt nicht über die Actor-Grenze mitnehmen (Swift-6-
/// Concurrency lehnt das ab). `window.delegate` ist WEAK — der Controller muss
/// die Instanz festhalten.
@MainActor
public final class PanelMoveRecorder: NSObject, NSWindowDelegate {
    private let id: String
    /// Während wir das Fenster SELBST verschieben (Panel wächst beim Aufklappen)
    /// darf nichts gespeichert werden — sonst wandert die gemerkte Position mit
    /// jedem Auf- und Zuklappen davon (Runde 47i).
    public var suspended = false

    public init(id: String) { self.id = id }

    public func windowDidMove(_ notification: Notification) {
        guard !suspended, let w = notification.object as? NSWindow else { return }
        PanelDock.storeTopLeft(NSPoint(x: w.frame.minX, y: w.frame.maxY), id: id)
    }
}
