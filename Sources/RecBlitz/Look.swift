import AppKit
import SwiftUI

/// Runde 115: Aussehen (System / Hell / Dunkel) und Glas (Normal / Klarer) als Einstellung.
/// Standard bleibt Dunkel + Normal (wie vor Runde 115). Wirkt sofort: `apply()` setzt `NSApp.appearance`,
/// alle Fenster erben es; das Glas liest `Look.glassKey` live per @AppStorage.
enum Look {
    static let appearanceKey = "rbAppearance"
    static let glassKey = "rbGlass"

    enum Mode: String { case system, light, dark }
    enum Glass: String { case normal, clear }

    static var mode: Mode {
        if ProcessInfo.processInfo.environment["RB_FORCE_LIGHT"] != nil { return .light }
        if Demo.on && CommandLine.arguments.contains("--light") { return .light }
        return Mode(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .dark
    }

    @MainActor static func apply() {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Für den Selbsttest: passt das Aussehen des Fensters zur Einstellung?
    @MainActor static func matches(_ w: NSWindow) -> Bool {
        let dark = w.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch mode {
        case .dark: return dark
        case .light: return !dark
        case .system: return true
        }
    }
}
