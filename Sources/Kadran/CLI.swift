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
        case "help", "--help", "-h":
            printUsage()
        default:
            // Anything else belongs to AppKit (open, -NSDocumentRevisions..., etc.)
            return false
        }
        return true
    }

    private static func printUsage() {
        print(
            """
            kadran — DDC/CI control for external displays

              kadran list                          List controllable displays
              kadran set <feature> <value>         Set a feature (0–100)
              kadran set <feature> <value> --display <n>

            Features: brightness, contrast, red, green, blue, volume, input,
                      reset-colour, or a raw VCP code such as 0x12
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
        guard let feature = parseFeature(args[0]) else {
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

        DDCService.shared.set(feature, to: value, on: displays[index])

        // The write is queued on a background queue and the bus is asynchronous
        // with no acknowledgement, so give the transaction time to land before
        // the process exits.
        Thread.sleep(forTimeInterval: 0.2)
        print("\(feature.label) -> \(value) on \(displays[index].name)")
    }

    private static func parseFeature(_ token: String) -> VCP? {
        switch token.lowercased() {
        case "brightness", "luminance": return .luminance
        case "contrast": return .contrast
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "volume": return .volume
        case "input": return .inputSource
        case "reset-colour", "reset-color": return .restoreColorDefaults
        default:
            let hex = token.hasPrefix("0x") ? String(token.dropFirst(2)) : token
            guard let code = UInt8(hex, radix: 16) else { return nil }
            return VCP(rawValue: code)
        }
    }
}
