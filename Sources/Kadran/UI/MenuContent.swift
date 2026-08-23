import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel
    @State private var newProfileName = ""
    @State private var isNamingProfile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = model.unsupportedReason {
                unsupported(reason)
            } else if model.displays.isEmpty {
                noDisplays
            } else {
                displayPicker
                Divider()
                sliders
                Divider()
                profileRow
                Divider()
                footer
            }
        }
        .padding(14)
        .frame(width: 280)
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
    private var displayPicker: some View {
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
    }

    private var displaySelection: Binding<CGDirectDisplayID> {
        Binding(
            get: { model.selectedDisplay?.id ?? 0 },
            set: { model.selectDisplay($0) }
        )
    }

    private var sliders: some View {
        VStack(spacing: 10) {
            ForEach(VCP.sliders, id: \.self) { feature in
                FeatureSlider(
                    feature: feature,
                    value: binding(for: feature)
                )
            }

            HStack {
                Spacer()
                Button("Reset colour") { model.resetColour() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(
                        """
                        Returns the monitor to its factory colour settings.                         The gain sliders cannot do this on their own, because                         the neutral value of a gain is unreadable.
                        """
                    )
            }
        }
    }

    private func binding(for feature: VCP) -> Binding<Double> {
        Binding(
            get: { Double(model.values[feature] ?? 50) },
            set: { model.set(feature, to: UInt16($0.rounded())) }
        )
    }

    private var profileRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profiles")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6)], spacing: 6) {
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
                Button("Save current as profile…") {
                    isNamingProfile = true
                }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Settings…") { openSettings() }
                    .font(.caption)
                Spacer()
                quitButton
            }
        }
    }

    private func openSettings() {
        SettingsWindowController.shared.show(model: model)
    }

    private var quitButton: some View {
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .font(.caption)
    }
}

/// One labelled slider.
///
/// The trailing number is the value this app last wrote, not a value read back
/// from the monitor — nothing here can confirm the panel agrees.
private struct FeatureSlider: View {
    let feature: VCP
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: feature.symbolName)
                    .frame(width: 16)
                Text(feature.label)
                    .font(.caption)
                Spacer()
                Text("\(Int(value))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...Double(feature.maxValue), step: 1)
                .controlSize(.small)
        }
    }
}
