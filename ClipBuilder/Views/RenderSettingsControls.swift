import SwiftUI

/// Shared output controls used by profile defaults, Wizard runs, and the
/// Builder's per-timeline override.
struct RenderSettingsControls: View {
    @Binding var settings: RenderSettings

    var body: some View {
        Picker("Canvas", selection: $settings.preset) {
            ForEach(RenderPreset.allCases) { preset in
                Text(preset.label).tag(preset)
            }
        }
        .fieldHelp(WizardFieldHelp.canvas)
        FieldCaption(WizardFieldHelp.canvas)

        if settings.preset == .custom {
            LabeledContent("Custom size") {
                HStack {
                    TextField("Width", value: $settings.customWidth, format: .number)
                        .frame(width: 72)
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", value: $settings.customHeight, format: .number)
                        .frame(width: 72)
                }
            }
            .fieldHelp(WizardFieldHelp.customSize)
        }

        Toggle("Keep clear of platform buttons", isOn: $settings.platformSafeArea.enabled)
            .fieldHelp(WizardFieldHelp.platformSafeArea)
        if settings.platformSafeArea.enabled {
            PlatformTargetsPicker(platforms: $settings.platformSafeArea.platforms)
        }
        FieldCaption(WizardFieldHelp.platformSafeArea)

        Picker("Encode quality", selection: $settings.quality) {
            ForEach(EncodeQuality.allCases) { quality in
                Text(quality.label).tag(quality)
            }
        }
        .fieldHelp(WizardFieldHelp.encodeQuality)
        FieldCaption(WizardFieldHelp.encodeQuality)

        if settings.quality == .custom {
            LabeledContent("CRF") {
                Stepper(value: $settings.customCRF, in: 10...35) {
                    Text(settings.customCRF.formatted()).monospacedDigit()
                }
            }
            .fieldHelp(WizardFieldHelp.customCRF)
            Text("Lower CRF is higher quality and creates a larger file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Which platforms' chrome the safe area accounts for.
struct PlatformTargetsPicker: View {
    @Binding var platforms: [SocialPlatform]

    var body: some View {
        LabeledContent("Platforms") {
            HStack(spacing: Theme.spaceM) {
                ForEach(SocialPlatform.allCases) { platform in
                    Toggle(platform.label, isOn: Binding(
                        get: { platforms.contains(platform) },
                        set: { on in
                            if on { if !platforms.contains(platform) { platforms.append(platform) } }
                            else { platforms.removeAll { $0 == platform } }
                        }))
                    .toggleStyle(.checkbox)
                }
            }
        }
        .help("The safe area is the part of the frame none of the chosen platforms cover")
    }
}
