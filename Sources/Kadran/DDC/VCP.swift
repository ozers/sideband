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

    var label: String {
        switch self {
        case .luminance: return "Brightness"
        case .contrast: return "Contrast"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        case .volume: return "Volume"
        case .inputSource: return "Input"
        }
    }

    var symbolName: String {
        switch self {
        case .luminance: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .red, .green, .blue: return "drop"
        case .volume: return "speaker.wave.2"
        case .inputSource: return "cable.connector"
        }
    }

    /// Upper bound used by the UI. The monitor never answers a "max" read, so
    /// these are the DDC/CI conventional maxima rather than measured values.
    var maxValue: UInt16 {
        switch self {
        case .inputSource: return 255
        default: return 100
        }
    }

    /// Features presented as sliders, in display order.
    static let sliders: [VCP] = [.luminance, .contrast, .red, .green, .blue, .volume]

    /// Features restored on launch and applied by profiles.
    /// Input source is deliberately excluded: writing it can blank the screen
    /// and strand the user on a dead input.
    static let restorable: [VCP] = [.luminance, .contrast, .red, .green, .blue]
}
