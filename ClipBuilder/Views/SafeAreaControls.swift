import SwiftUI

/// Shared per-run caption/name-tag safety controls for both Overlays tabs.
struct SafeAreaControls: View {
    @Binding var enabled: Bool
    @Binding var platforms: [SocialPlatform]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(alignment: .top, spacing: Theme.spaceM) {
                Toggle(isOn: $enabled) {
                    Text("Safe area only").lineLimit(1).fixedSize()
                }
                .fixedSize()
                .help("Keep captions and name tags inside the platforms' safe zones, even at Bottom, Top or a corner.")
                if enabled {
                    PlatformTargetsPicker(platforms: $platforms)
                }
            }
            if enabled {
                FormCaption("Captions and name tags stay clear of the chosen platforms' buttons and bars. Watermark and overlays are not moved.")
            }
        }
    }
}
