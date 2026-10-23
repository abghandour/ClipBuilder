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

/// Interview focus "Zoom in/out for focus": the camera zooms in and out on
/// the VIP in place instead of panning toward the interviewer.
struct InterviewZoomMovesToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("Zoom in/out for focus", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Zoom in/out for focus")
    }

    static let caption = "On: tight on the VIP while they talk, zoomed out to show everyone while the interviewer asks (around the VIP when they cannot all fit). Off: the camera pans toward the interviewer, and Pull back sets how tight the shot is."
}
