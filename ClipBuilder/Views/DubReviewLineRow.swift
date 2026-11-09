import SwiftUI

/// One dubbed line: who says it, the text, and its timing. The voice is
/// chosen once per speaker at the top of the review sheet, never per line.
struct DubReviewLineRow: View {
    @Binding var line: DubLine
    let original: DubLine
    /// Speaker keys the picker offers, with their display names.
    let speakers: [(key: String, name: String)]
    let isPlaying: Bool
    let play: () -> Void
    let stop: () -> Void
    let update: () -> Void

    private var edited: Bool { line != original }
    private var isEmpty: Bool { line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// How much the voice was sped up or slowed to fit the line's slot;
    /// nil when it plays at its natural pace.
    private var fitNote: String? {
        let factor = line.rate * line.stretch
        guard abs(factor - 1) >= 0.01 else { return nil }
        let amount = factor.formatted(.number.precision(.fractionLength(2)))
        return factor > 1 ? "Sped up \(amount)× to fit" : "Slowed to \(amount)× to fit"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(spacing: Theme.spaceS) {
                Picker("Speaker", selection: $line.speakerKey) {
                    ForEach(speakers, id: \.key) { speaker in Text(speaker.name).tag(speaker.key) }
                }
                .labelsHidden().lineLimit(1).fixedSize()
                .accessibilityLabel("Speaker")
                Text("\(line.start.timecode) · \(line.duration.formatted(.number.precision(.fractionLength(2)))) s")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                if line.tight {
                    Label("Tight", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold()).foregroundStyle(.orange).lineLimit(1).fixedSize()
                        .help("This line overlaps speech or still runs past its slot. Shorten the text.")
                }
                if line.reviewedEarlier == true {
                    Text("Reviewed earlier")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                if line.draft == true {
                    Text("Draft voice")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                if edited {
                    Label("Edited", systemImage: "pencil")
                        .font(.caption.bold()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                Spacer()
                if isPlaying {
                    Button("Stop", systemImage: "stop.fill", action: stop)
                        .lineLimit(1).fixedSize()
                } else {
                    Button("Play", systemImage: "play.fill", action: play)
                        .disabled(edited)
                        .help(edited ? "Update lines to hear this edit" : "Hear this line")
                        .lineLimit(1).fixedSize()
                }
            }
            TextField("Dubbed text", text: $line.text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4)
                .onSubmit(update)
            if isEmpty {
                Text("Add text, or reassign this line's speaker.")
                    .font(.caption).foregroundStyle(.orange)
            } else if let fitNote, !edited {
                Text(fitNote).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
