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

    static let caption = "0% fills a close shot with the chosen person's face; 100% opens to the full source height so both people show head to knees."
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

    static let caption = "On: close shots use conversation framing; the two-shot zooms out to show everyone, around the VIP when they cannot all fit. Off: Pull back sets how tight the shots are, and the two-shot leans toward the interviewer."
}

/// Shared Interview focus controls for Express and the full wizard.
struct InterviewShotChangesPicker: View {
    @Binding var cuts: Bool

    var body: some View {
        Picker("Shot changes", selection: $cuts) {
            Text("Smooth moves").tag(false)
            Text("Cuts").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .lineLimit(1).fixedSize()
        .help(Self.caption)
        .accessibilityLabel("Shot changes")
    }

    static let caption = WizardFieldHelp.interviewShotChanges.tooltip
}

struct InterviewPunchInPicker: View {
    @Binding var selection: String

    var body: some View {
        Picker("Punch in on", selection: $selection) {
            ForEach(InterviewPunchIn.allCases, id: \.rawValue) { choice in
                Text(choice.label).tag(choice.rawValue)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .lineLimit(1).fixedSize()
        .help(Self.caption)
        .accessibilityLabel("Punch in on")
    }

    static let caption = WizardFieldHelp.interviewPunchIn.tooltip
}
