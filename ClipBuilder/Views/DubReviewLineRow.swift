import SwiftUI

struct DubReviewLineRow: View {
    @Binding var line: DubLine
    let original: DubLine
    let speakerName: String
    let voices: [DubSynthesizer.Voice]
    let play: () -> Void
    let update: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(speakerName).font(.headline)
                Text("\(line.start.timecode) · \(line.duration.formatted(.number.precision(.fractionLength(2)))) s")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if line.tight {
                    Text("Tight").font(.caption.bold()).foregroundStyle(.orange)
                        .help("This line overlaps speech or still exceeds its slot. Shorten the text.")
                }
                Spacer()
                Button("Play", systemImage: "play.fill", action: play).disabled(line != original)
                    .lineLimit(1).fixedSize()
            }
            Picker("Voice", selection: $line.voice) {
                if !voices.contains(where: { $0.identifier == line.voice }) {
                    Text(line.voice).tag(line.voice)
                }
                ForEach(voices) { voice in Text(voice.name).tag(voice.identifier) }
            }
            .lineLimit(1)
            .onChange(of: line.voice) { _, _ in update() }
            TextField("Dubbed text", text: $line.text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...6)
                .onSubmit(update)
            HStack {
                Text("Speech \(line.rate.formatted(.number.precision(.fractionLength(2))))× · stretch \(line.stretch.formatted(.number.precision(.fractionLength(2))))×")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Update line", action: update)
                    .disabled(line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .lineLimit(1).fixedSize()
            }
        }
    }
}
