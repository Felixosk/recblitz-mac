import SwiftUI
import AppKit

// Runde 91: Theme.swift ist die EINZIGE Quelle für Farben, Schriftgrößen,
// Ecken, Abstände und Bausteine von Widget und Termin-Fenster. Die Views
// benutzen nur diese Namen, keine losen Zahlen und Farben. Seit Runde 98 gilt es auch für Einstellungen und Willkommen.
//
// Regeln (Stand 17.11.2026):
//  1. Drei Knopfarten: blauer Hauptknopf, runder Symbol-Knopf, schlichte Textzeile.
//  2. Blau heißt "klickbar" oder "ausgewählt", nie Deko. Ein einziger Blauton.
//  3. Eine Auswahl-Leiste für alles (Dauer, EN/DE), Auswahl blau.
//  4. Beschriftungen links weiß, Abschnittstitel klein und grau.
//  5. Vier Schriftgrößen: groß (44), Titel (22, Hero-Titel), normal, klein.
//  6. Ecken: Felder, Kästen, Knöpfe 10 pt, Fenster 26 pt. Abstände in 8er-Schritten (4 wo nötig).
//
// 🚨 Fallstrick 7 (packaging/repo/CLAUDE.md): randlose Glas-Panels haben die App
// schon einmal unklickbar gemacht. Runde 110: Fenster bleiben `.titled`, das Glas liegt als
// SwiftUI-Hintergrund IM Inhalt, rundum eine durchsichtige Bühne (`Theme.stageInset`).

/// Ebene, die nie Klicks annimmt.
final class GlassDecoration: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }
}

enum Theme {
    // MARK: Farben
    /// Der eine Blauton: klickbar oder ausgewählt.
    static let blueNS = NSColor(srgbRed: 0.16, green: 0.42, blue: 0.98, alpha: 1)
    static let blue = Color(red: 0.16, green: 0.42, blue: 0.98)
    /// Neutral dunkler Schleier im Glas (Runde 93: kein Blau im Glas).
    static let washNS = NSColor.black
    static let label = Color.primary                    // Beschriftungen: weiß
    static let muted = Color.secondary                  // Abschnittstitel, Nebentexte
    static let faint = Color.secondary.opacity(0.5)     // ausgegraut
    // Runde 115: alle Flächenfarben je nach Aussehen (dunkel: weiße Schicht, hell: schwarze Schicht).
    static func dyn(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let fill = dyn(dark: NSColor.white.withAlphaComponent(0.10), light: NSColor.black.withAlphaComponent(0.08))         // Felder, Knopf-Grund
    static let fillHover = dyn(dark: NSColor.white.withAlphaComponent(0.18), light: NSColor.black.withAlphaComponent(0.13))
    static let fillStrong = dyn(dark: NSColor.white.withAlphaComponent(0.16), light: NSColor.black.withAlphaComponent(0.11))       // Knopf-Grund zweite Stufe
    static let pressHighlight = dyn(dark: NSColor.white.withAlphaComponent(0.12), light: NSColor.black.withAlphaComponent(0.07))   // Aufhellen beim Überfahren
    static let line = dyn(dark: NSColor.white.withAlphaComponent(0.12), light: NSColor.black.withAlphaComponent(0.14))
    static let onBlue = Color.white
    static let warn = Color.orange
    static let ok = Color.green
    static let danger = Color.red

    static let knob = Color.white                       // Schieberknopf
    static let shadow = Color.black.opacity(0.35)

    /// Name zu einem Symbol-Knopf (VoiceOver + Tooltip), damit kein runder Knopf stumm ist.
    static func iconLabel(_ symbol: String) -> String {
        switch symbol {
        case "xmark": return L.t("Schließen", "Close")
        case "link": return L.t("Link kopieren", "Copy link")
        case "film": return L.t("Video im Finder zeigen", "Show video in Finder")
        case "doc.on.doc": return L.t("Transkript kopieren", "Copy transcript")
        case "doc.text": return L.t("Doc oder Notiz öffnen", "Open doc or note")
        case "gearshape": return L.t("Einstellungen", "Settings")
        case "power": return L.t("Beenden", "Quit")
        case "folder": return L.t("Ordner öffnen", "Open folder")
        case "externaldrive": return L.t("Drive-Ordner öffnen", "Open Drive folder")
        case "pause.fill": return L.t("Pause", "Pause")
        case "play.fill": return L.t("Weiter aufnehmen", "Resume")
        case "trash": return L.t("Aufnahme verwerfen", "Discard recording")
        case "chevron.down": return L.t("Mikrofon wählen", "Choose microphone")
        default: return symbol
        }
    }

    // MARK: Schriftgrößen (nur drei)
    enum Size { case big, title, heading, normal, small }
    static func size(_ s: Size) -> CGFloat {
        switch s {
        case .big: return 44
        case .title: return 22
        case .heading: return 15
        case .normal: return 13
        case .small: return 11
        }
    }

    // MARK: Ecken
    /// Runde 109: EINE Klapp-Animation für alle Aufklappbereiche.
    /// Runde 110: Feder ohne Nachfedern (Apple-Standardgefühl). `ThemeFold` + `withAnimation(Theme.fold)`.
    static let fold = Animation.smooth(duration: 0.26)
    /// Das Fenster schrumpft erst, wenn die Feder durch ist.
    static let foldSettle: TimeInterval = 0.32
    static let segInset: CGFloat = 2         // Abstand Leiste→Pille (= Luft zwischen zwei gewählten Pillen), wie MeetingBlitz
    static let radius: CGFloat = 10          // Felder, Kästen, Knöpfe
    static let windowRadius: CGFloat = 26    // Fenster (Runde 110: macOS-26-Maß, 10-pt-Felder bei 16 pt Abstand konzentrisch)
    /// Runde 110: Das Fenster ist die durchsichtige Bühne, rundum so viel größer als das Glas.
    static let stageInset: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["RB_STAGE"] ?? "") ?? 16)
    static let smallRadius: CGFloat = 4      // Haken, kleine Marken
    static let innerRadius: CGFloat = 8      // Auswahl-Leiste innen (= radius - 2, konzentrisch)

    /// Runde 102: Testschalter, erzwingt Hover für Fotos. `RB_HOVER=<Teil des Titels>` (Termin-Zeilen)
    /// oder `RB_HOVER=time` (große Uhrzeit im Termin-Fenster).
    static let demoHover: String? = ProcessInfo.processInfo.environment["RB_HOVER"]

    /// Runde 102: Konzentrische Ecken (Apple). Eine Form IN einer Form hat den
    /// Radius außen minus Abstand, mindestens `smallRadius`. Auf macOS 26 würde
    /// `ConcentricRectangle` dasselbe tun; die Formel gilt auf allen Versionen.
    static func inner(_ outer: CGFloat = radius, inset: CGFloat) -> CGFloat { max(smallRadius, outer - inset) }

    // MARK: Abstände (8er-Schritte, 4 wo nötig)
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s16: CGFloat = 16
    static let s24: CGFloat = 24

    // MARK: Knopfgrößen
    static let iconButton: CGFloat = 24
    /// Runde 110: runde Symbol-Knöpfe 28 pt (macOS-26-Kontrollgröße).
    static let iconButtonSize: CGFloat = 28
    static let primaryHeight: CGFloat = 36
    static let sliderHeight: CGFloat = 32    // Zeitzonen-Schieber samt Ticks (Runde 111: Ziffern 6 12 18 wurden unten abgeschnitten)
    static let knobSize: CGFloat = 16
    static let trackHeight: CGFloat = 8
    static let dot: CGFloat = 8              // Farbpunkt
    static let timelineTrack: CGFloat = 24
    static let timelineBlock: CGFloat = 16
    static let timelineHeight: CGFloat = 40
    static let pastOpacity: Double = 0.4   // Runde 111: vergangene Termine deutlicher abgedunkelt
    static let headerControlsWidth: CGFloat = 24 + 8 + 56 + 8 + 24   // ‹ Heute ›
    static let widgetWidth: CGFloat = 360
    static let formWidth: CGFloat = 320

}

extension View {
    /// Zeilen mit Hover-Hintergrund tragen innen 8 pt Rand. Dieser Modifier
    /// zieht die Liste um genau so viel nach außen, damit ihr TEXT auf derselben
    /// linken Kante steht wie Titel und Hero (Hover-Fläche ragt in den Rand).
    func themeRowList() -> some View { padding(.horizontal, -Theme.s8) }
}

extension Font {
    /// Die drei erlaubten Schriftgrößen.
    static func theme(_ s: Theme.Size, _ weight: Font.Weight = .regular) -> Font {
        .system(size: Theme.size(s), weight: weight)
    }
}

// MARK: - Bausteine

/// Runde 110: Aufklappbereich. Bleibt IMMER im Baum (kein if, keine Transition).
/// Die Höhe läuft 0 ↔ Inhaltshöhe, der Inhalt steht an der Kante fest und wird auf- bzw.
/// zugedeckt; die Deckkraft läuft im selben Takt. Nichts überlagert die Nachbarn.
/// `edge: .bottom` für Bereiche ÜBER der Kopfzeile (Inhalt hängt unten fest).
struct ThemeFold<Content: View>: View {
    let isOpen: Bool
    var gap: CGFloat = Theme.rowGap
    var edge: VerticalEdge = .top
    @ViewBuilder var content: Content
    @State private var height: CGFloat?
    var body: some View {
        content
            .padding(edge == .top ? .top : .bottom, gap)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
            .frame(height: isOpen ? height : 0, alignment: edge == .top ? .top : .bottom)
            .clipped()
            .opacity(isOpen ? 1 : 0)
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)
    }
}

/// Kleiner grauer Abschnittstitel ("Heute", "Später heute", "Zeitzonen").
struct ThemeSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.theme(.small, .semibold)).foregroundStyle(Theme.muted)
    }
}

/// Dünne Trennlinie.
struct ThemeDivider: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

/// Knopfart 1: Hauptknopf. Überall dieselbe Form (Beitreten, Erstellen).
/// `.primary` = blau (der einzige blaue Großknopf pro Fenster), `.secondary` =
/// grau gefüllt mit weißem Text (zweite Stufe, z. B. "Neues Meeting").
/// `.small` = kleine Variante für Zeilen ("Beitreten" in der Liste).
struct ThemePrimaryButton: View {
    enum Style { case primary, secondary }
    enum Size { case regular, small }
    let title: String
    var busy = false
    var style: Style = .primary
    var size: Size = .regular
    /// Andere Fuellung statt Blau (Aufnahme laeuft = `Theme.danger`).
    var tint: Color? = nil
    var icon: String? = nil
    /// Runde 114: kleine Tastenhilfe rechts im Knopf (z. B. "↩").
    var keyHint: String? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    private var height: CGFloat { size == .small ? Theme.iconButton : Theme.primaryHeight }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.s8) {
                if busy { ProgressView().controlSize(.small) }
                else if let icon { Image(systemName: icon).font(.theme(.small, .semibold)) }
                Text(title).font(.theme(size == .small ? .small : .normal, .semibold)).lineLimit(1)
                if let keyHint {
                    Text(keyHint).font(.system(size: 12, weight: .semibold)).opacity(0.75)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.22)))
                }
            }
            .foregroundStyle(Theme.onBlue)
            .padding(.horizontal, size == .small ? Theme.s16 : 0)
            .frame(maxWidth: size == .small ? nil : .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(style == .primary ? (tint ?? Theme.blue).opacity(enabled ? 1 : 0.55)
                                        : (hover ? Theme.fillHover : Theme.fillStrong)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(style == .primary && hover ? Theme.pressHighlight : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Runde 110: ‹ › als EINE Kapsel (56 × 28) mit Trennstrich, wie im Finder.
struct ThemeNavCapsule: View {
    let onBack: () -> Void
    let onForward: () -> Void
    @State private var hoverBack = false
    @State private var hoverForward = false
    var body: some View {
        HStack(spacing: 0) {
            half("chevron.left", L.t("Zurück", "Back"), hover: hoverBack, action: onBack).onHover { hoverBack = $0 }
            Rectangle().fill(Theme.line).frame(width: 1, height: 14)
            half("chevron.right", L.t("Weiter", "Forward"), hover: hoverForward, action: onForward).onHover { hoverForward = $0 }
        }
        .frame(width: 56, height: 28)
        .background(Capsule().fill(Theme.fill))
        .clipShape(Capsule())
    }
    private func half(_ symbol: String, _ label: String, hover: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.theme(.small, .semibold)).foregroundStyle(Theme.label)
                .frame(width: 27.5, height: 28)
                .background(hover ? Theme.fillHover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Knopfart 2: runder Symbol-Knopf. `active` = blau gefüllt.
struct ThemeIconButton: View {
    let systemName: String
    /// VoiceOver-Name und Tooltip. Ohne Angabe kommt er aus dem Symbol (`Theme.iconLabel`).
    var label: String? = nil
    var active = false
    var tint: Color? = nil
    /// Runde 111 (Fund 8): false, wenn schon ein eigener Hinweis (rowHint) dranhängt, damit nur EIN Tooltip erscheint.
    var showHelp = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.theme(.small, .semibold))
                .foregroundStyle(active ? Theme.onBlue : (tint ?? Theme.label))
                
                .frame(width: Theme.iconButtonSize, height: Theme.iconButtonSize)
                .background(Circle().fill(active ? Theme.blue : (hover ? Theme.fillHover : Theme.fill)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? Theme.iconLabel(systemName))
        .help(showHelp ? (label ?? Theme.iconLabel(systemName)) : "")
        .onHover { hover = $0 }
    }
}

/// Knopfart 3: schlichte Textzeile (mit kleinem Symbol links). `accent` = blau
/// (klickbarer Text wie "Beitreten", "+ Zone").
struct ThemeTextRow: View {
    let title: String
    var icon: String? = nil
    var busy = false
    var accent = false
    var trailing: String? = nil
    var trailingIcon: String? = nil
    var trailingRotation: Double = 0
    var weight: Font.Weight? = nil
    var fullWidth = true
    var compact = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.s8) {
                if busy {
                    ProgressView().controlSize(.mini).frame(width: Theme.s16)
                } else if let icon {
                    Image(systemName: icon).font(.theme(.small, .semibold))
                        .foregroundStyle(accent ? Theme.blue : Theme.muted).frame(width: Theme.s16)
                }
                Text(title).font(.theme(.normal, weight ?? (accent ? .semibold : .regular))).lineLimit(1)
                    .minimumScaleFactor(0.8)   // Runde 110c: lange Titel schrumpfen statt "…" abzuschneiden
                    .foregroundStyle(accent ? Theme.blue : Theme.label)
                if fullWidth { Spacer(minLength: 0) }
                if let trailing {
                    Text(trailing).font(.theme(.small)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                if let trailingIcon {
                    Image(systemName: trailingIcon).font(.theme(.small, .semibold))
                        .foregroundStyle(accent ? Theme.blue : Theme.muted)
                        .rotationEffect(.degrees(trailingRotation))
                        .frame(width: Theme.s16, height: Theme.s16)   // Runde 110b (U5)
                }
            }
            .padding(.horizontal, Theme.s8).padding(.vertical, Theme.s4)
            .frame(minHeight: compact ? Theme.s24 : Theme.s24 + Theme.s8)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(hover || Theme.demoHover == title ? Theme.fill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Die EINE Auswahl-Leiste (Dauer, EN/DE). Auswahl blau.
/// Runde 109 `draggable`: die blaue Pille lässt sich mit der Maus von Stufe zu
/// Stufe ziehen (folgt weich dem Zeiger, wechselt über der Mitte der nächsten
/// Stufe, Haptik je Stufe, rastet beim Loslassen ein), Mausrad = eine Stufe.
/// Ein Wert außerhalb der Stufen (Freitext 20 min) zeigt keine Pille.
/// Alle Stufen müssen gleich breit sein (`segmentWidth`).
struct ThemeSegmented<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T
    var draggable = false

    static var segmentWidth: CGFloat { Theme.s24 + Theme.s8 }
    @State private var dragCenter: CGFloat?

    private var index: Int? { options.firstIndex { $0.value == selection } }
    private func index(atX x: CGFloat) -> Int {
        min(max(Int((x - 2) / Self.segmentWidth), 0), options.count - 1)
    }
    private func pick(_ i: Int) {
        let i = min(max(i, 0), options.count - 1)
        guard options[i].value != selection else { return }
        selection = options[i].value
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    var body: some View {
        if draggable { draggableBody } else { plainBody }
    }

    private var draggableBody: some View {
        let w = Self.segmentWidth
        let h = Theme.s24 + Theme.s4
        let pillX: CGFloat? = dragCenter.map { $0 - w / 2 } ?? index.map { CGFloat($0) * w }
        return ZStack(alignment: .topLeading) {
            if let pillX {
                RoundedRectangle(cornerRadius: Theme.inner(inset: 2), style: .continuous)
                    .fill(Theme.blue).frame(width: w, height: h)
                    .offset(x: pillX)
            }
            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { i in
                    let on = i == index
                    Text(options[i].label)
                        .font(.theme(.normal, on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.onBlue : Theme.label)
                        .frame(width: w, height: h)
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                let x = v.location.x - 2
                let c = min(max(x, w / 2), w * CGFloat(options.count) - w / 2)
                dragCenter = c
                pick(index(atX: c + 2))
            }
            .onEnded { v in
                withAnimation(.easeOut(duration: 0.12)) { dragCenter = nil }
            })
        .modifier(ScrollStepper { pick((index ?? 0) + $0) })
        .accessibilityElement()
        .accessibilityValue(options.first { $0.value == selection }?.label ?? "")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: pick((index ?? -1) + 1)
            case .decrement: pick((index ?? options.count) - 1)
            @unknown default: break
            }
        }
    }

    private var plainBody: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].value == selection
                Button { selection = options[i].value } label: {
                    Text(options[i].label)
                        .font(.theme(.normal, on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.onBlue : Theme.label)
                        .frame(minWidth: Theme.s24 + Theme.s8).frame(height: Theme.s24 + Theme.s4)
                        .background(RoundedRectangle(cornerRadius: Theme.inner(inset: 2), style: .continuous)
                            .fill(on ? Theme.blue : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
    }
}

/// Dieselbe Leiste mit Mehrfach-Auswahl (Wochentage der eigenen Wiederholung).
struct ThemeMultiSegmented<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: Set<T>
    /// true: Leiste fuellt die Breite; false: so schmal wie der Inhalt (rechts in einer Zeile).
    var fill = true

    var body: some View {
        HStack(spacing: Theme.segInset) {   // Runde 20: Luft zwischen den Pillen = Innenabstand der Leiste
            ForEach(options.indices, id: \.self) { i in
                let on = selection.contains(options[i].value)
                Button {
                    if on { selection.remove(options[i].value) } else { selection.insert(options[i].value) }
                } label: {
                    Text(options[i].label)
                        .font(.theme(.small, on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.onBlue : Theme.label)
                        .padding(.horizontal, fill ? 0 : Theme.s8)
                        .frame(maxWidth: fill ? .infinity : nil).frame(minWidth: fill ? 0 : Theme.s24 + Theme.s16)
                        .frame(height: Theme.s24 + Theme.s4)
                        .background(RoundedRectangle(cornerRadius: Theme.inner(inset: 2), style: .continuous)
                            .fill(on ? Theme.blue : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.segInset)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
    }
}

/// Eingabefeld: eine Form für alle (10 pt Ecken, keine Umrandung).
struct ThemeFieldStyle: TextFieldStyle {
    var leading: CGFloat = Theme.s8
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.theme(.normal))
            .padding(.leading, leading).padding(.trailing, Theme.s8).padding(.vertical, Theme.s8)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
    }
}

/// Haken: ausgewählt = blau gefüllt.
struct ThemeCheckStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Image(systemName: configuration.isOn ? "checkmark" : "")
                .font(.theme(.small, .bold)).foregroundStyle(Theme.onBlue)
                .frame(width: Theme.s16, height: Theme.s16)
                .background(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(configuration.isOn ? Theme.blue : Theme.fill))
                .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .strokeBorder(configuration.isOn ? Color.clear : Theme.muted, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Zeile "Beschriftung links (weiß), Steuerung rechts".
struct ThemeFormRow<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: Theme.s8) {
            Text(title).font(.theme(.normal)).foregroundStyle(Theme.label)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            if let note { Text(note).font(.theme(.small)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8) }
            Spacer(minLength: Theme.s8)
            content
        }
        .themeRow()
    }
}

/// Runde 118: Fensterkante wie bei Apple. Gemessen am Finder-Fenster (Retina, 2x, 20.11.): 1 pt breite helle
/// Innenkante, oben am hellsten (Hell 96 bei Fläche 39-45, links 78, unten 83), dazu ein weicher Systemschatten.
/// Dunkel: weiße Lichtkante, oben stärker als unten. Hell: feine dunkle Haarlinie plus weißer Lichtsaum oben.
struct ThemeEdge: View {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = Theme.windowRadius
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if scheme == .dark {
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.08)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .allowsHitTesting(false)
        } else {
            ZStack {
                shape.strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
                shape.inset(by: 1).strokeBorder(LinearGradient(colors: [Color.white.opacity(0.9), Color.white.opacity(0.0)],
                                                               startPoint: .top, endPoint: .center), lineWidth: 1)
            }.allowsHitTesting(false)
        }
    }
}

/// Runde 110: EIN Glas im SwiftUI-Baum (kein Geschwister-View mehr, kein eigener Rand,
/// kein Verlauf). Der Inhalt liegt IM Glas; die Glaskante zeichnet das System.
struct ThemeGlass: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isKey = false
    @Environment(\.colorScheme) private var scheme
    @AppStorage(Look.glassKey) private var glassRaw = Look.Glass.normal.rawValue
    /// Runde 111b: feste Abdunklung (Willkommen 0,55), sonst je nach Tastaturfokus.
    var dim: Double? = nil
    /// Eckenradius (Fenster 28 ..., Banner-Kapsel 20): gleiches Glas, gleiche Kante, nur andere Ecke.
    var radius: CGFloat = Theme.windowRadius
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    var body: some View {
        glass
            .background(WindowKeyProbe(isKey: $isKey))
            // Runde 118: Das Glas bringt (im Tastaturfokus) einen eigenen weichen Hof außerhalb der Form mit. Der
            // gehört in die Fenstermaske und ließe den Systemschatten eine dunkle Kontur 9 pt außerhalb ziehen.
            // Hart auf die Glasform beschneiden; den Schatten zeichnet das System.
            .clipShape(shape)
    }
    /// Runde 115: Glas "Klarer" halbiert die Schicht; Hell = weiße statt schwarzer Schicht.
    private var wash: Double {
        let base = dim ?? (isKey ? Theme.glassWash : Theme.glassWashInactive)
        let clear = glassRaw == Look.Glass.clear.rawValue
        return base * (clear ? 0.5 : 1) * (scheme == .dark ? 1 : 1.7)   // Hell: weiße Schicht kräftiger, sonst wirkt das Glas grau
    }
    @ViewBuilder private var glass: some View {
        if Theme.flatGlass {
            // Offscreen-Fenster zeichnen kein Liquid Glass: deckender Ersatz fuer die Test-Bilder.
            shape.fill(scheme == .dark ? Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255)
                                       : Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255))
                .overlay(ThemeEdge(radius: radius))
        } else if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
                .overlay(ThemeEdge(radius: radius))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        } else if #available(macOS 26.0, *) {
            (scheme == .dark ? Color.black : Color.white)
                .opacity(wash)
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
                .overlay(ThemeEdge(radius: radius))
        } else {
            VisualEffectBackground(material: .menu)
                .clipShape(shape)
                .overlay(ThemeEdge(radius: radius))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
    }
}

/// Meldet, ob das Fenster der Ansicht gerade Hauptfenster (key) ist. Das Liquid Glass von macOS 26 rendert in
/// Fenstern ohne Tastaturfokus heller (gemessen 19.11.: 48 statt 43 auf Grau 0,5); das Widget ist nie key.
struct WindowKeyProbe: NSViewRepresentable {
    @Binding var isKey: Bool
    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView(); v.onChange = { k in DispatchQueue.main.async { isKey = k } }; return v
    }
    func updateNSView(_ v: ProbeView, context: Context) { v.onChange = { k in DispatchQueue.main.async { isKey = k } } }
    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
            guard let w = window else { return }
            onChange?(w.isKeyWindow)
            // Runde 118: Der Systemschatten wird aus dem ersten gezeichneten Bild berechnet (noch ohne Glas) und
            // sonst nie erneuert: dunkle Kontur 9 pt außerhalb. Nach dem Zeichnen und bei jeder Änderung neu rechnen.
            for d in [0.05, 0.2, 0.5, 1.0, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak w] in w?.invalidateShadow() }
            }
            for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self, weak w] _ in
                    self?.onChange?(w?.isKeyWindow ?? false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak w] in w?.invalidateShadow() }
                })
            }
            for n in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak w] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak w] in w?.invalidateShadow() }
                })
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// macOS 14/15: aktives Menü-Material hinter dem Fenster.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

extension Theme {
    /// Banner (Glas-Kapsel wie MeetingBlitz): Breite, Ecke, durchsichtiger Rand fuer den eigenen Schatten,
    /// Abstand zum Bildschirmrand, Schrift der zweiten Zeile (12), Schatten (Glas = ThemeGlass wie Panel).
    static let bannerWidth: CGFloat = 430
    static let bannerRadius: CGFloat = 20
    static let bannerStage: CGFloat = 16
    static let bannerScreenGap: CGFloat = 16
    static let bannerIconSize: CGFloat = 28
    static let bannerSubtitleSize: CGFloat = 12
    static let bannerShadowOpacity: Double = 0.35
    static let bannerShadowRadius: CGFloat = 12
    static let bannerShadowY: CGFloat = 5
    static let bannerFade: Double = 0.15

    /// Bereichsrahmen (Aufnahme-Bereich): Rahmen-Dicke, Abdunklung des Rests (mit / ohne Loch), Deckkraft des Rahmens.
    static let regionLine: CGFloat = 2
    static let regionDim: Double = 0.34
    static let regionDimEmpty: Double = 0.22
    static let regionLineAlpha: Double = 0.95
    /// Test-Bilder (`--render-*`): flaches Ersatz-Glas, weil Offscreen-Fenster kein Glas zeichnen.
    nonisolated(unsafe) static var flatGlass = ProcessInfo.processInfo.environment["RB_FLAT_GLASS"] != nil
    /// Deckkraft der Abdunklung über dem Glas (gewollt: dunkles Glas).
    static var glassWash: Double {
        Double(ProcessInfo.processInfo.environment["RB_WASH"] ?? "") ?? 0.28
    }
    /// Ohne Tastaturfokus rendert das Glas heller; etwas mehr Abdunklung gleicht es aus (gemessen: gleiche Helligkeit).
    static var glassWashInactive: Double {
        Double(ProcessInfo.processInfo.environment["RB_WASH2"] ?? "") ?? 0.355
    }

    /// Runde 118: weicher Systemschatten (folgt der Glasform, wie bei Apple-Fenstern).
    static let systemShadow = ProcessInfo.processInfo.environment["RB_NO_SYSSHADOW"] == nil
    /// Runde 110: Fenster = durchsichtige Bühne. Kein Glas im AppKit-Baum.
    /// Das Fenster bleibt `.titled` (Fallstrick 7), Ampel/Titel aus.
    @MainActor static func installStage(in panel: NSPanel, movableByBackground: Bool = true) {
        panel.hasShadow = systemShadow
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titleVisibility = .hidden
        for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(b)?.isHidden = ProcessInfo.processInfo.environment["RB_KEEP_TRAFFIC"] == nil
        }
        panel.isMovableByWindowBackground = movableByBackground
    }
}

// MARK: - Runde 98: Panel mit Esc, Schalter-Zeile, Aufklapp-Zeile, Auswahl mit Symbolen

// MARK: - Runde 104: Zeilen und Abstände (eine Quelle)

extension Theme {
    /// Testschalter: alte Abstände (vor Runde 104) für den Vorher-Messwert.
    static let legacyRows = false
    /// Höhe JEDER Formularzeile (Schalter, Beschriftung + Bedienelement).
    static var rowHeight: CGFloat { legacyRows ? 0 : s24 + s8 }
    /// Abstand zwischen Zeilen in einem Abschnitt.
    static var rowGap: CGFloat { legacyRows ? s8 : s4 }
    /// Luft über und unter einer Trennlinie (gleich oben und unten).
    static var dividerGap: CGFloat { legacyRows ? 0 : s8 }
}

/// Merkt die Rahmen der Formularzeilen (nur für `--measure-rows`).
struct RowFramesKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
struct ContentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
struct FootTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
enum RowProbe {
    @MainActor static var rows: [String: [CGRect]] = [:]
    @MainActor static var contentBottom: CGFloat = 0
    @MainActor static var footTop: CGFloat = 0
}

extension View {
    /// Formularzeile: feste Mindesthöhe, vertikal zentriert, Rahmen für das Mess-Werkzeug.
    func themeRow() -> some View {
        frame(minHeight: Theme.rowHeight)
            .background(GeometryReader { g in
                Color.clear.preference(key: RowFramesKey.self, value: [g.frame(in: .global)])
            })
    }
}

/// Runde 105: Auswahl-Zeile. Passt die Leiste neben die Beschriftung, steht sie rechts;
/// sonst steht sie darunter über die volle Breite. Nie abgeschnitten ("Medi…").
struct ThemeChoiceRow<T: Hashable>: View {
    let title: String
    let options: [(String, T)]
    @Binding var selection: T
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.s8) {
                Text(title).font(.theme(.normal)).foregroundStyle(Theme.label).lineLimit(1).fixedSize()
                Spacer(minLength: Theme.s8)
                SegPick(options: options, selection: $selection, fill: false).fixedSize()
            }
            .themeRow()
            VStack(alignment: .leading, spacing: Theme.s4) {
                Text(title).font(.theme(.normal)).foregroundStyle(Theme.label)
                    .frame(maxWidth: .infinity, alignment: .leading).themeRow()
                SegPick(options: options, selection: $selection)
            }
        }
    }
}

/// Runde 105: Erklärtext unter einer Zeile: klein, grau, 8 pt Luft nach unten.
struct ThemeNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).themeNote() }
}
extension View {
    func themeNote() -> some View {
        font(.theme(.small)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, Theme.s8)
    }
}

/// Trennlinie zwischen Abschnitten, oben und unten gleicher Abstand.
struct ThemeSectionDivider: View {
    var body: some View { ThemeDivider().padding(.vertical, Theme.dividerGap) }
}

/// Runde 110: Das ✕ ist ein runder Knopf AUF der linken oberen Glas-Ecke (wie bei Apples Widgets im
/// Bearbeiten-Modus): Kreis 20 pt, Mitte bei (6, 6) vom Glas-Eck, ragt 4 pt über das Glas hinaus in die
/// durchsichtige Bühne. Klickfläche 28 pt um dieselbe Mitte.
extension Theme {
    static let closeButtonCenter = CGPoint(x: 6, y: 6)
    static let closeButtonDiameter: CGFloat = 20
    static let closeButtonHit: CGFloat = 28
}

struct ThemeCloseButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Theme.dyn(dark: NSColor(white: hover ? 0.30 : 0.22, alpha: 1), light: NSColor(white: hover ? 0.78 : 0.86, alpha: 1)))
                    .overlay(Circle().strokeBorder(Theme.line, lineWidth: 0.5))
                    // Runde 118: kein eigener Schatten mehr, der Systemschatten des Fensters folgt dem Knopf (sonst doppelt)
                    .frame(width: Theme.closeButtonDiameter, height: Theme.closeButtonDiameter)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.label.opacity(hover ? 1 : 0.85))
            }
            .frame(width: Theme.closeButtonHit, height: Theme.closeButtonHit)
            .contentShape(Circle())
        }
        .buttonStyle(ThemeCloseStyle())
        .accessibilityLabel(L.t("Schließen", "Close"))
        .help(L.t("Schließen (Esc)", "Close (Esc)"))
        .onHover { hover = $0 }
    }
}

private struct ThemeCloseStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

extension View {
    /// Setzt das ✕ mit der Mitte auf `Theme.closeButtonCenter` der Glas-Ecke. Vor dem Bühnen-Padding anwenden.
    func themeCloseCorner(_ action: @escaping () -> Void) -> some View {
        overlay(alignment: .topLeading) {
            ThemeCloseButton(action: action)
                .offset(x: Theme.closeButtonCenter.x - Theme.closeButtonHit / 2,
                        y: Theme.closeButtonCenter.y - Theme.closeButtonHit / 2)
        }
    }
}

/// Kopfzeile der Fenster: Titel am linken Inhaltsrand (x = 16), 15 pt semibold, Zeile 24 hoch ab y = 16
/// (Mittellinie 28). Das ✕ sitzt auf der Ecke, nicht daneben.
struct ThemeWindowHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: Theme.s8) {
            Text(title).font(.theme(.heading, .semibold)).lineLimit(1)
            Spacer(minLength: Theme.s4)
        }
        .frame(height: Theme.iconButton)
    }
}

/// Panel, das auf Esc (cancelOperation) schließt.
final class ThemePanel: NSPanel {
    var onEscape: (() -> Void)?
    /// Runde 108b: bei `.fullSizeContentView` + durchsichtiger Titelleiste ist
    /// die Inhaltsgröße die Fenstergröße (keine Titelleiste obendrauf).
    var contentFillsFrame = false
    override func frameRect(forContentRect contentRect: NSRect) -> NSRect {
        contentFillsFrame ? contentRect : super.frameRect(forContentRect: contentRect)
    }
    override func contentRect(forFrameRect frameRect: NSRect) -> NSRect {
        contentFillsFrame ? frameRect : super.contentRect(forFrameRect: frameRect)
    }
    /// Runde 108b: vom Inhalt gemessene Höhe. `NSHostingView` setzt nach jeder
    /// Layout-Runde die Fensterhöhe neu und rechnet dabei die unsichtbare
    /// Titelleiste (24 pt) dazu, auch ohne `sizingOptions`. Ist hier eine Höhe
    /// gesetzt, gewinnt sie; die Oberkante bleibt dabei stehen.
    var pinnedHeight: CGFloat?
    /// Runde 109: Größenwünsche von `NSHostingView` (windowDidLayout →
    /// updateAnimatedWindowSize) werden verworfen, nur der Controller setzt die
    /// Größe (`setFrameFromController`). Mit dem oben festgenagelten Inhalt
    /// (flexibler Frame) schaukelte sich sonst die Höhe auf (gemessen 5161 pt,
    /// Layout-Rekursion, Absturz).
    var controllerOwnsSize = false
    /// Runde 110: Die durchsichtige Bühne darf über die Menüleiste ragen (das Glas steht darunter);
    /// AppKit schöbe ein Titel-Fenster sonst nach unten.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    private var fromController = false
    func setFrameFromController(_ r: NSRect, display: Bool) {
        fromController = true; defer { fromController = false }
        setFrame(r, display: display)
    }
    override func setFrame(_ r: NSRect, display: Bool) {
        if controllerOwnsSize, !fromController, (abs(r.height - frame.height) > 0.5 || abs(r.width - frame.width) > 0.5) { return }
        var f = r
        if contentFillsFrame, let h = pinnedHeight, abs(f.height - h) > 0.5 {
            f.origin.y = r.maxY - h
            f.size.height = h
        }
        super.setFrame(f, display: display)
        snapContentToFrame()
    }
    /// Runde 109b: Beim Wachsen rechnete AppKit die Vergrößerung zweimal auf den
    /// Inhalt drauf (gemessen: Fenster 557, contentView 669 → alles 112 pt nach
    /// oben verrutscht, unten leer). Inhalt = immer genau die Fensterfläche.
    private func snapContentToFrame() {
        guard contentFillsFrame, let c = contentView else { return }
        let want = NSRect(origin: .zero, size: frame.size)
        if c.frame != want { c.frame = want }
        if let sv = c.superview, sv.frame.size != frame.size { sv.setFrameSize(frame.size) }
        DispatchQueue.main.async { [weak self] in
            guard let self, let c = self.contentView else { return }
            let want = NSRect(origin: .zero, size: self.frame.size)
            if c.frame != want { c.frame = want }
        }
    }
    override func setFrame(_ r: NSRect, display: Bool, animate: Bool) {
        if controllerOwnsSize, !fromController, (abs(r.height - frame.height) > 0.5 || abs(r.width - frame.width) > 0.5) { return }
        var f = r
        if contentFillsFrame, let h = pinnedHeight, abs(f.height - h) > 0.5 {
            f.origin.y = r.maxY - h
            f.size.height = h
        }
        super.setFrame(f, display: display, animate: animate)
        snapContentToFrame()
    }
    /// Cmd+W schließt wie das ✕.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }
}

/// Schalter als Zeile: Beschriftung links (weiß), blaues Kästchen rechts.
struct ThemeToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: Theme.s8) {
                configuration.label
                    .font(.theme(.normal)).foregroundStyle(Theme.label)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: Theme.s8)
                Image(systemName: configuration.isOn ? "checkmark" : "")
                    .font(.theme(.small, .bold)).foregroundStyle(Theme.onBlue)
                    .frame(width: Theme.s16, height: Theme.s16)
                    .background(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .fill(configuration.isOn ? Theme.blue : Theme.fill))
                    .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .strokeBorder(configuration.isOn ? Color.clear : Theme.muted, lineWidth: 1))
            }
            .themeRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Eine Aufklapp-Zeile für alle: Titel links weiß, Wert rechts grau (nur zu),
/// Pfeil rechts grau, ganze Zeile klickbar mit Hover-Fläche.
struct ThemeDisclosureRow: View {
    let title: String
    var value: String? = nil
    /// Runde 114: Wert blau und in normaler Größe (wie "Kalender" im Termin-Fenster).
    var accentValue = false
    let isOpen: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.s8) {
                Text(title).font(.theme(.normal)).foregroundStyle(Theme.label)
                Spacer(minLength: Theme.s8)
                if let value, !isOpen {
                    // Runde 114 (Punkt 8): gleich gesetzt wie die Zeile "Kalender" (Wert blau, normale Größe).
                    Text(value).font(accentValue ? .theme(.normal, .medium).monospacedDigit() : .theme(.small).monospacedDigit())
                        .foregroundStyle(accentValue ? Theme.blue : Theme.muted)
                        .lineLimit(1).truncationMode(.tail)
                }
                Image(systemName: "chevron.down").font(.theme(.small, accentValue ? .bold : .semibold))
                    .foregroundStyle(accentValue ? Theme.blue : Theme.muted)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .frame(width: Theme.s16, height: Theme.s16)   // Runde 110b (U5)
            }
            .padding(.horizontal, Theme.s8).themeRow()
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(hover || Theme.demoHover == title ? Theme.fill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.horizontal, -Theme.s8)   // Text bündig mit den Formularzeilen, nur die Hover-Fläche ragt hinaus
    }
}

/// Auswahl-Leiste für Einstellungen: Text oder Symbol je Eintrag.
struct ThemeChoice<T: Hashable>: View {
    let options: [(label: String, icon: String?, value: T)]
    @Binding var selection: T
    var help: ((T) -> String)? = nil
    /// true: Leiste füllt die Breite; false: so schmal wie der Inhalt (rechts in einer Zeile).
    var fill = true
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].value == selection
                Button { selection = options[i].value } label: {
                    Group {
                        if let ic = options[i].icon {
                            Image(systemName: ic).font(.theme(.normal, .medium))
                        } else {
                            Text(options[i].label).font(.theme(.small, on ? .semibold : .regular)).lineLimit(1)
                        }
                    }
                    .foregroundStyle(on ? Theme.onBlue : Theme.label)
                    .padding(.horizontal, fill ? 0 : Theme.s4 + 2)
                    .frame(maxWidth: fill ? .infinity : nil).frame(minWidth: fill ? 0 : Theme.s24 + Theme.s8)
                    .frame(height: Theme.s24 + Theme.s4)
                    .background(RoundedRectangle(cornerRadius: Theme.inner(inset: 2), style: .continuous)
                        .fill(on ? Theme.blue : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help?(options[i].value) ?? options[i].label)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
    }
}

/// Kurzform für die Einstellungen: Liste aus (Text, Wert).
struct SegPick<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var selection: T
    var fill = true
    var body: some View {
        ThemeChoice(options: options.map { (label: $0.0, icon: nil, value: $0.1) },
                    selection: $selection, fill: fill)
    }
}

/// Text-Knopf (Link): blau, beim Überfahren hinterlegt. Ersetzt `.borderless`.
struct ThemeLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkBody(configuration: configuration)
    }
    private struct LinkBody: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.theme(.normal)).foregroundStyle(Theme.blue)
                .padding(.horizontal, Theme.s8).padding(.vertical, Theme.s4)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(configuration.isPressed || hover ? Theme.fill : .clear))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// Runde 97: Scrollrad/Trackpad als Schritte. Trackpad-Deltas werden aufsummiert
/// (Schwelle), damit nichts springt; ein Mausrad-Rastern = ein Schritt.
/// Hoch = +1, runter = -1. Der Monitor läuft nur, solange die Maus darüber steht.
struct ScrollStepper: ViewModifier {
    let onStep: (Int) -> Void
    @State private var hovering = false
    @State private var monitor: Any?
    @State private var acc: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0; if !$0 { acc = 0 } }
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                    guard hovering else { return e }
                    if e.hasPreciseScrollingDeltas {
                        acc += e.scrollingDeltaY
                        let threshold: CGFloat = 14
                        var steps = 0
                        while acc >= threshold { steps += 1; acc -= threshold }
                        while acc <= -threshold { steps -= 1; acc += threshold }
                        if steps != 0 { onStep(steps) }
                        if e.phase == .ended || e.momentumPhase == .ended { acc = 0 }
                    } else if e.scrollingDeltaY != 0 {
                        onStep(e.scrollingDeltaY > 0 ? 1 : -1)
                    }
                    return nil
                }
            }
            .onDisappear {
                if let m = monitor { NSEvent.removeMonitor(m) }
                monitor = nil
            }
    }
}


/// Runde 110: weiche Kante oben/unten, wo Inhalt unter dem Kopf bzw. Fuß weiterläuft (statt harter Schnittkante
/// mit halber Zeile). Nur sichtbar, wenn in die Richtung noch Inhalt ist; im Ruhezustand oben bleibt die erste Zeile voll.
struct ThemeScrollFade: ViewModifier {
    struct Edges: Equatable { var top = false; var bottom = false }
    var enabled = true
    @State private var edges = Edges()
    private let fade: CGFloat = 20   // Runde 110b (U4): 16-20 pt
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: Edges.self, of: { g in
                    Edges(top: g.contentOffset.y > 1,
                          bottom: g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1)
                }) { _, v in edges = v }
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [enabled && edges.top ? .clear : .black, .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
                        Rectangle().fill(.black)
                        LinearGradient(colors: [.black, enabled && edges.bottom ? .clear : .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    func themeScrollFade(enabled: Bool = true) -> some View { modifier(ThemeScrollFade(enabled: enabled)) }
}


/// Runde 110b (F4): die ganze Kopfzeile (Glas-y 0 bis 40) zieht das Fenster, nicht nur der 9-pt-Streifen der
/// unsichtbaren Titelleiste. Liegt als Overlay über dem Kopf, UNTER dem ✕. Pille und Schieber liegen weiter unten
/// und ziehen das Fenster nicht.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        // Runde 112 (Fund 13): eigenes Ziehen statt performDrag. Das System klemmte die Oberkante des FENSTERS an die
        // Menüleiste (das Glas stand dann 16 pt zu tief) und folgte der Maus nicht 1:1. Hier: Mausweg = Fensterweg,
        // Obergrenze = dieselbe wie beim Öffnen (Glas-Oberkante 5 pt unter der Menüleiste).
        private var startMouse = NSPoint.zero
        private var startOrigin = NSPoint.zero
        override func mouseDown(with event: NSEvent) {
            startMouse = NSEvent.mouseLocation
            startOrigin = window?.frame.origin ?? .zero
        }
        override func mouseDragged(with event: NSEvent) {
            guard let w = window else { return }
            let m = NSEvent.mouseLocation
            var o = NSPoint(x: startOrigin.x + (m.x - startMouse.x), y: startOrigin.y + (m.y - startMouse.y))
            if let vf = (NSScreen.screens.first { $0.frame.contains(m) } ?? w.screen)?.visibleFrame {
                let top = vf.maxY + Theme.stageInset - 5          // Glas-Oberkante höchstens 5 pt unter der Menüleiste
                o.y = min(o.y, top - w.frame.height)
            }
            w.setFrameOrigin(o)
        }
    }
}

extension View {
    func themeDragHeader() -> some View {
        overlay(alignment: .top) { WindowDragArea().frame(height: 40) }
    }
}


/// Runde 111b: ein Reiter der Einstellungen, Symbol 17 pt über Wort 10 pt; gewählt = blau hinterlegt (Ecke 8).
struct SettingsTabButton: View {
    let symbol: String
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 17, weight: .regular)).frame(height: 22)
                Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Theme.onBlue : Theme.label.opacity(hover ? 1 : 0.8))
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                .fill(selected ? Theme.blue : (hover ? Theme.fillHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}


/// Fehlertext in Rot (klein, umbrechend).
struct ErrorLine: View {
    let text: String
    var color: Color = Theme.danger
    var body: some View {
        Text(text).font(.theme(.small)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}
