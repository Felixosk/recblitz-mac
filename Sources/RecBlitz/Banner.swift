import AppKit
import SwiftUI

/// Kleines Ergebnis-Fenster oben rechts (Glas-Kapsel wie MeetingBlitz, mit blauer Toenung; Fehler orange).
/// Klick oeffnet das Ergebnis, ✕ (links oben auf der Ecke) schliesst nur. Schliesst von selbst.
final class Banner {
    private static var current: NSPanel?

    /// Fenster ohne Rand, nimmt nie Tastaturfokus (stiehlt keine Tasten), Buehne darf ueber den Rand ragen.
    private final class BannerPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// `screen` nur fuer Tests (`--demo-window banner`): erlaubt, die Meldung auf einem bestimmten Monitor zu
    /// zeigen. Normal immer der Bildschirm mit der Menueleiste.
    static func show(title: String, subtitle: String, url: URL?, isError: Bool = false,
                     seconds: TimeInterval = 12, hint: String? = nil, screen: NSScreen? = nil) {
        dismiss(animated: false)

        let view = BannerView(title: title, subtitle: subtitle, isError: isError,
                              hint: hint, hasLink: url != nil,
                              onTap: {
            if let url { NSWorkspace.shared.open(url) }
            dismiss(animated: true)
        }, onClose: {
            // ✕ schliesst, ohne den Link zu oeffnen.
            dismiss(animated: true)
        })
        let hosting = NSHostingView(rootView: view)
        hosting.safeAreaRegions = []
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = BannerPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // den Schatten zeichnet die Kapsel selbst (weich, folgt der Form)
        panel.isFloatingPanel = true
        panel.level = .floating          // NACH isFloatingPanel (Falle 11)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting

        if let screen = screen ?? NSScreen.main {
            let f = screen.visibleFrame
            // Glas rechts und oben je `bannerScreenGap` vom Rand, die Buehne ragt darueber hinaus.
            panel.setFrameOrigin(NSPoint(x: (f.maxX - Theme.bannerScreenGap - size.width + Theme.bannerStage).rounded(),
                                         y: (f.maxY - Theme.bannerScreenGap - size.height + Theme.bannerStage).rounded()))
        }
        // Einblenden erst nach dem ersten Zeichnen.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            fade(panel, to: 1)
        }
        current = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak panel] in
            if current === panel { dismiss(animated: true) }
        }
    }

    static func dismiss(animated: Bool) {
        guard let p = current else { return }
        current = nil
        guard animated else { p.orderOut(nil); p.contentView = nil; return }
        fade(p, to: 0) {
            p.orderOut(nil)
            p.contentView = nil
        }
    }

    /// Alpha linear in `Theme.bannerFade` s auf `target`, in 60 Schritten pro Sekunde per Timer (der Animator
    /// lief bei diesem randlosen Fenster nicht an: Alpha blieb 0, siehe PROGRESS Runde 18).
    private static func fade(_ w: NSWindow, to target: CGFloat, completion: (() -> Void)? = nil) {
        let start = w.alphaValue
        let t0 = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
            let k = min(1, Date().timeIntervalSince(t0) / Theme.bannerFade)
            w.alphaValue = start + (target - start) * CGFloat(k)
            if k >= 1 { t.invalidate(); completion?() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// Glas-Kapsel in derselben Glasfarbe wie Panel/Einstellungen (Fehler nur ueber das Warn-Dreieck). Folgt Hell/Dunkel und Glas Normal/Klarer.
struct BannerView: View {
    let title: String
    let subtitle: String
    let isError: Bool
    let hint: String?
    let hasLink: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.bannerRadius, style: .continuous) }
    private var hintText: String? {
        if let hint, !hint.isEmpty { return hint }
        if !isError, hasLink { return L.t("Klick öffnet das Ergebnis", "Click to open the result") }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.s8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "waveform")
                .font(.theme(.normal, .semibold))
                .foregroundStyle(isError ? Theme.warn : Theme.label)
                .frame(width: Theme.bannerIconSize, height: Theme.bannerIconSize)
                .background(Circle().fill(Theme.fillStrong))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.theme(.heading, .semibold)).foregroundStyle(Theme.label).lineLimit(1)
                Text(subtitle).font(.system(size: Theme.bannerSubtitleSize)).foregroundStyle(Theme.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let hintText {
                    Text(hintText).font(.theme(.small)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s16).padding(.vertical, Theme.s16 - Theme.s4)
        .frame(width: Theme.bannerWidth, alignment: .leading)
        .background(glass)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .themeCloseCorner(onClose)   // ✕ auf der linken oberen Ecke, wie im Panel
        .padding(Theme.bannerStage)  // durchsichtiger Rand fuer den Schatten
    }

    /// Gleiches Glas wie Panel und Einstellungen (ThemeGlass), nur mit der Banner-Ecke. Keine Toenung.
    private var glass: some View {
        ThemeGlass(radius: Theme.bannerRadius)
            .shadow(color: .black.opacity(Theme.bannerShadowOpacity), radius: Theme.bannerShadowRadius, y: Theme.bannerShadowY)
    }
}

/// Farben fuer Hex-Werte (nur noch von Tests/Altcode gebraucht).
extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
