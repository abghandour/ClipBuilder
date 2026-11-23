import SwiftUI

struct DubLineInspector: View {
    @Environment(AppStore.self) private var store
    let block: BuilderDubLayout.Block
    private var playback: DubReviewPlayback { store.builder.dubAudition }
    @State private var voiceName: String?

    var body: some View {
        let line = block.line
        let speaker = store.people.first { $0.key == line.speakerKey }?.displayName ?? DubPlanning.speakerLabel(line.speakerKey)
        VStack(alignment: .leading, spacing: 12) {
            Label("Dub line", systemImage: "waveform.badge.mic").font(.headline)
            SpeakerPill(speaker: speaker)
            LabeledContent("Voice", value: voiceName ?? line.voice)
            Text(line.text).textSelection(.enabled)
            LabeledContent("Start", value: line.start.timecode)
            LabeledContent("Length", value: "\(block.duration.formatted(.number.precision(.fractionLength(2)))) s")
            if !block.freezes.isEmpty {
                Text("Stops for a freeze · \(block.freezes.count)")
                    .font(.caption).lineLimit(1).fixedSize()
            }
            if line.tight {
                Label("Tight", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).lineLimit(1).fixedSize()
            }
            if !block.prepared { Text("Not prepared").font(.caption).foregroundStyle(.secondary) }
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading) { controls }
            }
            if let error = playback.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(12)
        .task(id: line.voice) {
            voiceName = nil
            guard let settings = store.builder.document.dub else { return }
            let voices = await DubLanguageChoices.voices(engine: settings.engine, language: settings.language)
            guard !Task.isCancelled else { return }
            voiceName = voices.first { $0.identifier == line.voice }?.name
        }
        .onChange(of: line) { _, _ in store.builder.stopAudition() }
        .onDisappear { store.builder.stopAudition() }
    }

    @ViewBuilder private var controls: some View {
        if playback.lineID == block.id {
            Button("Stop", systemImage: "stop.fill") { store.builder.stopAudition() }.lineLimit(1).fixedSize()
        } else {
            Button("Play line", systemImage: "play.fill") {
                store.builder.audition(block.line, stopExact: store.stopBuilderPreview)
            }
            .disabled(!block.prepared).lineLimit(1).fixedSize()
        }
        Button("Review lines…") {
            store.builder.stopAudition()
            store.reviewTimelineDub(at: block.id)
        }.lineLimit(1).fixedSize()
    }
}
