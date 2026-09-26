import AppKit
import SwiftUI

/// Erster Klick zählt sofort, auch wenn die App nicht aktiv ist — sonst muss man
/// jedes schwebende Bedienelement zweimal anklicken.
final class OverlayHosting<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
}

/// Liquid Glass (macOS 26) mit Rückfall auf ein dunkles Material.
///
/// Rückmeldung 01.08.: "Liquid Glass bitte überall nach Apple machen". `.glassEffect`
/// ist das Material, das Apple selbst für schwebende Bedienelemente nutzt — es
/// nimmt den Hintergrund auf, statt ihn nur abzudunkeln.
///
/// ⚠️ Deshalb IMMER `.primary` für Schrift und Symbole darauf, nie `.white`:
/// auf hellem Untergrund verschwindet weiße Schrift sonst komplett.
struct GlassBackground: ViewModifier {
    let corner: CGFloat
    /// `clear` = deutlich durchsichtiger. Nötig überall dort, wo das Glas nur
    /// ein schmaler Rand ist: `.regular` ist auf hellem Untergrund fast deckend
    /// und sah dann nach grauem Plastikring aus statt nach Glas (Rückmeldung 01.08.).
    var clear = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // .interactive(): reagiert auf Zeiger und Bewegung, das ist der
            // lebendige Apple-Look statt einer statischen Milchglasplatte.
            content.glassEffect(clear ? .clear.interactive() : .regular.interactive(),
                                in: .rect(cornerRadius: corner))
        } else {
            content
                .background(RoundedRectangle(cornerRadius: corner)
                    .fill(Color(white: 0.13).opacity(0.96)))
                .overlay(RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
    }
}
