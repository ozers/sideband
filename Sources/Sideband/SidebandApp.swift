import AppKit
import SwiftUI

/// Chooses between the headless CLI and the menu bar UI.
///
/// `App` supplies its own `main()`, so the choice cannot live inside `SidebandApp`
/// without recursing into it. A separate entry point keeps both paths in one
/// binary, which is what makes `sideband set …` usable for scripting and for
/// testing the DDC layer without a UI.
@main
enum Entry {
    static func main() {
        if CLI.run() { return }
        SidebandApp.main()
    }
}

struct SidebandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Sideband", systemImage: "dial.medium") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no menu bar menus of its own.
        // Also set in Info.plist via LSUIElement; doing both keeps `swift run`
        // (which has no bundle) behaving the same as the packaged app.
        NSApp.setActivationPolicy(.accessory)
    }
}
