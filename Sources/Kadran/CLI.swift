import Foundation

/// Headless entry point, used for scripting and for verifying the DDC layer
/// without launching the UI.
///
///   kadran list
///   kadran set brightness 40
///   kadran set 0x12 55            (raw VCP code)
///   kadran set brightness 40 --display 2
enum CLI {
    /// Returns true when the arguments were handled and the app should not
    /// start its UI.
    static func run(_ arguments: [String] = CommandLine.arguments) -> Bool {
        let args = Array(arguments.dropFirst())
        guard let command = args.first else { return false }

        switch command {
        case "list":
            list()
        case "set":
            set(Array(args.dropFirst()))
        case "caps":
            capabilities()
        case "get":
            get(Array(args.dropFirst()))
        case "help", "--help", "-h":
            printUsage()
        default:
            // Anything else belongs to AppKit (open, -NSDocumentRevisions..., etc.)
            return false
        }
        return true
    }

    private static func get(_ args: [String]) {
        guard let token = args.first, let (code, label) = parseCode(token) else {
            printUsage()
            exit(2)
        }
        let displays = DDCService.shared.discoverDisplays()
        guard let display = displays.first else {
            print("No external display with a DDC bus found.")
            return
        }
        guard let value = DDCService.shared.read(code: code, from: display) else {
            print("\(label): no answer")
            return
        }
        print("\(label): \(value.current) / \(value.maximum)")
    }

    private static func capabilities() {
        let displays = DDCService.shared.discoverDisplays()
        guard let display = displays.first else {
            print("No external display with a DDC bus found.")
            return
        }
        switch DDCService.shared.readCapabilities(of: display) {
        case .string(let caps):
            print(caps)
        case .writeFailed(let code):
            print("\(display.name): the bus refused the request (IOReturn \(hex(code))).")
        case .noReply(let code):
            print("\(display.name): no reply (IOReturn \(hex(code))).")
            print("The display accepts writes but does not answer reads.")
        case .malformed(let bytes):
            print("\(display.name): unexpected reply.")
            print(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
    }

    private static func hex(_ value: Int32) -> String {
        String(format: "0x%08X", value)
    }

    private static func printUsage() {
        print(
            """
            kadran — DDC/CI control for external displays

              kadran list                          List controllable displays
              kadran caps                          Print the capability string
              kadran get <feature>                 Read a feature's current and maximum
              kadran set <feature> <value>         Set a feature (0–100)
              kadran set <feature> <value> --display <n>

            Features: brightness, contrast, red, green, blue, volume, mute,
                      input, preset, temperature, mode, reset-colour, or any raw
                      VCP code such as 0xDC
            """
        )
    }

    private static func list() {
        guard DDCService.shared.isSupported else {
            FileHandle.standardError.write(
                Data("IOAVService is unavailable on this system.\n".utf8)
            )
            exit(1)
        }
        let displays = DDCService.shared.discoverDisplays()
        guard !displays.isEmpty else {
            print("No external display with a DDC bus found.")
            return
        }
        for (index, display) in displays.enumerated() {
            print("[\(index + 1)] \(display.name)  (\(display.persistentKey))")
        }
    }

    private static func set(_ args: [String]) {
        guard args.count >= 2, let value = UInt16(args[1]) else {
            printUsage()
            exit(2)
        }
        guard let (code, label) = parseCode(args[0]) else {
            FileHandle.standardError.write(Data("Unknown feature: \(args[0])\n".utf8))
            exit(2)
        }

        var index = 0
        if let flag = args.firstIndex(of: "--display"), args.indices.contains(flag + 1),
           let n = Int(args[flag + 1]), n >= 1 {
            index = n - 1
        }

        let displays = DDCService.shared.discoverDisplays()
        guard displays.indices.contains(index) else {
            FileHandle.standardError.write(Data("No display at index \(index + 1)\n".utf8))
            exit(1)
        }

        DDCService.shared.setRaw(code: code, to: value, on: displays[index], label: label)

        // The write is queued on a background queue and the bus is asynchronous
        // with no acknowledgement, so give the transaction time to land before
        // the process exits.
        Thread.sleep(forTimeInterval: 0.2)
        print("\(label) -> \(value) on \(displays[index].name)")
    }

    /// Resolves a feature name or a raw VCP code.
    ///
    /// Raw codes are accepted even when they are not in `VCP`, because the
    /// point of probing is to write codes the app does not yet know about.
    private static func parseCode(_ token: String) -> (UInt8, String)? {
        if let feature = parseFeature(token) {
            return (feature.rawValue, feature.label)
        }
        let hex = token.hasPrefix("0x") ? String(token.dropFirst(2)) : token
        guard let code = UInt8(hex, radix: 16) else { return nil }
        return (code, String(format: "0x%02X", code))
    }

    private static func parseFeature(_ token: String) -> VCP? {
        switch token.lowercased() {
        case "brightness", "luminance": return .brightness
        case "contrast": return .contrast
        case "red": return .redGain
        case "green": return .greenGain
        case "blue": return .blueGain
        case "volume": return .volume
        case "input": return .inputSource
        case "preset", "colour-preset", "color-preset": return .colorPreset
        case "temperature", "temp": return .colorTemperature
        case "mode", "picture-mode": return .displayApplication
        case "mute": return .mute
        case "reset-colour", "reset-color": return .restoreColorDefaults
        default: return nil
        }
    }
}
