import SwiftUI

/// One dubbed line: who says it, the text, and its timing. The voice is
/// chosen once per speaker at the top of the review sheet, never per line.
struct DubReviewLineRow: View {
    @Binding var line: DubLine
    let original: DubLine
    /// Speaker keys the picker offers, with their display names.
    let speakers: [(key: String, name: String)]
    let play: () -> Void
    let update: () -> Void

    private var edited: Bool { line != original }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Speaker", selection: $line.speakerKey) {
                    ForEach(speakers, id: \.key) { speaker in Text(speaker.name).tag(speaker.key) }
                }
                .labelsHidden().lineLimit(1).fixedSize()
                .accessibilityLabel("Speaker")
                Text("\(line.start.timecode) · \(line.duration.formatted(.number.precision(.fractionLength(2)))) s")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if line.tight {
                    Text("Tight").font(.caption.bold()).foregroundStyle(.orange)
                        .help("This line overlaps speech or still exceeds its slot. Shorten the text.")
                }
                if edited {
                    Text("Edited").font(.caption.bold()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Play", systemImage: "play.fill", action: play).disabled(edited)
                    .lineLimit(1).fixedSize()
            }
            TextField("Dubbed text", text: $line.text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4)
                .onSubmit(update)
            Text("Speech \(line.rate.formatted(.number.precision(.fractionLength(2))))× · stretch \(line.stretch.formatted(.number.precision(.fractionLength(2))))×")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
