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

    /// Current values, read from the display rather than remembered.
    ///
    /// Refreshed at launch and whenever the display configuration changes, so a
    /// change made from the monitor's own on-screen menu shows up here too.
    private(set) var values: [VCP: UInt16] = [:]

    /// Ranges as the display reports them. A gain's neutral point and a
    /// feature's maximum are both display-specific, and neither can be assumed:
    /// on the panel this was written against, gain neutral is 50, not 100.
    private(set) var maxima: [VCP: UInt16] = [:]

    /// True while values are being read off the bus, which takes long enough to
    /// be worth showing.
    private(set) var isReading = false

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

        refreshDisplays()
        observeDisplayChanges()
        wireHotKeys()
        wireSchedule()

        // A schedule rule describes what the panel should look like now, so it
        // wins over a fixed launch profile when both are set.
        if store.isScheduleEnabled {
            schedule.applyCurrentRule()
        } else if let id = store.launchProfileID,
                  let profile = profiles.first(where: { $0.id == id }) {
            apply(profile)
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

        Task { await syncFromDisplay() }
    }

    /// Features this display advertises and Kadran knows how to present.
    var supportedFeatures: [VCP] {
        guard let display = selectedDisplay else { return [] }
        return VCP.allCases.filter { display.capabilities.supports($0) }
    }

    func supportedFeatures(in group: VCP.Group, includingAdvanced: Bool = false) -> [VCP] {
        supportedFeatures.filter { $0.group == group && (includingAdvanced || !$0.isAdvanced) }
    }

    func allowedValues(for feature: VCP) -> [UInt8] {
        selectedDisplay?.capabilities.allowedValues(for: feature) ?? []
    }

    func maximum(for feature: VCP) -> UInt16 {
        maxima[feature] ?? 100
    }

    /// Kelvin per unit of `colorTemperature` on this display.
    ///
    /// 50 K is both the most common step and what this panel reports, but it is
    /// read rather than assumed, since getting it wrong silently shifts every
    /// colour temperature the app sets.
    var colorTemperatureStep: Int {
        let reported = Int(values[.colorTemperatureIncrement] ?? 0)
        return reported > 0 ? reported : 50
    }

    /// Converts kelvin to the units VCP 0x0C expects on this display.
    func colorTemperatureUnits(fromKelvin kelvin: Int) -> UInt16 {
        UInt16(max(0, (kelvin - 3000) / colorTemperatureStep))
    }

    func kelvin(fromUnits units: UInt16) -> Int {
        3000 + Int(units) * colorTemperatureStep
    }

    /// Reads every supported feature off the display.
    ///
    /// Off the main actor because each read is a bus round trip of tens of
    /// milliseconds, and a display with a dozen features would otherwise block
    /// the UI for most of a second.
    func syncFromDisplay() async {
        guard let display = selectedDisplay else {
            values = [:]
            maxima = [:]
            return
        }

        isReading = true
        defer { isReading = false }

        let features = supportedFeatures.filter { $0.kind != .command }
        let readings = await Task.detached { [ddc] in
            features.reduce(into: [VCP: DDCService.FeatureValue]()) { result, feature in
                result[feature] = ddc.read(feature, from: display)
            }
        }.value

        values = readings.mapValues(\.current)
        maxima = readings.mapValues(\.maximum)
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

    func selectDisplay(_ id: CGDirectDisplayID) {
        selectedDisplayID = id
        Task { await syncFromDisplay() }
    }

    // MARK: - Control

    func set(_ feature: VCP, to value: UInt16) {
        guard let display = selectedDisplay else { return }
        if feature.kind != .command {
            values[feature] = value
        }
        ddc.set(feature, to: value, on: display)
    }

    /// Sends a command feature, then re-reads, since a reset changes values
    /// this app never wrote.
    func run(_ command: VCP) {
        guard let display = selectedDisplay else { return }
        ddc.set(command, to: 1, on: display)
        Task {
            // Give the display time to settle before believing what it reports.
            try? await Task.sleep(for: .milliseconds(500))
            await syncFromDisplay()
        }
    }

    /// Nudges a feature by `delta`, clamped to its range. Backs the keyboard
    /// shortcuts, where the caller has no idea what the current value is.
    func adjust(_ feature: VCP, by delta: Int) {
        guard let current = values[feature] else { return }
        let bounded = min(max(Int(current) + delta, 0), Int(maximum(for: feature)))
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
        case .brightnessUp: adjust(.brightness, by: step)
        case .brightnessDown: adjust(.brightness, by: -step)
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
        // Only what this display advertises: a profile is portable between
        // monitors, so it may well name features this one does not implement.
        for (feature, stored) in profile.values.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where display.capabilities.supports(feature) {
            // Colour temperature is stored in kelvin so a profile means the same
            // thing on any display; every other feature is stored raw.
            let value = feature == .colorTemperature
                ? colorTemperatureUnits(fromKelvin: Int(stored))
                : stored
            let clamped = min(value, maximum(for: feature))
            if feature.kind != .command {
                values[feature] = clamped
            }
            ddc.set(feature, to: clamped, on: display)
        }
    }

    /// Captures the current values as a new profile.
    func captureProfile(named name: String, symbolName: String = "square.on.square") {
        profiles.append(Profile(name: name, symbolName: symbolName, values: capturedValues()))
        store.setProfiles(profiles)
    }

    /// Current values in the form profiles store them.
    private func capturedValues() -> [VCP: UInt16] {
        VCP.profilable.reduce(into: [VCP: UInt16]()) { result, feature in
            guard let value = values[feature] else { return }
            result[feature] = feature == .colorTemperature
                ? UInt16(kelvin(fromUnits: value))
                : value
        }
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
        profiles[index].values = capturedValues()
        store.setProfiles(profiles)
    }

    var launchProfileID: UUID? {
        get { store.launchProfileID }
        set { store.launchProfileID = newValue }
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
