import Foundation
import os

/// Persistence for the things a display cannot hold on the app's behalf:
/// profiles, shortcuts and schedule rules.
///
/// Feature values are deliberately absent. They are read from the display, so
/// storing a copy would only create a second version of the truth that goes
/// stale the moment someone touches the monitor's own menu.
struct Store {
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.github.ozers.Sideband", category: "store")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Unwritable features

    /// Features a display advertises but does not apply, remembered per display.
    ///
    /// The discovery costs the user a change that silently does nothing, so it
    /// is worth keeping: without this the warning is forgotten at every launch
    /// and the control looks functional again until they try it once more.
    func unwritableFeatures(for displayKey: String) -> Set<VCP> {
        let raw = defaults.array(forKey: "unwritable.\(displayKey)") as? [Int] ?? []
        return Set(raw.compactMap { UInt8(exactly: $0).flatMap(VCP.init(rawValue:)) })
    }

    func setUnwritableFeatures(_ features: Set<VCP>, for displayKey: String) {
        defaults.set(features.map { Int($0.rawValue) }, forKey: "unwritable.\(displayKey)")
    }

    // MARK: - Profiles

    private let profilesKey = "profiles"

    /// Bumped when the shipped defaults change in a way that makes previously
    /// saved copies wrong.
    ///
    /// Version 3 dropped colour gains from the built-in profiles entirely and
    /// moved colour to colour temperature, after reading the display showed
    /// that gain neutral is 50 rather than the 100 the earlier defaults wrote.
    private static let currentProfilesVersion = 3

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

    /// A profile to apply when Sideband starts, if any.
    ///
    /// Replaces the old "restore the values we remember" setting: with values
    /// read from the display there is nothing to restore, but choosing which
    /// profile the day should start in is still worth having.
    var launchProfileID: UUID? {
        get {
            guard let raw = defaults.string(forKey: "launchProfileID") else { return nil }
            return UUID(uuidString: raw)
        }
        nonmutating set {
            defaults.set(newValue?.uuidString, forKey: "launchProfileID")
        }
    }
}
