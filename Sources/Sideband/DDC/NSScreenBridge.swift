import AppKit
import CoreGraphics

/// Localized product names for attached displays, keyed by `CGDirectDisplayID`.
///
/// Kept apart from `DDCService` so the IOKit layer stays free of AppKit.
enum NSScreenBridge {
    static func localizedNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            names[CGDirectDisplayID(truncating: number)] = screen.localizedName
        }
        return names
    }
}
