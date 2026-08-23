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

    /// Starting set, chosen to be useful before the user has tuned anything.
    /// Colour gains stay at 100 except in Night, where dropping blue is the
    /// point; raising red or green instead would only cut peak brightness.
    static let defaults: [Profile] = [
        Profile(
            name: "Day",
            symbolName: "sun.max",
            values: [.luminance: 90, .contrast: 50, .red: 100, .green: 100, .blue: 100]
        ),
        Profile(
            name: "Night",
            symbolName: "moon",
            values: [.luminance: 25, .contrast: 45, .red: 100, .green: 92, .blue: 72]
        ),
        Profile(
            name: "Movie",
            symbolName: "film",
            values: [.luminance: 45, .contrast: 65, .red: 100, .green: 100, .blue: 100]
        ),
        Profile(
            name: "Game",
            symbolName: "gamecontroller",
            values: [.luminance: 80, .contrast: 60, .red: 100, .green: 100, .blue: 100]
        ),
    ]
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
