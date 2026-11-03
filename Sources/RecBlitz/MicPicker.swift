import AppKit
import AVFoundation
import SwiftUI

/// Mikrofon-Menü (03.11.): alle Audio-Eingänge, Häkchen am gewählten, oben
/// „System-Standard". Die Wahl landet in der config.json und gilt für Sprachnotiz
/// UND Bildschirmaufnahme (`Recorder.captureMicID`).
///
/// Bewusst ein echtes NSMenu per Hand geöffnet: ein SwiftUI-`.menu`-Picker hängt
/// im nonactivating Panel (siehe PROGRESS Runde 4).
@MainActor
final class MicMenu: NSObject {
    static let shared = MicMenu()
    var onChange: (() -> Void)?

    func show() {
        let menu = NSMenu(title: L.t("Mikrofon", "Microphone"))
        menu.autoenablesItems = false
        let on = NSMenuItem(title: L.t("Mikrofon aufnehmen", "Record microphone"),
                            action: #selector(toggleMic), keyEquivalent: "")
        on.target = self
        on.state = ConfigStore.shared.captureMicrophone ? .on : .off
        menu.addItem(on)
        menu.addItem(.separator())
        let header = NSMenuItem(title: L.t("Gerät", "Device"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let selected = Recorder.selectedMicID
        let std = AVCaptureDevice.default(for: .audio)?.localizedName
        let stdTitle = L.t("System-Standard", "System default") + (std.map { " (\($0))" } ?? "")
        let stdItem = NSMenuItem(title: stdTitle, action: #selector(pick(_:)), keyEquivalent: "")
        stdItem.target = self
        stdItem.representedObject = ""
        stdItem.state = selected == nil ? .on : .off
        menu.addItem(stdItem)
        menu.addItem(.separator())

        let mics = Recorder.availableMics()
        for d in mics {
            let item = NSMenuItem(title: d.localizedName, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.uniqueID
            item.state = (selected == d.uniqueID) ? .on : .off
            menu.addItem(item)
        }
        // Gewähltes Gerät gerade nicht angesteckt: sichtbar lassen, sonst wirkt
        // die Auswahl verschwunden.
        if let selected, !mics.contains(where: { $0.uniqueID == selected }) {
            let item = NSMenuItem(title: L.t("(nicht angesteckt)", "(not connected)"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.state = .on
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func toggleMic() {
        ConfigStore.shared.captureMicrophone.toggle()
        ConfigStore.shared.save()
        onChange?()
    }

    @objc private func pick(_ item: NSMenuItem) {
        let id = item.representedObject as? String ?? ""
        Recorder.selectedMicID = id.isEmpty ? nil : id
        onChange?()
    }
}

/// Fängt den Rechtsklick auf einer SwiftUI-Fläche ab, ohne Linksklicks zu schlucken.
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView(); v.action = action; return v
    }
    func updateNSView(_ v: CatcherView, context: Context) { v.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            let t = NSApp.currentEvent?.type
            return (t == .rightMouseDown || t == .rightMouseUp) ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { action?() }
    }
}
