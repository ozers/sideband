import Foundation

/// A DDC/CI VCP feature this app can drive.
///
/// Only features confirmed writable on the MPG 491C are surfaced by default;
/// `volume` is included but unverified, because the monitor's speakers were
/// never exercised during the capability probe.
enum VCP: UInt8, CaseIterable, Codable, Sendable {
    case luminance = 0x10
    case contrast = 0x12
    case red = 0x16
    case green = 0x18
    case blue = 0x1A
    case volume = 0x62
    case inputSource = 0x60

    /// Selects a colour preset. MCCS defines the values, so they mean the same
    /// thing on any monitor that implements the feature:
    /// 0x01 sRGB, 0x02 native, 0x03 4000K, 0x04 5000K, 0x05 6500K,
    /// 0x06 7500K, 0x07 8200K, 0x08 9300K, 0x0B–0x0D user presets.
    ///
    /// Preferred over the RGB gain registers for anything colour-temperature
    /// shaped: the values are defined rather than guessed, and returning to
    /// neutral is a matter of selecting 6500K rather than hoping a gain of 100
    /// happens to be the neutral point.
    case colorPreset = 0x14

    /// Sharpness / edge enhancement. Standard in MCCS, but the value range is
    /// vendor-specific and unreadable here, so the slider spans the full byte.
    case sharpness = 0x87

    /// How the panel maps a non-native signal — the "screen size" or aspect
    /// entry in most OSDs. MCCS values: 1 no scaling, 2 max image without
    /// aspect distortion, 3 max image with distortion, 4 max vertical,
    /// 5 max horizontal, 6 aspect-correct linear expansion.
    case displayScaling = 0x86

    /// Write-only command, not a value: any write tells the monitor to reset
    /// its colour settings to the factory state.
    ///
    /// This is the only reliable way back to neutral colour. Writing 100 to
    /// each gain does not do it — the neutral point of a gain register is
    /// vendor-specific and unreadable on a display that answers no reads, and
    /// touching a gain at all switches most monitors into a custom colour mode
    /// that a factory preset cannot be re-entered from by writing gains.
    case restoreColorDefaults = 0x08

    var label: String {
        switch self {
        case .luminance: return "Brightness"
        case .contrast: return "Contrast"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        case .volume: return "Volume"
        case .colorPreset: return "Colour preset"
        case .sharpness: return "Sharpness"
        case .displayScaling: return "Screen size"
        case .inputSource: return "Input"
        case .restoreColorDefaults: return "Reset colour"
        }
    }

    var symbolName: String {
        switch self {
        case .luminance: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .red, .green, .blue: return "drop"
        case .volume: return "speaker.wave.2"
        case .colorPreset: return "thermometer.sun"
        case .sharpness: return "triangle"
        case .displayScaling: return "aspectratio"
        case .inputSource: return "cable.connector"
        case .restoreColorDefaults: return "arrow.counterclockwise"
        }
    }

    /// Upper bound used by the UI. The monitor never answers a "max" read, so
    /// these are the DDC/CI conventional maxima rather than measured values.
    var maxValue: UInt16 {
        switch self {
        case .inputSource, .restoreColorDefaults, .colorPreset, .sharpness, .displayScaling:
            return 255
        default: return 100
        }
    }

    /// True for features that are commands rather than values: writing one
    /// performs an action, and there is no state afterwards worth remembering.
    var isCommand: Bool { self == .restoreColorDefaults }

    /// Features presented as sliders, in display order.
    static let sliders: [VCP] = [.luminance, .contrast, .red, .green, .blue, .volume]

    /// Features restored on launch and applied by profiles.
    /// Input source is deliberately excluded: writing it can blank the screen
    /// and strand the user on a dead input.
    static let restorable: [VCP] = [.luminance, .contrast, .red, .green, .blue]
}
