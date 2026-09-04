import SwiftUI

/// A single saved brand policy replaces three per-run watermark/headline/outro
/// switches. Runs can still make a rare temporary override from More Options.
struct WizardBrandingDefaultsSection: View {
    @AppStorage(WizardDefaults.brandingModeKey) private var rawMode = WizardBrandingMode.standard.rawValue

    private var modeBinding: Binding<WizardBrandingMode> {
        Binding(
            get: { WizardBrandingMode(rawValue: rawMode) ?? .standard },
            set: { rawMode = $0.rawValue }
        )
    }

    var body: some View {
        Section("Wizard Branding Default") {
            Picker("Branding", selection: modeBinding) {
                ForEach(WizardBrandingMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text("Standard adds the watermark, result headline when available, and branded outro. Minimal keeps only the watermark. Per-run overrides are tucked under More Options in the Wizard.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
