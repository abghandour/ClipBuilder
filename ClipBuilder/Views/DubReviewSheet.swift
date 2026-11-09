import AVKit
import SwiftUI

/// Review a prepared dub: one voice per speaker, then each line's speaker and
/// text. Edited lines are re-prepared by an `AppJobs` job (status-bar row and
/// Stop) while this sheet stays open and adopts the result in place.
struct DubReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var jobID: UUID
    @State private var review: DubReview
    @State private var lines: [DubLine]
    @State private var settings: DubSettings
    @State private var voices: [DubSynthesizer.Voice] = []
    @State private var playback = DubReviewPlayback()
    @State private var continuing = false
    @State private var subscription: ElevenLabsSubscription?
    @State private var creditEstimate: ElevenLabsDubUsage.Estimate?
    @State private var voiceListRevision = 0
    @State private var observedClones: [String: String] = [:]
    /// The Update lines job this sheet is following, if any.
    @State private var updateJobID: UUID?
    /// Play hears the phrase alone unless the source video is on.
    @AppStorage("dubReview.showVideo") private var showVideo = false

    init(jobID: UUID, review: DubReview) {
        _jobID = State(initialValue: jobID)
        _review = State(initialValue: review)
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
    private var hasEmptyLine: Bool {
        lines.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var applyTitle: String {
        if case .render = review.target { return "Apply and render" }
        return "Apply"
    }
    private var isElevenLabs: Bool { review.prepared.settings.engine == .elevenLabs }
    private var updateJob: AppJob? {
        updateJobID.flatMap { id in store.jobs.items.first { $0.id == id } }
    }
    private var isUpdating: Bool { updateJob?.status == .running }

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
        VStack(alignment: .leading, spacing: Theme.spaceL) {
            header
            voicesSection.disabled(isUpdating)
            linesSection
            footer
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
        // A teammate's clone arrives through Team Sync without a local
        // notification; refetch so a clone on this account shows up.
        .onChange(of: store.editingDefaults.clonedVoices) { _, _ in
            guard isElevenLabs else { return }
            Task {
                await ElevenLabsVoiceCache.shared.invalidate()
                voiceListRevision += 1
            }
        }
        .task(id: estimateKey) {
            guard isElevenLabs else { return }
            creditEstimate = nil
            do {
                let estimate = try await ElevenLabsDubUsage.estimate(lines: lines, cachedLines: review.prepared.lines,
                    voices: settings.voices, database: store.database)
                try Task.checkCancellation()
                creditEstimate = estimate
            } catch {
                if !Task.isCancelled { creditEstimate = nil }
            }
        }
        .onChange(of: updateJob?.status) { _, status in followUpdate(status) }
        .task { await loadSubscription() }
        .onDisappear {
            playback.stop()
            if !continuing {
                if let updateJobID { store.jobs.cancel(updateJobID) }
                store.cancelDubReview(review)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXS) {
            HStack(alignment: .firstTextBaseline) {
                Text("Review \(DubLanguageChoices.name(review.prepared.settings.language)) dub").font(.headline)
                Spacer()
                Text(lines.count == 1 ? "1 line" : "\(lines.count) lines")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(isElevenLabs
                ? "Review the draft voice and update any edits. Apply voices drafts with your final model."
                : "Choose a voice for each speaker and fix any line. Changed lines are re-voiced before you apply.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Voices

    /// One voice per speaker who has a line.
    private var voicesSection: some View {
        let speaking = speakerKeys.filter { key in lines.contains { $0.speakerKey == key } }
        // A grid keeps the columns aligned; the voice menu is the one column
        // that shrinks (and truncates), so a long voice name never widens the
        // sheet past its edges.
        return VStack(alignment: .leading, spacing: Theme.spaceS) {
            SectionLabel("Voices")
            Grid(alignment: .leading, horizontalSpacing: Theme.spaceM, verticalSpacing: Theme.spaceS) {
                ForEach(speaking, id: \.self) { key in
                    let count = lines.filter { $0.speakerKey == key }.count
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(name(key)).lineLimit(1).truncationMode(.tail)
                            Text(count == 1 ? "1 line" : "\(count) lines")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(minWidth: 120, maxWidth: 180, alignment: .leading)
                        voicePicker(key)
                        if isElevenLabs, store.people.contains(where: { $0.key == key }) {
                            VoiceCloneControls(store: store, personKey: key, name: name(key)).fixedSize()
                        } else {
                            Color.clear.frame(width: 0, height: 0)
                        }
                    }
                }
            }
        }
    }

    private func voicePicker(_ key: String) -> some View {
        Picker("Voice for \(name(key))", selection: voiceBinding(key)) {
            if let current = settings.voices[key], !voices.contains(where: { $0.identifier == current }) {
                Text(unavailableVoiceLabel(current, speaker: key)).tag(current)
            }
            ForEach(voicesFor(key)) { voice in
                // Every voice here is ElevenLabs when that engine is on; say it once.
                Text(isElevenLabs ? voice.name : voice.qualityLabel.map { "\(voice.name) (\($0))" } ?? voice.name)
                    .tag(voice.identifier)
            }
        }
        .labelsHidden().lineLimit(1).frame(minWidth: 160, maxWidth: 300, alignment: .leading)
    }

    /// A remembered voice this Mac cannot use, usually a teammate's clone made
    /// with another ElevenLabs account. Never show the raw identifier.
    private func unavailableVoiceLabel(_ identifier: String, speaker key: String) -> String {
        if let clone = store.editingDefaults.clonedVoices?[key],
           identifier == ElevenLabsVoices.identifierPrefix + clone {
            return "\(name(key)) (cloned, other account)"
        }
        return voices.isEmpty ? "Loading voices…" : "Voice not available"
    }

    private func adoptClones() {
        // A running update replaces `settings` with its snapshot when it ends;
        // adopt after that (followUpdate calls back) so a clone is not lost.
        guard isElevenLabs, !isUpdating else { return }
        let clones = store.editingDefaults.clonedVoices ?? [:]
        for key in speakerKeys {
            if let id = clones[key], observedClones[key] != id {
                // Only a clone this account can speak with; a teammate's
                // clone on another account leaves the current voice alone.
                let identifier = ElevenLabsVoices.identifierPrefix + id
                if voices.contains(where: { $0.identifier == identifier }) { settings.voices[key] = identifier }
                else { continue }
            } else if let removed = observedClones[key], clones[key] == nil,
                      settings.voices[key] == ElevenLabsVoices.identifierPrefix + removed {
                settings.voices[key] = voicesFor(key).first?.identifier ?? ""
            }
            observedClones[key] = clones[key]
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

    // MARK: Lines

    private var linesSection: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(spacing: Theme.spaceS) {
                SectionLabel("Lines")
                Spacer()
                Toggle("Play over source video", isOn: $showVideo)
                    .toggleStyle(.checkbox).font(.caption).lineLimit(1).fixedSize()
                    .onChange(of: showVideo) { _, _ in playback.stop() }
            }
            if showVideo, let player = playback.player {
                VideoPlayer(player: player).frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.spaceXS + 2))
            }
            if let error = playback.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.spaceM) {
                    ForEach($lines) { $line in
                        DubReviewLineRow(line: $line, original: review.prepared.lines.first { $0.id == line.id } ?? line,
                            speakers: speakerKeys.map { ($0, name($0)) },
                            isPlaying: playback.lineID == line.id,
                            play: { play(line) }, stop: { playback.stop() }, update: update)
                        Divider()
                    }
                }
                .padding(.trailing, Theme.spaceS)
            }
            .disabled(isUpdating)
        }
    }

    private func play(_ line: DubLine) {
        Task { await playback.play(line, prepared: review.prepared, withVideo: showVideo) }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.spaceS) {
            footerStatus
            Spacer(minLength: Theme.spaceM)
            Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
            if isUpdating {
                Button("Stop") { if let updateJobID { store.jobs.cancel(updateJobID) } }
                    .lineLimit(1).fixedSize()
            } else if hasEdits {
                Button("Revert") { revert() }
                    .lineLimit(1).fixedSize()
                    .help("Discard your changes to voices and lines")
                Button(editedCount == 1 ? "Update 1 line" : "Update \(editedCount) lines", action: update)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(hasEmptyLine)
                    .lineLimit(1).fixedSize()
            } else {
                Button(applyTitle) { apply() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .lineLimit(1).fixedSize()
            }
        }
    }

    /// Progress while updating, otherwise what applying needs and what it costs.
    @ViewBuilder private var footerStatus: some View {
        if isUpdating, let job = updateJob {
            HStack(spacing: Theme.spaceS) {
                ProgressView(value: job.progress).frame(width: 120)
                Text(job.statusLine.isEmpty ? "Updating lines…" : job.statusLine)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        } else if hasEmptyLine {
            Label("Every line needs text.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).lineLimit(1)
        } else if isElevenLabs {
            creditsCaption
        } else if hasEdits {
            Text("Update the changed lines to hear them, then apply.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }

    private var estimateKey: String {
        DubTake.digest(lines.flatMap { [$0.id.uuidString, $0.text, settings.voices[$0.speakerKey] ?? $0.voice,
                                        $0.audio ?? "", String($0.draft == true)] } + [String(voiceListRevision)])
    }

    private var creditsCaption: some View {
        let characters = creditEstimate?.credits ?? ElevenLabsDubUsage.pendingCharacters(lines: lines, cachedLines: review.prepared.lines,
                                                              voices: settings.voices)
        let left = subscription.map { ($0.characterLimit - $0.characterCount).formatted() }
        let text: String = switch (characters > 0, left) {
        case (true, let left?): "Apply: ≈ \(characters.formatted()) credits for final voice · \(left) left"
        case (true, nil): "Apply: ≈ \(characters.formatted()) credits for final voice"
        case (false, let left?): "\(left) credits left this month"
        case (false, nil): ""
        }
        return Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
    }

    private func loadSubscription() async {
        guard isElevenLabs else { return }
        subscription = await ElevenLabsSubscriptionCache.shared.lastSuccessful()
        do {
            let refreshed = try await ElevenLabsSubscriptionCache.shared.refresh()
            try Task.checkCancellation()
            subscription = refreshed
        } catch {
            subscription = nil
        }
    }

    // MARK: Actions

    private func update() {
        guard hasEdits, !hasEmptyLine, !isUpdating else { return }
        playback.stop()
        updateJobID = store.updateDubReview(review, jobID: jobID, lines: lines, settings: settings)
    }

    /// Adopt a finished update in place: the job's result becomes this
    /// sheet's review, so the sheet never closes and reopens.
    private func followUpdate(_ status: AppJob.Status?) {
        guard let id = updateJobID else { return }
        switch status {
        case .running: return
        case .done:
            if case .dub(let updated) = updateJob?.result {
                store.jobs.adoptReviewInPlace(id)
                review = updated
                lines = updated.prepared.lines
                settings = updated.prepared.settings
                jobID = id
            }
            updateJobID = nil
        case .failed, .cancelled, nil:
            // AppJobs reports the failure; keep the edits so the user can retry.
            updateJobID = nil
        }
        adoptClones()
    }

    private func revert() {
        playback.stop()
        lines = review.prepared.lines
        settings = review.prepared.settings
    }

    private func apply() {
        guard store.applyDubReview(review, jobID: jobID) else { return }
        continuing = true
        playback.stop()
        dismiss()
    }

    private func cancel() {
        if let updateJobID { store.jobs.cancel(updateJobID) }
        store.cancelDubReview(review)
        dismiss()
    }
}
