import SwiftUI
import Translation
import UniformTypeIdentifiers

/// Podcast-oriented tools over the shared enriched transcript: topics,
/// cleanup-cut review, translation tracks, and SRT export.
struct TranscriptToolsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: VideoRecord

    @State private var features: [TranscriptFeatureSegment] = []
    @State private var topics: [TopicRange] = []
    @State private var proposals: [EditProposal] = []
    @State private var transcripts: [TranscriptRow] = []
    @State private var targetLanguage = "pt-BR"
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var isWorking = false
    @State private var status = ""
    @State private var batchFallback = false
    /// Cuts ticked for a batch decision.
    @State private var selectedProposalIDs: Set<Int64> = []

    var body: some View {
        NavigationStack {
            List {
                Section("Transcript Analysis") {
                    LabeledContent("Speech segments", value: features.count(where: { $0.kind == .speech }).formatted())
                    LabeledContent("Speaker turns", value: Set(features.compactMap(\.speakerKey)).count.formatted())
                    LabeledContent("Detected pauses and filler", value: proposals.count.formatted())
                    Button(
                        "Analyze Transcript", systemImage: "waveform.badge.magnifyingglass",
                        action: analyzeTranscript
                    )
                    .disabled(isWorking || transcripts.filter({ !$0.isTranslation }).isEmpty)
                }

                Section("Topics and Chapters") {
                    if topics.isEmpty {
                        Text("Analyze the transcript to create titled topic ranges.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(topics) { topic in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(topic.title).bold()
                                Text(
                                    "\(topic.startTime.timecode)–\(topic.endTime.timecode) · \(topic.duration.formatted(.number.precision(.fractionLength(1))))s"
                                )
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                Text(topic.summary).lineLimit(2)
                            }
                        }
                    }
                }

                Section {
                    if proposals.isEmpty {
                        Text("No pauses or filler runs exceed the configured thresholds.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($proposals) { $proposal in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 8) {
                                Toggle(isOn: Binding(
                                    get: { selectedProposalIDs.contains(proposal.id) },
                                    set: { on in if on { selectedProposalIDs.insert(proposal.id) } else { selectedProposalIDs.remove(proposal.id) } })
                                ) { EmptyView() }
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .help("Tick cuts to accept or reject them together")
                                VideoThumbnail(
                                    url: video.url,
                                    time: (proposal.startTime + proposal.endTime) / 2,
                                    cornerRadius: 6
                                )
                                .frame(width: 120, height: 68)
                            }
                            Text(proposal.reason)
                            HStack {
                                TextField("In", value: $proposal.startTime, format: .number)
                                TextField("Out", value: $proposal.endTime, format: .number)
                                Picker("Decision", selection: $proposal.decision) {
                                    Text("Pending").tag(EditProposal.Decision.pending)
                                    Text("Accept").tag(EditProposal.Decision.accepted)
                                    Text("Reject").tag(EditProposal.Decision.rejected)
                                }
                                .labelsHidden()
                            }
                        }
                        .onChange(of: proposal) { _, changed in saveProposal(changed) }
                    }
                } header: {
                    HStack {
                        Text("Proposed Cleanup Cuts")
                        Spacer()
                        if !proposals.isEmpty {
                            let pending = proposals.count { $0.decision == .pending }
                            Button(selectedProposalIDs.count == proposals.count ? "Select None" : "Select All") {
                                selectedProposalIDs = selectedProposalIDs.count == proposals.count ? [] : Set(proposals.map(\.id))
                            }
                            Button("Accept Selected") { decide(.accepted, ids: selectedProposalIDs) }
                                .disabled(selectedProposalIDs.isEmpty)
                            Button("Reject Selected") { decide(.rejected, ids: selectedProposalIDs) }
                                .disabled(selectedProposalIDs.isEmpty)
                            Button("Accept All Pending (\(pending))") {
                                decide(.accepted, ids: Set(proposals.filter { $0.decision == .pending }.map(\.id)))
                            }
                            .disabled(pending == 0)
                            .help("Accept every cut still marked Pending; accepted cuts are skipped when the Wizard builds from this video")
                        }
                    }
                    .controlSize(.small)
                    .textCase(nil)
                }

                Section("Caption Translation") {
                    Picker("Target language", selection: $targetLanguage) {
                        Text("Português (Brasil)").tag("pt-BR")
                        Text("English (United States)").tag("en-US")
                    }
                    Button(
                        "Translate On Device", systemImage: "character.book.closed",
                        action: startTranslation
                    )
                    .disabled(isWorking || transcripts.filter({ !$0.isTranslation }).isEmpty)
                    Button(
                        "Export \(targetLanguage) SRT…", systemImage: "square.and.arrow.up",
                        action: exportSRT
                    )
                    .disabled(!transcripts.contains { $0.isTranslation && $0.language == targetLanguage })
                }

                if !status.isEmpty {
                    Section { Text(status).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Transcript Tools")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .frame(width: 720, height: 650)
        .task { await load() }
        .translationTask(translationConfiguration) { session in
            await translate(using: session)
        }
    }

    private func load() async {
        guard let database = store.database else { return }
        transcripts = (try? await database.fetchTranscripts(videoID: video.id)) ?? []
        features = (try? await database.fetchTranscriptFeatures(videoID: video.id)) ?? []
        topics = (try? await database.fetchTopicRanges(videoID: video.id)) ?? []
        proposals = (try? await database.fetchEditProposals(videoID: video.id)) ?? []
    }

    private func analyzeTranscript() {
        guard let database = store.database else { return }
        isWorking = true
        Task {
            let original = transcripts.filter { !$0.isTranslation }
            let segments = original.map {
                TranscriptSegment(start: $0.startTime, end: $0.endTime, text: $0.text, words: nil)
            }
            let people = (try? await database.fetchVideoPeople(videoID: video.id)) ?? []
            let scenes = ((try? await database.fetchScenes(includeExcluded: true)) ?? [])
                .filter { $0.videoID == video.id }
            let settings = store.settings.podcast
            let result = TranscriptFeatureAnalyzer.analyze(
                segments: segments, videoID: video.id, speakerKeys: people.map(\.key),
                mediaDuration: video.duration,
                speakerHints: TranscriptFeatureAnalyzer.speakerHints(
                    scenes: scenes, personKeys: people.map(\.key)),
                deadAirThreshold: settings.deadAirSeconds,
                fillerRunThreshold: settings.fillerRunSeconds)
            let newTopics = TopicSegmenter.segment(result.features, videoID: video.id)
            let decided = settings.cleanupCutPolicy.applied(to: result.proposals)
            do {
                try await database.replaceTranscriptFeatures(
                    videoID: video.id,
                    features: result.features,
                    proposals: decided)
                try await database.replaceTopicRanges(videoID: video.id, topics: newTopics)
                status = "Created \(newTopics.count) topics and \(result.proposals.count) cleanup proposals."
                await load()
            } catch {
                store.presentError("Could not analyze transcript", error)
            }
            isWorking = false
        }
    }

    /// One decision for several cuts at once, saved together.
    private func decide(_ decision: EditProposal.Decision, ids: Set<Int64>) {
        guard let database = store.database, !ids.isEmpty else { return }
        for index in proposals.indices where ids.contains(proposals[index].id) {
            proposals[index].decision = decision
        }
        let changed = proposals.filter { ids.contains($0.id) }
        selectedProposalIDs = []
        Task {
            do {
                for proposal in changed { try await database.updateEditProposal(proposal) }
                status = "\(changed.count) cut\(changed.count == 1 ? "" : "s") \(decision == .accepted ? "accepted" : "rejected")."
            } catch {
                store.presentError("Could not save cut decisions", error)
            }
        }
    }

    private func saveProposal(_ proposal: EditProposal) {
        guard let database = store.database else { return }
        Task {
            do { try await database.updateEditProposal(proposal) } catch {
                store.presentError("Could not save cut decision", error)
            }
        }
    }

    private func startTranslation() {
        let originals = transcripts.filter { !$0.isTranslation }
        translationConfiguration = TranscriptTranslator.configuration(originals: originals, target: targetLanguage)
        isWorking = true
        status = "Preparing on-device translation…"
    }

    private func translate(using session: TranslationSession) async {
        let originals = transcripts.filter { !$0.isTranslation }
        do {
            let outcome = try await TranscriptTranslator.translate(videoID: video.id, originals: originals,
                                                                   target: targetLanguage, session: session, store: store)
            status = outcome.summary
            await load()
        } catch {
            store.presentError("Caption translation failed", error)
        }
        translationConfiguration = nil
        isWorking = false
    }

    private func exportSRT() {
        let rows = transcripts.filter { $0.isTranslation && $0.language == targetLanguage }
        guard !rows.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = "\(video.url.deletingPathExtension().lastPathComponent)-\(targetLanguage).srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = rows.enumerated().map { index, row in
            "\(index + 1)\n\(srtTime(row.startTime)) --> \(srtTime(row.endTime))\n\(row.text)\n"
        }.joined(separator: "\n")
        do { try content.write(to: url, atomically: true, encoding: .utf8) } catch {
            store.presentError("Could not export SRT", error)
        }
    }

    private func srtTime(_ seconds: Double) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let secs = milliseconds / 1000 % 60
        let millis = milliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}
