import Foundation
import SwiftUI

struct TelestratorTimingControls: View {
    @Bindable var editor: TelestratorEditor

    var body: some View {
        FlowLayout(spacing: 16) {
            if editor.allowsMotion {
            HStack {
                Text("Picture while drawing").lineLimit(1).fixedSize()
                Picker("Picture while drawing", selection: Binding(get: { editor.drawing.motion },
                                                                   set: { editor.setMotion($0) })) {
                    Text(TelestrationPlayback.label(nil)).tag(Double?.none)
                    ForEach(Telestration.motionRates, id: \.self) { rate in
                        Text(TelestrationPlayback.label(rate)).tag(Double?.some(rate))
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Paused freezes the picture while the figures are drawn. A speed keeps it moving under them, slowed to that share of the clip's speed.")
            }
            }
            HStack {
                Text("Stays for").lineLimit(1).fixedSize()
                Slider(value: $editor.drawing.stay, in: 0.5...max(Telestration.sliderStay, editor.drawing.stay), step: 0.1,
                       onEditingChanged: editor.controlEditing)
                    .frame(width: 140).accessibilityLabel("Stays for, seconds")
                Text("\(editor.drawing.stay, format: .number.precision(.fractionLength(1))) s")
                    .monospacedDigit().lineLimit(1).fixedSize()
            }
            HStack {
                Text("Drawing speed").lineLimit(1).fixedSize()
                Slider(value: $editor.drawing.drawSpeed, in: 0.15...2, step: 0.05,
                       onEditingChanged: editor.controlEditing)
                    .frame(width: 140).accessibilityLabel("Drawing speed, seconds per figure")
                Text("\(editor.drawing.drawSpeed, format: .number.precision(.fractionLength(2))) s / figure")
                    .monospacedDigit().lineLimit(1).fixedSize()
            }
            summary
        }
        .disabled(editor.isDragging || editor.isPlaying)
    }

    /// What the reel does at this moment, in one line.
    @ViewBuilder private var summary: some View {
        let length = editor.drawing.duration.formatted(.number.precision(.fractionLength(2)))
        if let motion = editor.drawing.motion {
            if editor.motionFits {
                Text("The picture plays at \(TelestrationPlayback.label(motion).lowercased()) for \(length) s · \(editor.drawing.sourceSpan, format: .number.precision(.fractionLength(2))) s of footage")
                    .foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
            } else {
                Label("Needs \(editor.drawing.sourceSpan, format: .number.precision(.fractionLength(2))) s of footage after this moment, the clip has \(editor.footageRoom, format: .number.precision(.fractionLength(2))) s: the picture will pause instead",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).monospacedDigit()
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("The picture pauses for \(length) s")
                .foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
        }
    }
}
