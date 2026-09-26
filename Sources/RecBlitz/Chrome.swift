import SwiftUI

// Gemeinsame Bausteine im MeetingBlitz-Stil. Beide Apps sollen sich wie
// Geschwister anfühlen: gleiche Reiterleiste, gleiche Aktionspille, gleiche
// Kartenflächen, gleiche Schriftgrößen. Handgemalt statt System-Styles, weil
// Systemknöpfe im nie aktiven Menüleisten-Panel grau und leblos rendern.

/// Segment-Leiste, gebaut wie die Reiterleiste in den MeetingBlitz-
/// Einstellungen: dunkle Mulde, gewähltes Feld in Akzentfarbe, Hover hellt auf.
struct PillSegment<ID: Hashable>: View {
    struct Item {
        let id: ID
        let label: String
        var icon: String? = nil
        var help: String? = nil
    }

    let items: [Item]
    let selection: ID
    var disabled = false
    let onSelect: (ID) -> Void
    @State private var hovered: ID?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                let on = item.id == selection
                Button { onSelect(item.id) } label: {
                    HStack(spacing: 4) {
                        if let icon = item.icon {
                            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                        }
                        Text(item.label)
                            .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .padding(.horizontal, 3)
                    .foregroundStyle(on ? Color.white
                                     : hovered == item.id ? Color.primary : Color.secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(on ? Color.accentColor
                                  : hovered == item.id ? Color.primary.opacity(0.10) : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .onHover { h in hovered = h ? item.id : (hovered == item.id ? nil : hovered) }
                .help(item.help ?? item.label)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)
    }
}

/// Die große Aktionspille aus MeetingBlitz („Neues Meeting"): satte, deckende
/// Füllung mit Glanzkante, damit das durchscheinende Panel sie über einem
/// hellen Fenster nicht auswäscht.
struct ActionPill: View {
    let title: String
    let icon: String
    var tint: Color = .accentColor
    var hovered = false
    var dimmed = false

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [tint.opacity(hovered ? 1.0 : 0.95),
                                 tint.opacity(hovered ? 0.92 : 0.82)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.28), .clear],
                                                 startPoint: .top, endPoint: .center))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.5)
                    )
                    .shadow(color: tint.opacity(0.25), radius: 3, y: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(dimmed ? 0.55 : 1)
    }
}

/// Kleiner quadratischer Nebenknopf neben der Aktionspille (Pause, Verwerfen).
/// Neutral statt farbig: die Hauptaktion bleibt die einzige satte Fläche.
struct SquarePill: View {
    let icon: String
    var active = false
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.primary)
                .frame(width: 36)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(active ? Color.accentColor
                              : Color.primary.opacity(hovered ? 0.15 : 0.09))
                )
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// Umschalter als Chip, gebaut wie der „Heute"-Chip im MeetingBlitz-Kopf:
/// an = Akzentschrift auf Akzent-Tönung, aus = gedämpft.
struct ChipToggle: View {
    let icon: String
    let offIcon: String
    let label: String
    let isOn: Bool
    var disabled = false
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? icon : offIcon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 11, weight: isOn ? .semibold : .medium))
            }
            .foregroundStyle(isOn ? Color.accentColor : hovered ? Color.primary : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isOn ? Color.accentColor.opacity(0.15)
                      : Color.primary.opacity(hovered ? 0.10 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .help(help)
    }
}

/// Symbolknopf in einer Listenzeile, wie die Aktionen in den MeetingBlitz-
/// Terminzeilen (Kopieren, Beitreten). Zeigt nach dem Klick kurz ein Häkchen.
struct RowIconButton: View {
    let icon: String
    let help: String
    var confirms = false
    let action: () -> Void
    @State private var done = false
    @State private var hovered = false

    var body: some View {
        Button {
            action()
            guard confirms else { return }
            withAnimation(.easeInOut(duration: 0.14)) { done = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.2)) { done = false }
            }
        } label: {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .font(.system(size: 11.5))
                .foregroundStyle(done ? Color.green : hovered ? Color.primary : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// Fußzeilen-Knopf (Einstellungen, Beenden) in der MeetingBlitz-Optik. Eigene
/// Bauform statt `.borderless`, die sich im nie aktiven Panel nicht zuverlässig
/// einfärbt.
struct FooterButton: View {
    var icon: String? = nil
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11.5)) }
                Text(label).font(.system(size: 12))
            }
            .foregroundStyle(hovered ? Color.primary : Color.primary.opacity(0.85))
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(hovered ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Kartenfläche für zusammengehörige Einstellungen, wie das aufgeklappte
/// Kalenderraster in MeetingBlitz.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

/// Kleine Abschnittsüberschrift („Zuletzt", Reiter-Titel), wie in MeetingBlitz.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
