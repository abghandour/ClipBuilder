import Foundation
import SwiftUI

struct TelestratorTimingControls: View {
    @Bindable var editor: TelestratorEditor

    var body: some View {
        FlowLayout(spacing: 16) {
            HStack {
                Text("Stays for").lineLimit(1).fixedSize()
                Slider(value: $editor.drawing.stay, in: 0.5...10, step: 0.1,
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
            Text("Total pause: \(editor.drawing.duration, format: .number.precision(.fractionLength(2))) s")
                .foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
        }
        .disabled(editor.isDragging || editor.playStarted != nil)
    }
}
