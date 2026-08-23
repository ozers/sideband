import Foundation

/// What a display says it can do, parsed from its DDC/CI capability string.
///
/// This is what makes the UI honest on hardware nobody tested against: controls
/// appear because the display advertised the feature, not because a table
/// somewhere claims this model supports it. A monitor that answers no capability
/// request gets a conservative fallback instead.
struct DisplayCapabilities: Sendable {
    /// Model name as the display reports it, which is often not the marketing
    /// name — this monitor calls itself FALCON.
    var model: String?
    var mccsVersion: String?

    /// Advertised VCP codes, mapped to the values each one permits. An empty
    /// array means the code is supported but takes a range rather than a list.
    var codes: [UInt8: [UInt8]] = [:]

    /// True when the string was parsed from a real answer rather than assumed.
    var isFromDisplay: Bool = true

    func supports(_ feature: VCP) -> Bool {
        codes[feature.rawValue] != nil
    }

    /// Values a display permits for an enumerated feature, in the order it
    /// listed them.
    func allowedValues(for feature: VCP) -> [UInt8] {
        codes[feature.rawValue] ?? []
    }

    init(
        model: String? = nil,
        mccsVersion: String? = nil,
        codes: [UInt8: [UInt8]] = [:],
        isFromDisplay: Bool = true
    ) {
        self.model = model
        self.mccsVersion = mccsVersion
        self.codes = codes
        self.isFromDisplay = isFromDisplay
    }

    /// Used when a display answers no capability request. Assumes only the two
    /// features that are near-universal, so an unknown monitor gets a small
    /// working UI rather than a wall of controls that quietly do nothing.
    static let assumed = DisplayCapabilities(
        model: nil,
        mccsVersion: nil,
        codes: [VCP.brightness.rawValue: [], VCP.contrast.rawValue: []],
        isFromDisplay: false
    )

    /// Parses a capability string of the form
    /// `(prot(monitor)type(lcd)model(X)cmds(…)vcp(10 12 14(01 05) …)…)`.
    init?(parsing string: String) {
        guard let vcpBody = Self.section(named: "vcp", in: string) else { return nil }

        model = Self.section(named: "model", in: string)
        mccsVersion = Self.section(named: "mccs_ver", in: string)
        codes = Self.parseVCPList(vcpBody)
        isFromDisplay = true

        guard !codes.isEmpty else { return nil }
    }

    /// Extracts the body of `name(...)`, honouring nesting so that
    /// `vcp(… 14(01 05) …)` returns everything up to its own closing bracket.
    private static func section(named name: String, in string: String) -> String? {
        guard let range = string.range(of: name + "(") else { return nil }

        var depth = 1
        var index = range.upperBound
        var body = ""

        while index < string.endIndex, depth > 0 {
            let character = string[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            body.append(character)
            index = string.index(after: index)
        }

        return depth == 0 ? body : nil
    }

    /// Reads `10 12 14(01 04 05) DC(00 01)` into codes and their value lists.
    private static func parseVCPList(_ body: String) -> [UInt8: [UInt8]] {
        var result: [UInt8: [UInt8]] = [:]
        var token = ""
        var pendingCode: UInt8?
        var values: [UInt8] = []
        var insideValues = false

        func flushToken() {
            defer { token = "" }
            guard let byte = UInt8(token, radix: 16) else { return }
            if insideValues {
                values.append(byte)
            } else {
                if let code = pendingCode { result[code] = [] }
                pendingCode = byte
            }
        }

        for character in body {
            switch character {
            case "(":
                flushToken()
                insideValues = true
                values = []
            case ")":
                flushToken()
                if let code = pendingCode { result[code] = values }
                pendingCode = nil
                values = []
                insideValues = false
            case " ", "\t", "\n":
                flushToken()
            default:
                token.append(character)
            }
        }
        flushToken()
        if let code = pendingCode { result[code] = [] }

        return result
    }
}
