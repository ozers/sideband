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
        case .inputSource: return "cable.connector"
        case .restoreColorDefaults: return "arrow.counterclockwise"
        }
    }

    /// Upper bound used by the UI. The monitor never answers a "max" read, so
    /// these are the DDC/CI conventional maxima rather than measured values.
    var maxValue: UInt16 {
        switch self {
        case .inputSource, .restoreColorDefaults: return 255
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
