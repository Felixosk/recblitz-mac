import AppKit
import SwiftUI

/// Small floating result banner, top-right. Click opens the result; auto-dismisses.
final class Banner {
    private static var current: NSPanel?

    /// `screen` nur fuer die Verifikation (--demo-banner): erlaubt, die Meldung
    /// auf einem bestimmten Monitor zu zeigen. Normal immer NSScreen.main.
    static func show(title: String, subtitle: String, url: URL?, isError: Bool = false,
                     seconds: TimeInterval = 12, hint: String? = nil, screen: NSScreen? = nil) {
        current?.close()

        let view = BannerView(title: title, subtitle: subtitle, isError: isError,
                              hint: hint, hasLink: url != nil,
                              onTap: {
            if let url { NSWorkspace.shared.open(url) }
            current?.close()
            current = nil
        }, onClose: {
            // × schließt, ohne den Link zu öffnen (Rückmeldung 31.07.: "überall ein x
            // zum Schließen wie bei MeetingBlitz").
            current?.close()
            current = nil
        })
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.frame.size),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false

        if let screen = screen ?? NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - hosting.frame.width - 16,
                                         y: f.maxY - hosting.frame.height - 12))
        }
        panel.orderFrontRegardless()
        current = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak panel] in
            if current === panel { current?.close(); current = nil }
        }
    }
}

/// Farben aus MeetingBlitz (Banner-Kapsel, Rand, Schrift), damit beide Apps
/// dieselbe Handschrift tragen.
extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

private struct BannerView: View {
    let title: String
    let subtitle: String
    let isError: Bool
    let hint: String?
    let hasLink: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isError ? Color(hex: 0xF0A93B) : Color(hex: 0x8EE6C8))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.black.opacity(0.22)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(hex: 0xEAF6F2))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint, !hint.isEmpty {
                    Text(hint).font(.system(size: 10.5))
                        .foregroundStyle(Color(hex: 0xEAF6F2).opacity(0.7))
                } else if !isError, hasLink {
                    Text(L.t("Klick öffnet das Ergebnis", "Click to open the result"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(hex: 0xEAF6F2).opacity(0.7))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            Spacer(minLength: 0)
        }
        .padding(.leading, 12).padding(.trailing, 16).padding(.vertical, 12)
        .frame(width: 340, alignment: .leading)
        .background(
            // Dieselbe Meeresfarbe wie die MeetingBlitz-Kapsel. Fehler bekommen
            // ein dunkles Schiefer statt Türkis, damit man sie nicht mit einer
            // Erfolgsmeldung verwechselt.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(
                    colors: isError ? [Color(hex: 0x3A4658), Color(hex: 0x1B2230)]
                                    : [Color(hex: 0x18A9B4), Color(hex: 0x0A4E58)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(hex: isError ? 0xF0A93B : 0x2EC7A0).opacity(0.30), lineWidth: 1)
        )
        // × sitzt AUF der Ecke und ragt leicht heraus, wie bei den macOS-
        // Mitteilungen (Rückmeldung 31.07.). Dunkle Scheibe, weißes Kreuz, wie
        // das Schließkreuz der MeetingBlitz-Kapsel.
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L.t("Schließen", "Close"))
            .offset(x: 4, y: -4)
        }
        // Platz für das überstehende ×, sonst schneidet das Panel es ab.
        .padding(.top, 6)
        .padding(.trailing, 6)
    }
}
