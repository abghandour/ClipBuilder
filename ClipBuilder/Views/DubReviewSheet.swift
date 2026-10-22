import AVKit
import SwiftUI

struct DubReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let review: DubReview
    @State private var lines: [DubLine]
    @State private var voices: [DubSynthesizer.Voice] = []
    @State private var playback = DubReviewPlayback()
    @State private var continuing = false

    init(jobID: UUID, review: DubReview) {
        self.jobID = jobID
        self.review = review
        _lines = State(initialValue: review.prepared.lines)
    }

    private var hasEdits: Bool { lines != review.prepared.lines }
    private var applyTitle: String {
        if case .render = review.target { return "Apply and render" }
        return "Apply"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Review \(DubLanguageChoices.name(review.prepared.settings.language)) dub").font(.title3.bold())
                Spacer()
                Text("\(lines.count) lines").foregroundStyle(.secondary)
            }
            Text("Play to hear a line over its source video. After editing, Update line prepares only that line in a background job.")
                .font(.caption).foregroundStyle(.secondary)
            if let player = playback.player {
                VideoPlayer(player: player).frame(height: 200)
                Button("Stop playback", systemImage: "stop.fill") { playback.stop() }
            }
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach($lines) { $line in
                        DubReviewLineRow(line: $line, original: review.prepared.lines.first { $0.id == line.id } ?? line,
                            speakerName: review.prepared.speakerNames[line.speakerKey] ?? (line.speakerKey == "unknown" ? "Unknown speaker" : line.speakerKey),
                            voices: voices, play: { play(line) }, update: { update(line) })
                            .disabled(hasEdits && line == review.prepared.lines.first { $0.id == line.id })
                        Divider()
                    }
                }
            }
            HStack {
                if hasEdits { Text("Update edited lines before applying.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button(applyTitle) {
                    if store.applyDubReview(review, jobID: jobID) {
                        continuing = true
                        playback.stop()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(hasEdits)
            }
        }
        .padding(20).frame(minWidth: 680, idealWidth: 780, minHeight: 460, idealHeight: 650)
        .task {
            let installed = await DubLanguageChoices.voices()
            voices = installed.filter { DubLanguageChoices.matches($0.language, requested: review.prepared.settings.language) }
        }
        .onDisappear {
            playback.stop()
            if !continuing { store.cancelDubReview(review) }
        }
    }

    private func play(_ line: DubLine) {
        Task { await playback.play(line, prepared: review.prepared) }
    }

    private func update(_ line: DubLine) {
        guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Only one row is editable at a time; no unsynthesized edits can reach Apply.
        continuing = true
        playback.stop()
        store.resynthesizeDubLine(line, review: review, jobID: jobID)
        dismiss()
    }

    private func cancel() {
        store.cancelDubReview(review)
        dismiss()
    }
}
