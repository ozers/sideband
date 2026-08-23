import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettings(model: model)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            ProfileSettings(model: model)
                .tabItem { Label("Profiles", systemImage: "square.on.square") }
            ScheduleSettings(model: model)
                .tabItem { Label("Schedule", systemImage: "clock") }
        }
        .frame(width: 460, height: 340)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var loginItemFailed = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: launchBinding)
                if loginItemFailed {
                    Text(
                        """
                        macOS refused the login item. This happens when the app \
                        is run from a build directory rather than from a bundle \
                        in /Applications.
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Picker("Apply at launch", selection: launchProfileBinding) {
                    Text("Nothing").tag(UUID?.none)
                    ForEach(model.profiles) { profile in
                        Text(profile.name).tag(UUID?.some(profile.id))
                    }
                }
                Text(
                    """
                    Current values are read from the display, so nothing needs \
                    restoring. This is for starting the day in a chosen profile.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Displays") {
                if model.displays.isEmpty {
                    Text("No external display with a DDC bus found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.displays) { display in
                        LabeledContent(display.name) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(display.capabilities.model ?? display.persistentKey)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Text(capabilitySummary(display))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button("Rescan") { model.refreshDisplays() }
            }
        }
        .formStyle(.grouped)
    }

    /// Says where the feature list came from, because "12 features" and
    /// "assumed, the display never answered" are very different situations for
    /// anyone wondering why a control is missing.
    private func capabilitySummary(_ display: DDCDisplay) -> String {
        let capabilities = display.capabilities
        guard capabilities.isFromDisplay else {
            return "no capability string; assuming brightness and contrast"
        }
        let version = capabilities.mccsVersion.map { "MCCS \($0), " } ?? ""
        return "\(version)\(capabilities.codes.count) features reported"
    }

    private var launchProfileBinding: Binding<UUID?> {
        Binding(
            get: { model.launchProfileID },
            set: { model.launchProfileID = $0 }
        )
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { model.launchesAtLogin },
            set: { wanted in
                model.launchesAtLogin = wanted
                loginItemFailed = model.launchesAtLogin != wanted
            }
        )
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.label) {
                        HStack(spacing: 6) {
                            if model.isHotKeyConflicted(action) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("Another app already uses this combination.")
                            }
                            HotKeyRecorder(
                                binding: model.hotKeys[action],
                                isConflicted: model.isHotKeyConflicted(action)
                            ) { binding in
                                model.setHotKey(binding, for: action)
                            }
                            .frame(width: 120, height: 22)
                        }
                    }
                }
            } footer: {
                Text("Click a field and press the combination. ⌫ clears it, ⎋ cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(
                    "Step size: \(model.hotKeyStep)",
                    value: Binding(get: { model.hotKeyStep }, set: { model.hotKeyStep = $0 }),
                    in: 1...50
                )
            } footer: {
                Text("How far one press moves brightness or contrast.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Profiles

private struct ProfileSettings: View {
    @Bindable var model: AppModel
    @State private var selection: Profile.ID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(model.profiles) { profile in
                    HStack {
                        Image(systemName: profile.symbolName)
                            .frame(width: 18)
                        Text(profile.name)
                        Spacer()
                        Text(summary(of: profile))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(profile.id)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    model.captureProfile(named: "New profile")
                } label: {
                    Image(systemName: "plus")
                }
                .help("Capture the current values as a new profile")

                Button {
                    if let profile = selected { model.deleteProfile(profile) }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selected == nil)

                Spacer()

                Button("Overwrite with current values") {
                    if let profile = selected { model.updateProfileToCurrentValues(profile) }
                }
                .disabled(selected == nil)
            }
            .padding(8)
        }
    }

    private var selected: Profile? {
        model.profiles.first { $0.id == selection }
    }

    /// Brightness and contrast only: the full VCP set does not fit on one row,
    /// and those two are what distinguishes profiles in practice.
    private func summary(of profile: Profile) -> String {
        let brightness = profile.values[.brightness].map(String.init) ?? "–"
        let contrast = profile.values[.contrast].map(String.init) ?? "–"
        return "B \(brightness)   C \(contrast)"
    }
}

// MARK: - Schedule

private struct ScheduleSettings: View {
    @Bindable var model: AppModel
    @State private var newProfileID: UUID?
    @State private var newTime = Date()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Switch profiles on a schedule", isOn: scheduleBinding)
                } footer: {
                    Text(
                        """
                        The rule in effect is also applied when Kadran starts, so \
                        a switch that came due while it was closed is not missed.
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 110)

            List {
                ForEach(model.scheduleRules) { rule in
                    HStack {
                        Toggle("", isOn: enabledBinding(for: rule))
                            .labelsHidden()
                        Text(rule.timeLabel)
                            .font(.body.monospacedDigit())
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(profileName(for: rule))
                        Spacer()
                        Button {
                            model.deleteScheduleRule(rule)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .opacity(model.isScheduleEnabled ? 1 : 0.5)
                }
            }

            Divider()

            HStack(spacing: 8) {
                DatePicker("", selection: $newTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Picker("", selection: $newProfileID) {
                    Text("Choose profile").tag(UUID?.none)
                    ForEach(model.profiles) { profile in
                        Text(profile.name).tag(UUID?.some(profile.id))
                    }
                }
                .labelsHidden()
                Button("Add") { addRule() }
                    .disabled(newProfileID == nil)
            }
            .padding(8)
        }
    }

    private func addRule() {
        guard let newProfileID else { return }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: newTime)
        model.addScheduleRule(
            profileID: newProfileID,
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0
        )
        self.newProfileID = nil
    }

    private var scheduleBinding: Binding<Bool> {
        Binding(get: { model.isScheduleEnabled }, set: { model.isScheduleEnabled = $0 })
    }

    private func enabledBinding(for rule: ScheduleRule) -> Binding<Bool> {
        Binding(
            get: { rule.isEnabled },
            set: { isEnabled in
                var updated = rule
                updated.isEnabled = isEnabled
                model.updateScheduleRule(updated)
            }
        )
    }

    private func profileName(for rule: ScheduleRule) -> String {
        model.profiles.first { $0.id == rule.profileID }?.name ?? "Deleted profile"
    }
}
