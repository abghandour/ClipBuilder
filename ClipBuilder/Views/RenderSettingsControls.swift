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
        }

        Picker("Encode quality", selection: $settings.quality) {
            ForEach(EncodeQuality.allCases) { quality in
                Text(quality.label).tag(quality)
            }
        }

        if settings.quality == .custom {
            LabeledContent("CRF") {
                Stepper(value: $settings.customCRF, in: 10...35) {
                    Text(settings.customCRF.formatted()).monospacedDigit()
                }
            }
            Text("Lower CRF is higher quality and creates a larger file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
