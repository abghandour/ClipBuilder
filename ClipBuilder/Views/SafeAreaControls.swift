import SwiftUI

/// Shared per-run caption/name-tag safety controls for both Overlays tabs.
struct SafeAreaControls: View {
    @Binding var enabled: Bool
    @Binding var platforms: [SocialPlatform]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            SettingsRow("Safe area only") {
                HStack(alignment: .top, spacing: Theme.spaceM) {
                    Toggle("Safe area only", isOn: $enabled)
                        .toggleStyle(.switch).fixedSize()
                        .help("Keep captions and name tags inside the platforms' safe zones, even at Bottom, Top or a corner.")
                    if enabled {
                        PlatformTargetsPicker(platforms: $platforms)
                    }
                }
            }
            if enabled {
                FormCaption("Captions and name tags stay clear of the chosen platforms' buttons and bars. Watermark and overlays are not moved.")
            }
        }
    }
}
