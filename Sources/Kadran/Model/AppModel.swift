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

    /// Set when the private IOAVService symbols are missing, so the UI can say
    /// why it is doing nothing instead of silently failing.
    private(set) var unsupportedReason: String?

    private let ddc = DDCService.shared
    private let store = Store()
    private let logger = Logger(subsystem: "dev.kadran", category: "model")
    private let screenObserver = ScreenObserverToken()

    var selectedDisplay: DDCDisplay? {
        displays.first { $0.id == selectedDisplayID } ?? displays.first
    }

    init() {
        profiles = store.profiles()

        guard ddc.isSupported else {
            unsupportedReason = """
                This build of macOS does not expose the private IOAVService API \
                that DDC/CI control depends on.
                """
            return
        }

        refreshDisplays(applyRemembered: store.restoresOnLaunch)
        observeDisplayChanges()
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

    // MARK: - Profiles

    func apply(_ profile: Profile) {
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
