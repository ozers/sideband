import Foundation

/// A DDC/CI VCP feature.
///
/// Membership here means Sideband knows how to present the feature, not that any
/// particular display implements it. What a display actually supports comes from
/// its capability string; see `DisplayCapabilities`.
enum VCP: UInt8, CaseIterable, Codable, Sendable {
    // Values
    case brightness = 0x10
    case contrast = 0x12
    case colorTemperature = 0x0C
    case colorPreset = 0x14
    case redGain = 0x16
    case greenGain = 0x18
    case blueGain = 0x1A
    case redBlackLevel = 0x6C
    case greenBlackLevel = 0x6E
    case blueBlackLevel = 0x70
    case volume = 0x62
    case mute = 0x8D
    case displayApplication = 0xDC
    case inputSource = 0x60

    // Read-only
    case usageTime = 0xC0

    /// Kelvin per unit of `colorTemperature`. Read to interpret that feature;
    /// never shown, since a step size is not something anyone sets.
    case colorTemperatureIncrement = 0x0B

    // Commands
    case restoreFactoryDefaults = 0x04
    case restoreBrightnessContrast = 0x05
    case restoreColorDefaults = 0x08

    /// How a feature is presented and written.
    enum Kind {
        /// A number over a range, shown as a slider.
        case continuous
        /// One of a fixed set, shown as a menu. Which values are offered comes
        /// from the display's capability string, not from this app.
        case enumerated
        /// Writing any value performs an action; there is no state to show.
        case command
        /// Reported by the display, never written.
        case readOnly
    }

    var kind: Kind {
        switch self {
        case .restoreFactoryDefaults, .restoreBrightnessContrast, .restoreColorDefaults:
            return .command
        case .colorPreset, .displayApplication, .inputSource, .mute:
            return .enumerated
        case .usageTime, .colorTemperatureIncrement:
            return .readOnly
        default:
            return .continuous
        }
    }

    var label: String {
        switch self {
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .colorTemperature: return "Colour temperature"
        case .colorPreset: return "Colour preset"
        case .redGain: return "Red"
        case .greenGain: return "Green"
        case .blueGain: return "Blue"
        case .redBlackLevel: return "Red black level"
        case .greenBlackLevel: return "Green black level"
        case .blueBlackLevel: return "Blue black level"
        case .volume: return "Volume"
        case .mute: return "Mute"
        case .displayApplication: return "Picture mode"
        case .inputSource: return "Input"
        case .usageTime: return "Panel hours"
        case .colorTemperatureIncrement: return "Colour temperature step"
        case .restoreFactoryDefaults: return "Reset everything"
        case .restoreBrightnessContrast: return "Reset brightness and contrast"
        case .restoreColorDefaults: return "Reset colour"
        }
    }

    var symbolName: String {
        switch self {
        case .brightness: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .colorTemperature: return "thermometer.sun"
        case .colorPreset: return "swatchpalette"
        case .redGain, .greenGain, .blueGain: return "drop"
        case .redBlackLevel, .greenBlackLevel, .blueBlackLevel: return "drop.halffull"
        case .volume: return "speaker.wave.2"
        case .mute: return "speaker.slash"
        case .displayApplication: return "photo"
        case .inputSource: return "cable.connector"
        case .usageTime, .colorTemperatureIncrement: return "clock"
        case .restoreFactoryDefaults, .restoreBrightnessContrast, .restoreColorDefaults:
            return "arrow.counterclockwise"
        }
    }

    /// Grouping for the UI, so related controls stay together.
    enum Group: Int, CaseIterable {
        case picture, colour, calibration, audio, source, info

        var title: String {
            switch self {
            case .picture: return "Picture"
            case .colour: return "Colour"
            case .calibration: return "Calibration"
            case .audio: return "Audio"
            case .source: return "Source"
            case .info: return "Display"
            }
        }
    }

    var group: Group {
        switch self {
        case .brightness, .contrast, .displayApplication, .restoreBrightnessContrast:
            return .picture
        case .colorTemperature, .colorPreset, .restoreColorDefaults: return .colour
        case .redGain, .greenGain, .blueGain,
             .redBlackLevel, .greenBlackLevel, .blueBlackLevel:
            return .calibration
        case .volume, .mute: return .audio
        case .inputSource: return .source
        case .usageTime, .colorTemperatureIncrement, .restoreFactoryDefaults:
            return .info
        }
    }

    /// Features hidden until the user asks for them.
    ///
    /// Black levels shift the bottom of the gamma curve and are easy to set
    /// wrong in a way that looks like a broken monitor rather than a bad
    /// setting, and switching input can leave the Mac looking at a display that
    /// no longer shows it.
    var isAdvanced: Bool {
        switch self {
        case .redBlackLevel, .greenBlackLevel, .blueBlackLevel, .inputSource,
             .restoreFactoryDefaults, .colorTemperatureIncrement:
            return true
        default:
            return false
        }
    }

    /// Features a profile may carry.
    ///
    /// Input is excluded: a profile that changes input can leave the user
    /// staring at a blank panel with no way back to the app.
    static var profilable: [VCP] {
        allCases.filter { $0.kind != .readOnly && $0 != .inputSource && $0.kind != .command }
    }

    /// Values to offer when a display advertises an enumerated feature without
    /// listing which values it takes.
    ///
    /// The capability string is allowed to name a code with no value list, and
    /// this display does exactly that for mute. Falling back to what MCCS
    /// defines is better than showing an empty menu, and a value the display
    /// rejects is caught by write verification rather than by guesswork here.
    var fallbackValues: [UInt8] {
        switch self {
        case .mute: return [0x01, 0x02]
        case .colorPreset: return [0x01, 0x04, 0x05, 0x06, 0x08, 0x0B]
        case .displayApplication: return Array(0x00...0x08)
        case .inputSource: return [0x0F, 0x10, 0x11, 0x12, 0x1B]
        default: return []
        }
    }

    /// Names for the values of an enumerated feature, where MCCS defines them.
    ///
    /// Only the values a display advertises are ever shown, so an entry missing
    /// here appears by its raw number rather than being hidden.
    func valueName(_ value: UInt8) -> String? {
        switch self {
        case .colorPreset:
            switch value {
            case 0x01: return "sRGB"
            case 0x02: return "Native"
            case 0x03: return "4000 K"
            case 0x04: return "5000 K"
            case 0x05: return "6500 K"
            case 0x06: return "7500 K"
            case 0x07: return "8200 K"
            case 0x08: return "9300 K"
            case 0x09: return "10000 K"
            case 0x0A: return "11500 K"
            case 0x0B: return "User 1"
            case 0x0C: return "User 2"
            case 0x0D: return "User 3"
            default: return nil
            }
        case .displayApplication:
            switch value {
            case 0x00: return "Standard"
            case 0x01: return "Productivity"
            case 0x02: return "Mixed"
            case 0x03: return "Movie"
            case 0x04: return "User"
            case 0x05: return "Games"
            case 0x06: return "Sports"
            case 0x07: return "Professional"
            case 0x08: return "Text"
            case 0x09: return "Video"
            case 0x0A: return "Photo"
            default: return nil
            }
        case .inputSource:
            switch value {
            case 0x01: return "VGA 1"
            case 0x03: return "DVI 1"
            case 0x04: return "DVI 2"
            case 0x0F: return "DisplayPort 1"
            case 0x10: return "DisplayPort 2"
            case 0x11: return "HDMI 1"
            case 0x12: return "HDMI 2"
            case 0x1B: return "USB-C"
            default: return nil
            }
        case .mute:
            switch value {
            case 0x01: return "Muted"
            case 0x02: return "Unmuted"
            default: return nil
            }
        default:
            return nil
        }
    }
}
