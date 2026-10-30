import AVKit
import SwiftUI

struct DubReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let review: DubReview
    @State private var lines: [DubLine]
    @State private var settings: DubSettings
    @State private var voices: [DubSynthesizer.Voice] = []
    @State private var playback = DubReviewPlayback()
    @State private var continuing = false
    /// Play hears the phrase alone unless the source video is expanded.
    @AppStorage("dubReview.showVideo") private var showVideo = false

    init(jobID: UUID, review: DubReview) {
        self.jobID = jobID
        self.review = review
        _lines = State(initialValue: review.prepared.lines)
        _settings = State(initialValue: review.prepared.settings)
    }

    private var hasEdits: Bool { lines != review.prepared.lines || settings.voices != review.prepared.settings.voices }
    private var editedCount: Int {
        let original = Dictionary(uniqueKeysWithValues: review.prepared.lines.map { ($0.id, $0) })
        return lines.filter { line in
            guard let old = original[line.id] else { return true }
            return old != line || settings.voices[line.speakerKey] != old.voice
        }.count
    }
    private var applyTitle: String {
        if case .render = review.target { return "Apply and render" }
        return "Apply"
    }

    /// Speakers in order of first appearance, then the rest of the roster.
    private var speakerKeys: [String] {
        var keys: [String] = []
        for key in lines.map(\.speakerKey) + review.prepared.speakerChoices + ["unknown"] where !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }
    private func name(_ key: String) -> String {
        review.prepared.speakerNames[key] ?? DubPlanning.speakerLabel(key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Review \(DubLanguageChoices.name(review.prepared.settings.language)) dub").font(.headline)
                Spacer()
                Text("\(lines.count) lines").foregroundStyle(.secondary)
            }
            Text("Pick one voice per speaker. Correct who says a line with its speaker menu, edit the text, then Update lines prepares the changed lines in a background job. Play hears the phrase; expand Source video to hear it over the clip.")
                .font(.caption).foregroundStyle(.secondary)
            voicesSection
            DisclosureGroup("Source video", isExpanded: $showVideo) {
                if showVideo, let player = playback.player {
                    VideoPlayer(player: player).frame(height: 200)
                } else {
                    Text("Press Play on a line to see it here.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: showVideo) { _, _ in playback.stop() }
            if playback.player != nil {
                HStack(spacing: 8) {
                    Button("Stop playback", systemImage: "stop.fill") { playback.stop() }.lineLimit(1).fixedSize()
                    if let id = playback.lineID, let line = lines.first(where: { $0.id == id }) {
                        Text("Playing: \(line.text)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach($lines) { $line in
                        DubReviewLineRow(line: $line, original: review.prepared.lines.first { $0.id == line.id } ?? line,
                            speakers: speakerKeys.map { ($0, name($0)) },
                            play: { play(line) }, update: update)
                        Divider()
                    }
                }
            }
            HStack {
                if hasEdits {
                    Text("Update the \(editedCount) changed line(s) before applying.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Update lines", action: update)
                    .disabled(!hasEdits || lines.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    .lineLimit(1).fixedSize()
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
        .padding(Theme.spaceL).frame(minWidth: 680, idealWidth: 780, minHeight: 460, idealHeight: 650)
        .modalCloseButton(action: cancel)
        .task {
            let installed = await DubLanguageChoices.voices(engine: review.prepared.settings.engine)
            voices = installed.filter { DubLanguageChoices.matches($0.language, requested: review.prepared.settings.language) }
        }
        .onDisappear {
            playback.stop()
            if !continuing { store.cancelDubReview(review) }
        }
    }

    /// One voice per speaker who has a line.
    private var voicesSection: some View {
        let speaking = speakerKeys.filter { key in lines.contains { $0.speakerKey == key } }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Voices").font(.headline)
            ForEach(speaking, id: \.self) { key in
                HStack {
                    Text(name(key)).lineLimit(1).fixedSize().frame(minWidth: 140, alignment: .leading)
                    Picker("Voice for \(name(key))", selection: voiceBinding(key)) {
                        if let current = settings.voices[key], !voices.contains(where: { $0.identifier == current }) {
                            Text(current).tag(current)
                        }
                        ForEach(voicesFor(key)) { voice in
                            Text(voice.qualityLabel.map { "\(voice.name) (\($0))" } ?? voice.name).tag(voice.identifier)
                        }
                    }
                    .labelsHidden().lineLimit(1).fixedSize()
                    Text("\(lines.filter { $0.speakerKey == key }.count) lines")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Only voices of the speaker's gender, when known and installed.
    private func voicesFor(_ key: String) -> [DubSynthesizer.Voice] {
        let gender = review.prepared.speakerGenders[key] ?? .unknown
        let matching = voices.filter { gender == .unknown || $0.gender == gender }
        return matching.isEmpty ? voices : matching
    }

    private func voiceBinding(_ key: String) -> Binding<String> {
        Binding(get: { settings.voices[key] ?? lines.first { $0.speakerKey == key }?.voice ?? "" },
                set: { settings.voices[key] = $0 })
    }

    private func play(_ line: DubLine) {
        Task { await playback.play(line, prepared: review.prepared, withVideo: showVideo) }
    }

    private func update() {
        guard hasEdits, !lines.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        continuing = true
        playback.stop()
        store.updateDubReview(review, jobID: jobID, lines: lines, settings: settings)
        dismiss()
    }

    private func cancel() {
        store.cancelDubReview(review)
        dismiss()
    }
}
