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

                Section("Proposed Cleanup Cuts") {
                    if proposals.isEmpty {
                        Text("No pauses or filler runs exceed the configured thresholds.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($proposals) { $proposal in
                        VStack(alignment: .leading, spacing: 6) {
                            VideoThumbnail(
                                url: video.url,
                                time: (proposal.startTime + proposal.endTime) / 2,
                                cornerRadius: 6
                            )
                            .frame(width: 120, height: 68)
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
            do {
                try await database.replaceTranscriptFeatures(
                    videoID: video.id,
                    features: result.features,
                    proposals: result.proposals)
                try await database.replaceTopicRanges(videoID: video.id, topics: newTopics)
                status = "Created \(newTopics.count) topics and \(result.proposals.count) cleanup proposals."
                await load()
            } catch {
                store.presentError("Could not analyze transcript", error)
            }
            isWorking = false
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
        let original = transcripts.first { !$0.isTranslation }
        let source = original.map { Locale.Language(identifier: $0.language) }
        translationConfiguration = TranslationSession.Configuration(
            source: source, target: Locale.Language(identifier: targetLanguage))
        isWorking = true
        status = "Preparing on-device translation…"
    }

    private func translate(using session: TranslationSession) async {
        guard let database = store.database else { return }
        let originals = transcripts.filter { !$0.isTranslation }
        do {
            try await session.prepareTranslation()
            let requests = originals.map {
                TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id))
            }
            let responses = try await session.translations(from: requests)
            let translated = Dictionary(
                uniqueKeysWithValues: responses.compactMap { response in
                    response.clientIdentifier.map { ($0, response.targetText) }
                })
            let segments = originals.compactMap { row -> TranscriptSegment? in
                guard let text = translated[String(row.id)] else { return nil }
                return TranscriptSegment(start: row.startTime, end: row.endTime, text: text, words: nil)
            }
            try await database.replaceTranscripts(
                videoID: video.id, language: targetLanguage,
                isTranslation: true, segments: segments,
                provider: "apple", model: "Translation")
            status = "Translated \(segments.count) segments to \(targetLanguage) on device."
            translationConfiguration = nil
            await load()
        } catch {
            status = "On-device translation was unavailable. Trying the configured AI provider…"
            await translateWithAI(originals, database: database)
        }
        isWorking = false
    }

    private func translateWithAI(_ originals: [TranscriptRow], database: Database) async {
        var segments: [TranscriptSegment] = []
        for row in originals {
            do {
                let response = try await store.ai.call(
                    prompt:
                        "Translate this caption to \(targetLanguage). Preserve names and meaning. Return only the translation:\n\(row.text)",
                    task: "translate", timeout: 60, log: { _ in })
                segments.append(
                    .init(
                        start: row.startTime, end: row.endTime,
                        text: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        words: nil))
            } catch {
                store.presentError("Caption translation failed", error)
                return
            }
        }
        do {
            try await database.replaceTranscripts(
                videoID: video.id, language: targetLanguage,
                isTranslation: true, segments: segments,
                provider: "ai", model: nil)
            status = "Translated \(segments.count) segments to \(targetLanguage) with the configured AI provider."
            await load()
        } catch {
            store.presentError("Could not save translation", error)
        }
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
