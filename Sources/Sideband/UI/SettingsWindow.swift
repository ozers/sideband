import AppKit
import SwiftUI

/// Owns the settings window.
///
/// SwiftUI's `Settings` scene is the usual route, but it is opened through the
/// `showSettingsWindow:` action, whose selector name has changed between macOS
/// releases and which relies on a responder chain that an accessory-policy app
/// driving a menu bar popover does not reliably have. Hosting the window here
/// removes both dependencies: it either appears or throws, with nothing in
/// between.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show(model: AppModel) {
        if let window {
            bringToFront(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sideband Settings"
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.isReleasedWhenClosed = false  // reused across openings
        window.center()
        window.setFrameAutosaveName("com.github.ozers.Sideband.settings")

        self.window = window
        bringToFront(window)
    }

    /// An accessory app is never the active app, so its windows open behind
    /// whatever the user was looking at unless it activates first.
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
