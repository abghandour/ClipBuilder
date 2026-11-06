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
    @State private var subscription: ElevenLabsSubscription?
    @State private var voiceListRevision = 0
    @State private var observedClones: [String: String] = [:]
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
            if review.prepared.settings.engine == .elevenLabs {
                creditsCaption
            }
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
        .task(id: voiceListRevision) {
            let installed = await DubLanguageChoices.voices(engine: review.prepared.settings.engine,
                                                           language: review.prepared.settings.language)
            guard !Task.isCancelled, review.profileGeneration == store.profileGeneration else { return }
            voices = installed.filter { DubLanguageChoices.matches($0.language, requested: review.prepared.settings.language) }
            adoptClones()
        }
        .onReceive(NotificationCenter.default.publisher(for: ElevenLabsVoices.settingsChanged)) { _ in
            voiceListRevision += 1
        }
        .task { await loadSubscription() }
        .onDisappear {
            playback.stop()
            if !continuing { store.cancelDubReview(review) }
        }
    }

    private var creditsCaption: some View {
        let characters = ElevenLabsDubUsage.pendingCharacters(lines: lines, cachedLines: review.prepared.lines,
                                                              voices: settings.voices)
        return HStack(spacing: Theme.spaceM) {
            Text("≈ \(characters.formatted()) characters")
            if let subscription {
                Text("\((subscription.characterLimit - subscription.characterCount).formatted()) credits left this month")
            }
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }

    private func loadSubscription() async {
        guard review.prepared.settings.engine == .elevenLabs else { return }
        subscription = await ElevenLabsSubscriptionCache.shared.lastSuccessful()
        do {
            let refreshed = try await ElevenLabsSubscriptionCache.shared.refresh()
            try Task.checkCancellation()
            subscription = refreshed
        } catch {
            subscription = nil
        }
    }

    /// One voice per speaker who has a line.
    private var voicesSection: some View {
        let speaking = speakerKeys.filter { key in lines.contains { $0.speakerKey == key } }
        let elevenLabs = review.prepared.settings.engine == .elevenLabs
        // A grid keeps the columns aligned; the voice menu is the one column
        // that shrinks (and truncates), so a long voice name never widens the
        // sheet past its edges.
        return VStack(alignment: .leading, spacing: 6) {
            Text("Voices").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: Theme.spaceM, verticalSpacing: 6) {
                ForEach(speaking, id: \.self) { key in
                    let count = lines.filter { $0.speakerKey == key }.count
                    GridRow {
                        Text(name(key)).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: 180, alignment: .leading)
                        Picker("Voice for \(name(key))", selection: voiceBinding(key)) {
                            if let current = settings.voices[key], !voices.contains(where: { $0.identifier == current }) {
                                Text(current).tag(current)
                            }
                            ForEach(voicesFor(key)) { voice in
                                // Every voice here is ElevenLabs when that engine is on; say it once.
                                Text(elevenLabs ? voice.name : voice.qualityLabel.map { "\(voice.name) (\($0))" } ?? voice.name)
                                    .tag(voice.identifier)
                            }
                        }
                        .labelsHidden().lineLimit(1).frame(minWidth: 160, maxWidth: 300, alignment: .leading)
                        if elevenLabs, store.people.contains(where: { $0.key == key }) {
                            VoiceCloneControls(store: store, personKey: key, name: name(key)).fixedSize()
                        } else {
                            Color.clear.frame(width: 0, height: 0)
                        }
                        Text(count == 1 ? "1 line" : "\(count) lines")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                }
            }
        }
    }

    private func adoptClones() {
        guard review.prepared.settings.engine == .elevenLabs else { return }
        let clones = store.editingDefaults.clonedVoices ?? [:]
        for key in speakerKeys {
            if let id = clones[key], observedClones[key] != id {
                settings.voices[key] = ElevenLabsVoices.identifierPrefix + id
            } else if let removed = observedClones[key], clones[key] == nil,
                      settings.voices[key] == ElevenLabsVoices.identifierPrefix + removed {
                settings.voices[key] = voicesFor(key).first?.identifier ?? ""
            }
        }
        observedClones = clones
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
