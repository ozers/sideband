import Foundation
import os

/// Persistence for everything the monitor cannot tell us.
///
/// This display answers no DDC read, so the last value written is the only
/// record that exists. If it is lost, the sliders come back at a guess and the
/// UI disagrees with the panel until the user touches every control.
struct Store {
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "dev.kadran", category: "store")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Per-display values

    private func valuesKey(_ displayKey: String) -> String { "values.\(displayKey)" }

    func values(for displayKey: String) -> [VCP: UInt16] {
        guard let raw = defaults.dictionary(forKey: valuesKey(displayKey)) as? [String: Int] else {
            return [:]
        }
        return raw.reduce(into: [:]) { result, pair in
            guard let code = UInt8(pair.key, radix: 16),
                  let feature = VCP(rawValue: code),
                  let value = UInt16(exactly: pair.value)
            else { return }
            result[feature] = value
        }
    }

    func setValues(_ values: [VCP: UInt16], for displayKey: String) {
        let raw = values.reduce(into: [String: Int]()) { result, pair in
            result[String(pair.key.rawValue, radix: 16)] = Int(pair.value)
        }
        defaults.set(raw, forKey: valuesKey(displayKey))
    }

    // MARK: - Profiles

    private let profilesKey = "profiles"

    /// Bumped when the shipped defaults change in a way that makes previously
    /// saved copies wrong. Version 2 replaced colour gains of 100 in the
    /// non-Night profiles with an explicit factory colour reset.
    private static let currentProfilesVersion = 2

    func profiles() -> [Profile] {
        let storedVersion = defaults.integer(forKey: "profilesVersion")
        if storedVersion < Self.currentProfilesVersion {
            defaults.set(Self.currentProfilesVersion, forKey: "profilesVersion")
            defaults.removeObject(forKey: profilesKey)
            return Profile.defaults
        }

        guard let data = defaults.data(forKey: profilesKey) else { return Profile.defaults }
        do {
            return try JSONDecoder().decode([Profile].self, from: data)
        } catch {
            logger.error("profiles failed to decode, falling back to defaults: \(error)")
            return Profile.defaults
        }
    }

    func setProfiles(_ profiles: [Profile]) {
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: profilesKey)
        } catch {
            logger.error("profiles failed to encode, not saved: \(error)")
        }
    }

    // MARK: - Hot keys

    private let hotKeysKey = "hotKeys"

    func hotKeys() -> [HotKeyAction: HotKeyBinding] {
        guard let data = defaults.data(forKey: hotKeysKey) else { return [:] }
        do {
            let raw = try JSONDecoder().decode([String: HotKeyBinding].self, from: data)
            return raw.reduce(into: [:]) { result, pair in
                guard let action = HotKeyAction(rawValue: pair.key) else { return }
                result[action] = pair.value
            }
        } catch {
            logger.error("hot keys failed to decode, starting unbound: \(error)")
            return [:]
        }
    }

    func setHotKeys(_ hotKeys: [HotKeyAction: HotKeyBinding]) {
        let raw = hotKeys.reduce(into: [String: HotKeyBinding]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }
        do {
            defaults.set(try JSONEncoder().encode(raw), forKey: hotKeysKey)
        } catch {
            logger.error("hot keys failed to encode, not saved: \(error)")
        }
    }

    /// How much one press of a brightness or contrast shortcut moves the value.
    var hotKeyStep: Int {
        get {
            let stored = defaults.integer(forKey: "hotKeyStep")
            return stored == 0 ? 5 : stored
        }
        nonmutating set { defaults.set(newValue, forKey: "hotKeyStep") }
    }

    // MARK: - Schedule

    private let scheduleKey = "scheduleRules"

    func scheduleRules() -> [ScheduleRule] {
        guard let data = defaults.data(forKey: scheduleKey) else { return [] }
        do {
            return try JSONDecoder().decode([ScheduleRule].self, from: data)
        } catch {
            logger.error("schedule failed to decode, starting empty: \(error)")
            return []
        }
    }

    func setScheduleRules(_ rules: [ScheduleRule]) {
        do {
            defaults.set(try JSONEncoder().encode(rules), forKey: scheduleKey)
        } catch {
            logger.error("schedule failed to encode, not saved: \(error)")
        }
    }

    var isScheduleEnabled: Bool {
        get { defaults.bool(forKey: "isScheduleEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "isScheduleEnabled") }
    }

    // MARK: - Preferences

    /// Whether to push remembered values back to the monitor at launch.
    /// Off by default: on first run there is nothing remembered worth pushing,
    /// and a surprise brightness change at login is a bad first impression.
    var restoresOnLaunch: Bool {
        get { defaults.bool(forKey: "restoresOnLaunch") }
        nonmutating set { defaults.set(newValue, forKey: "restoresOnLaunch") }
    }
}
