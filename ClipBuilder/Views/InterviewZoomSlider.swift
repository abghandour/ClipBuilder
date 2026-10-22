import SwiftUI

/// Interview focus pull-back: how far both shots open from tight on the VIP
/// toward the full source height.
struct InterviewZoomSlider: View {
    @Binding var zoom: Double

    var body: some View {
        HStack(spacing: Theme.spaceS) {
            Slider(value: Binding(
                get: { min(1, max(0, zoom)) },
                set: { zoom = (($0 * 100).rounded()) / 100 }), in: CropRecipe.interviewZoomRange)
                .frame(width: 160)
                .accessibilityLabel("Pull back")
            Text("\(Int((min(1, max(0, zoom)) * 100).rounded()))%")
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    static let caption = "0% stays tight on the VIP's face; 100% opens to the full source height so both people show head to knees."
}
