import AppKit
import Combine
import CoreGraphics
import Observation
import os

/// Everything the menu bar UI binds to.
@MainActor
@Observable
final class AppModel {
    private(set) var displays: [DDCDisplay] = []
    var selectedDisplayID: CGDirectDisplayID?

    /// The values believed to be on the panel right now. Believed, not known:
    /// changing brightness from the monitor's own OSD leaves this stale, and
    /// nothing can detect that.
    private(set) var values: [VCP: UInt16] = [:]

    private(set) var profiles: [Profile] = []
    private(set) var hotKeys: [HotKeyAction: HotKeyBinding] = [:]
    private(set) var scheduleRules: [ScheduleRule] = []

    /// Set when the private IOAVService symbols are missing, so the UI can say
    /// why it is doing nothing instead of silently failing.
    private(set) var unsupportedReason: String?

    private let ddc = DDCService.shared
    private let store = Store()
    private let logger = Logger(subsystem: "dev.kadran", category: "model")
    private let screenObserver = ScreenObserverToken()
    private let schedule = ScheduleEngine()

    var selectedDisplay: DDCDisplay? {
        displays.first { $0.id == selectedDisplayID } ?? displays.first
    }

    init() {
        profiles = store.profiles()
        hotKeys = store.hotKeys()
        scheduleRules = store.scheduleRules()

        guard ddc.isSupported else {
            unsupportedReason = """
                This build of macOS does not expose the private IOAVService API \
                that DDC/CI control depends on.
                """
            return
        }

        refreshDisplays(applyRemembered: store.restoresOnLaunch)
        observeDisplayChanges()
        wireHotKeys()
        wireSchedule()

        // A rule that came due while the app was closed still describes what
        // the panel should look like now, so it is applied at launch too.
        if store.isScheduleEnabled {
            schedule.applyCurrentRule()
        }
    }

    // MARK: - Displays

    /// Rescans the bus. Plugging a cable creates a new `IOAVService`, so the
    /// old handles are dead after any reconfiguration and must be rebuilt.
    func refreshDisplays(applyRemembered: Bool = false) {
        displays = ddc.discoverDisplays()

        if let selectedDisplayID, !displays.contains(where: { $0.id == selectedDisplayID }) {
            self.selectedDisplayID = nil
        }
        if selectedDisplayID == nil {
            selectedDisplayID = displays.first?.id
        }

        loadValues()

        if applyRemembered, let display = selectedDisplay {
            for feature in VCP.restorable {
                if let value = values[feature] {
                    ddc.set(feature, to: value, on: display)
                }
            }
        }
    }

    private func observeDisplayChanges() {
        screenObserver.token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshDisplays(applyRemembered: false)
            }
        }
    }

    private func loadValues() {
        guard let display = selectedDisplay else {
            values = [:]
            return
        }
        var loaded = store.values(for: display.persistentKey)

        // A slider needs a position even before anything has been written, so
        // unknown features start at the DDC/CI midpoint rather than at zero.
        for feature in VCP.sliders where loaded[feature] == nil {
            loaded[feature] = feature == .luminance ? 50 : 50
        }
        values = loaded
    }

    func selectDisplay(_ id: CGDirectDisplayID) {
        selectedDisplayID = id
        loadValues()
    }

    // MARK: - Control

    func set(_ feature: VCP, to value: UInt16) {
        guard let display = selectedDisplay else { return }
        values[feature] = value
        ddc.set(feature, to: value, on: display)
        store.setValues(values, for: display.persistentKey)
    }

    /// Nudges a feature by `delta`, clamped to its range. Backs the keyboard
    /// shortcuts, where the caller has no idea what the current value is.
    func adjust(_ feature: VCP, by delta: Int) {
        let current = Int(values[feature] ?? 50)
        let bounded = min(max(current + delta, 0), Int(feature.maxValue))
        set(feature, to: UInt16(bounded))
    }

    // MARK: - Hot keys

    private func wireHotKeys() {
        HotKeyCenter.shared.onTrigger = { [weak self] action in
            self?.perform(action)
        }
        HotKeyCenter.shared.apply(hotKeys)
    }

    func setHotKey(_ binding: HotKeyBinding?, for action: HotKeyAction) {
        if let binding {
            // A combination can only drive one action, so claiming it for a new
            // one has to release it from the old.
            for (other, existing) in hotKeys where existing == binding && other != action {
                hotKeys[other] = nil
            }
            hotKeys[action] = binding
        } else {
            hotKeys[action] = nil
        }
        store.setHotKeys(hotKeys)
        HotKeyCenter.shared.apply(hotKeys)
    }

    /// True when the binding exists but the system refused to grant it,
    /// normally because another app claimed the combination first.
    func isHotKeyConflicted(_ action: HotKeyAction) -> Bool {
        hotKeys[action] != nil && !HotKeyCenter.shared.isRegistered(action)
    }

    var hotKeyStep: Int {
        get { store.hotKeyStep }
        set { store.hotKeyStep = max(1, min(newValue, 50)) }
    }

    private func perform(_ action: HotKeyAction) {
        let step = store.hotKeyStep
        switch action {
        case .brightnessUp: adjust(.luminance, by: step)
        case .brightnessDown: adjust(.luminance, by: -step)
        case .contrastUp: adjust(.contrast, by: step)
        case .contrastDown: adjust(.contrast, by: -step)
        case .cycleProfile: cycleProfile()
        }
    }

    private func cycleProfile() {
        guard !profiles.isEmpty else { return }
        let next = (lastAppliedProfileIndex.map { $0 + 1 } ?? 0) % profiles.count
        apply(profiles[next])
    }

    private var lastAppliedProfileIndex: Int?

    // MARK: - Schedule

    private func wireSchedule() {
        schedule.onFire = { [weak self] rule in
            guard let self, let profile = profiles.first(where: { $0.id == rule.profileID })
            else { return }
            apply(profile)
        }
        schedule.update(rules: scheduleRules, isEnabled: store.isScheduleEnabled)
    }

    var isScheduleEnabled: Bool {
        get { store.isScheduleEnabled }
        set {
            store.isScheduleEnabled = newValue
            schedule.update(rules: scheduleRules, isEnabled: newValue)
            if newValue { schedule.applyCurrentRule() }
        }
    }

    func addScheduleRule(profileID: UUID, hour: Int, minute: Int) {
        scheduleRules.append(ScheduleRule(profileID: profileID, hour: hour, minute: minute))
        persistSchedule()
    }

    func updateScheduleRule(_ rule: ScheduleRule) {
        guard let index = scheduleRules.firstIndex(where: { $0.id == rule.id }) else { return }
        scheduleRules[index] = rule
        persistSchedule()
    }

    func deleteScheduleRule(_ rule: ScheduleRule) {
        scheduleRules.removeAll { $0.id == rule.id }
        persistSchedule()
    }

    private func persistSchedule() {
        store.setScheduleRules(scheduleRules)
        schedule.update(rules: scheduleRules, isEnabled: store.isScheduleEnabled)
    }

    // MARK: - Login item

    var launchesAtLogin: Bool {
        get { LoginItem.isEnabled }
        set { LoginItem.setEnabled(newValue) }
    }

    // MARK: - Profiles

    func apply(_ profile: Profile) {
        lastAppliedProfileIndex = profiles.firstIndex(where: { $0.id == profile.id })
        guard let display = selectedDisplay else { return }
        for (feature, value) in profile.values {
            values[feature] = value
            ddc.set(feature, to: value, on: display)
        }
        store.setValues(values, for: display.persistentKey)
    }

    /// Captures the current values as a new profile.
    func captureProfile(named name: String, symbolName: String = "square.on.square") {
        let captured = VCP.restorable.reduce(into: [VCP: UInt16]()) { result, feature in
            result[feature] = values[feature]
        }
        profiles.append(Profile(name: name, symbolName: symbolName, values: captured))
        store.setProfiles(profiles)
    }

    func deleteProfile(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        store.setProfiles(profiles)

        // Rules pointing at a deleted profile would fire and do nothing.
        let orphaned = scheduleRules.filter { $0.profileID == profile.id }
        if !orphaned.isEmpty {
            scheduleRules.removeAll { $0.profileID == profile.id }
            persistSchedule()
        }
    }

    func renameProfile(_ profile: Profile, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].name = name
        store.setProfiles(profiles)
    }

    /// Overwrites a profile with the values currently on screen.
    func updateProfileToCurrentValues(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].values = VCP.restorable.reduce(into: [VCP: UInt16]()) { result, feature in
            result[feature] = values[feature]
        }
        store.setProfiles(profiles)
    }

    var restoresOnLaunch: Bool {
        get { store.restoresOnLaunch }
        set { store.restoresOnLaunch = newValue }
    }
}


/// Holds a NotificationCenter observer token and unregisters it when the model
/// goes away.
///
/// A plain stored property on `AppModel` cannot do this: the model is main-actor
/// isolated, and `deinit` runs outside that isolation, so it may not touch the
/// model's own state. Parking the token in its own object moves the cleanup to a
/// deinit that has no isolation to violate.
private final class ScreenObserverToken: @unchecked Sendable {
    var token: Any?

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
