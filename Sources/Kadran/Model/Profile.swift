import Foundation

/// A named set of VCP values applied together.
struct Profile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var symbolName: String
    var values: [VCP: UInt16]

    init(id: UUID = UUID(), name: String, symbolName: String, values: [VCP: UInt16]) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.values = values
    }

    /// Built-in profiles.
    ///
    /// The brightness numbers are derived from published viewing standards
    /// rather than picked by eye, then converted through this panel class's
    /// measured SDR maximum of roughly 260 cd/m² at 100%:
    ///
    /// - Day: ISO 9241-303 puts a typical office at 120–150 cd/m².
    /// - Dim: the same guidance puts a dark room at 80–100 cd/m².
    /// - Movie: Rec.709 / BT.1886 mastering reference white is 100 cd/m² in a
    ///   dim surround.
    /// - Bright: ISO guidance for a well-lit room is 200–250 cd/m².
    /// - Night: below the dark-room floor, paired with the warmest colour
    ///   temperature the display offers, since lowering both luminance and
    ///   correlated colour temperature is what reduces melanopic exposure in
    ///   the evening.
    ///
    /// The conversion assumes a display in the same brightness class. On a
    /// panel with a different maximum these are still reasonable starting
    /// points, but they are no longer the cited luminances — which is why they
    /// are a starting set the user edits, not a claim of calibration.
    ///
    /// Colour is set through colour temperature rather than RGB gains. Gains
    /// have a neutral point that is neither documented nor guessable — on this
    /// panel it is 50, not the 100 that looks like "full" — so a profile built
    /// on gains cannot reliably return to neutral.
    ///
    /// There is deliberately no "Game" profile. Game modes change overdrive,
    /// black equalisation, sharpness and saturation; none of that is reachable
    /// over DDC, so such a profile would only be a brightness change wearing a
    /// misleading name. Displays that expose their own picture modes offer the
    /// real thing through the Picture mode control instead.
    static let defaults: [Profile] = [
        Profile(
            name: "Day",
            symbolName: "sun.max",
            values: [.brightness: 50, .colorTemperature: kelvin(6500)]
        ),
        Profile(
            name: "Dim",
            symbolName: "cloud.sun",
            values: [.brightness: 35, .colorTemperature: kelvin(6500)]
        ),
        Profile(
            name: "Movie",
            symbolName: "film",
            values: [.brightness: 40, .colorTemperature: kelvin(6500)]
        ),
        Profile(
            name: "Bright",
            symbolName: "sun.max.fill",
            values: [.brightness: 85, .colorTemperature: kelvin(6500)]
        ),
        Profile(
            name: "Night",
            symbolName: "moon",
            values: [.brightness: 25, .colorTemperature: kelvin(3000)]
        ),
    ]

    /// Colour temperature is stored in kelvin, not in the units VCP 0x0C uses.
    ///
    /// MCCS defines that feature's value as an offset from 3000 K in steps given
    /// by VCP 0x0B, and the step is display-specific. Storing raw units would
    /// make a profile mean a different colour on a display with a different
    /// step, so the conversion happens when the profile is applied, against the
    /// step that display actually reports.
    static func kelvin(_ temperature: Int) -> UInt16 {
        UInt16(temperature)
    }
}

/// `[VCP: UInt16]` is not directly Codable because the key is not a String, so
/// it is encoded as a dictionary of hex-coded feature strings.
extension Profile {
    private enum CodingKeys: String, CodingKey {
        case id, name, symbolName, values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbolName = try container.decode(String.self, forKey: .symbolName)

        let raw = try container.decode([String: UInt16].self, forKey: .values)
        values = raw.reduce(into: [:]) { result, pair in
            guard let code = UInt8(pair.key, radix: 16), let feature = VCP(rawValue: code) else {
                return
            }
            result[feature] = pair.value
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(symbolName, forKey: .symbolName)

        let raw = values.reduce(into: [String: UInt16]()) { result, pair in
            result[String(pair.key.rawValue, radix: 16)] = pair.value
        }
        try container.encode(raw, forKey: .values)
    }
}
