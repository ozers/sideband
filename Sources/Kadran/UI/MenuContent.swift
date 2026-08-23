import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel
    @State private var newProfileName = ""
    @State private var isNamingProfile = false
    @State private var showsAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = model.unsupportedReason {
                unsupported(reason)
            } else if model.displays.isEmpty {
                noDisplays
            } else {
                header
                Divider()
                controls
                Divider()
                profileRow
                Divider()
                footer
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: - States

    private func unsupported(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("DDC unavailable", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
            quitButton
        }
    }

    private var noDisplays: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No external display", systemImage: "display.slash")
                .font(.headline)
            Text(
                """
                Connect a display over DisplayPort or USB-C. Built-in panels and \
                displays behind the HDMI port of entry-level Apple silicon Macs \
                have no DDC bus.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("Rescan") { model.refreshDisplays() }
            quitButton
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var header: some View {
        HStack {
            if model.displays.count > 1 {
                Picker("Display", selection: displaySelection) {
                    ForEach(model.displays) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                .labelsHidden()
            } else if let display = model.selectedDisplay {
                Text(display.name)
                    .font(.headline)
                    .lineLimit(1)
            }

            Spacer()

            if model.isReading {
                ProgressView()
                    .controlSize(.small)
                    .help("Reading current values from the display")
            }
        }
    }

    private var displaySelection: Binding<CGDirectDisplayID> {
        Binding(
            get: { model.selectedDisplay?.id ?? 0 },
            set: { model.selectDisplay($0) }
        )
    }

    /// Only what the display advertises, grouped.
    ///
    /// A control that is present but does nothing is worse than a missing one:
    /// it makes the display look broken rather than the app look limited.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(VCP.Group.allCases, id: \.self) { group in
                let features = model.supportedFeatures(in: group, includingAdvanced: showsAdvanced)
                if !features.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(features, id: \.self) { feature in
                            control(for: feature)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func control(for feature: VCP) -> some View {
        switch feature.kind {
        case .continuous:
            FeatureSlider(
                feature: feature,
                maximum: model.maximum(for: feature),
                value: sliderBinding(for: feature)
            )
        case .enumerated:
            FeaturePicker(
                feature: feature,
                options: model.allowedValues(for: feature),
                isIgnored: model.unwritableFeatures.contains(feature),
                value: pickerBinding(for: feature)
            )
        case .command:
            Button(feature.label) { model.run(feature) }
                .buttonStyle(.link)
                .font(.caption)
        case .readOnly:
            if let value = model.values[feature] {
                HStack {
                    Image(systemName: feature.symbolName)
                        .frame(width: 16)
                    Text(feature.label)
                        .font(.caption)
                    Spacer()
                    Text(readOnlyText(feature, value))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func readOnlyText(_ feature: VCP, _ value: UInt16) -> String {
        feature == .usageTime ? "\(value) h" : "\(value)"
    }

    private func sliderBinding(for feature: VCP) -> Binding<Double> {
        Binding(
            get: { Double(model.values[feature] ?? 0) },
            set: { model.set(feature, to: UInt16($0.rounded())) }
        )
    }

    private func pickerBinding(for feature: VCP) -> Binding<UInt8> {
        Binding(
            get: { UInt8(truncatingIfNeeded: model.values[feature] ?? 0) },
            set: { model.set(feature, to: UInt16($0)) }
        )
    }

    private var profileRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profiles")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)], spacing: 6) {
                ForEach(model.profiles) { profile in
                    Button {
                        model.apply(profile)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: profile.symbolName)
                            Text(profile.name)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .contextMenu {
                        Button("Delete", role: .destructive) { model.deleteProfile(profile) }
                    }
                }
            }

            if isNamingProfile {
                HStack {
                    TextField("Profile name", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveProfile)
                    Button("Save", action: saveProfile)
                        .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button("Save current as profile…") { isNamingProfile = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func saveProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.captureProfile(named: name)
        newProfileName = ""
        isNamingProfile = false
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(showsAdvanced ? "Fewer" : "More…") { showsAdvanced.toggle() }
                .buttonStyle(.link)
                .font(.caption)
                .help("Black levels, input switching and a full reset")

            Button("Refresh") { Task { await model.syncFromDisplay() } }
                .buttonStyle(.link)
                .font(.caption)
                .help("Re-read the current values from the display")

            Spacer()

            Button("Settings…") { openSettings() }
                .buttonStyle(.link)
                .font(.caption)
            quitButton
        }
    }

    private func openSettings() {
        SettingsWindowController.shared.show(model: model)
    }

    private var quitButton: some View {
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .buttonStyle(.link)
            .font(.caption)
    }
}

/// One labelled slider, spanning the range the display reported.
private struct FeatureSlider: View {
    let feature: VCP
    let maximum: UInt16
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: feature.symbolName)
                    .frame(width: 16)
                Text(feature.label)
                    .font(.caption)
                Spacer()
                Text(displayValue)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...Double(max(maximum, 1)), step: 1)
                .controlSize(.small)
        }
    }

    /// Colour temperature is stored as an offset from 3000 K in 50 K steps, so
    /// the raw number would be meaningless on screen.
    private var displayValue: String {
        feature == .colorTemperature ? "\(3000 + Int(value) * 50) K" : "\(Int(value))"
    }
}

/// A menu of exactly the values the display advertised.
private struct FeaturePicker: View {
    let feature: VCP
    let options: [UInt8]

    /// The display advertised this feature and then ignored a write to it.
    let isIgnored: Bool

    @Binding var value: UInt8

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: feature.symbolName)
                .frame(width: 16)
            Text(feature.label)
                .font(.caption)
            if isIgnored {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(
                        """
                        This display lists the feature but does not apply changes                         to it. Use the monitor's own menu instead.
                        """
                    )
            }
            Spacer()
            Picker("", selection: $value) {
                ForEach(options, id: \.self) { option in
                    Text(feature.valueName(option) ?? String(format: "0x%02X", option))
                        .tag(option)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 130)
            .opacity(isIgnored ? 0.5 : 1)
        }
    }
}
