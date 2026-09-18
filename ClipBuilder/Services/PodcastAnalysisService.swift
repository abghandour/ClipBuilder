import AVFoundation
import Foundation
import ImageIO
import Vision

/// Transcript-first podcast analysis. Expensive frame sampling is deliberately
/// absent: Vision sees a small layout sample and at most two frames per turn.
actor PodcastAnalysisService {
    private let ai: AIService

    init(ai: AIService) {
        self.ai = ai
    }

    struct Result: Sendable {
        var runID: Int64
        var newPeople: [DetectedNewPerson]
        var suggestedFilename: String?
    }

    func analyze(video: VideoRecord, profile: BrandProfile, database: Database,
                 runName: String, provider: String?, model: String?, languageCode: String,
                 analyzer: Analyzer, transcription: TranscriptionService,
                 highlightThreshold: Double, holdSeconds: Double,
                 log: @escaping @Sendable (String) -> Void,
                 progress: @escaping @Sendable (Double, String) -> Void, useLocal: Bool = false,
                 capturedSettings: PodcastSettings? = nil,
                 checkpointing: PodcastCheckpointing? = nil) async throws -> Result {
        // An interrupted run's finished pieces: the people pass and the
        // exchange grouping are the model calls worth not repeating (the
        // transcript is cached on disk and the rest is local).
        var state = checkpointing?.resume ?? AnalysisCheckpoint.PodcastState()
        progress(0.03, "transcribing podcast")
        let segments = try await transcription.transcribePodcast(
            video: video, database: database, languageCode: languageCode, log: log)

        progress(0.30, "separating speakers")
        let turns = try await PodcastSpeakerSeparator.separate(video: video, segments: segments)

        progress(0.43, "identifying speakers")
        let roster: [VideoPersonRecord]
        let newPeople: [DetectedNewPerson]
        let suggestedFilename: String?
        if state.peopleDone {
            log("Resuming \(video.filename): the people pass is already done — reusing its roster")
            roster = try await database.fetchVideoPeople(videoID: video.id)
            newPeople = state.newPeople
            suggestedFilename = state.suggestedFilename
        } else {
            let peopleBefore = Set((try await database.fetchPeople()).map(\.key))
            let peopleResult = try await analyzer.detectPeopleOnly(
                video: video, profile: profile, database: database,
                provider: provider, model: model,
                sampleTimes: Self.identitySampleTimes(turns: turns, duration: video.duration), log: log)
            roster = peopleResult.roster
            newPeople = roster.filter { !peopleBefore.contains($0.key) }.map {
                DetectedNewPerson(key: $0.key, descriptor: $0.descriptor,
                                  suggestedName: $0.name.isEmpty ? nil : $0.name,
                                  videoURL: video.url, videoFilename: video.filename,
                                  sampleTime: $0.portraitAt)
            }
            suggestedFilename = peopleResult.suggestedFilename
            state.peopleDone = true
            state.newPeople = newPeople
            state.suggestedFilename = suggestedFilename
            await checkpointing?.save(state)
        }

        progress(0.55, "reading speaker motion")
        var visual = await PodcastVisualAnalyzer.analyze(video: video, turns: turns)
        // Who sits in which tile: the People pass's portraits name the cells.
        visual.tiles = PodcastVisualAnalyzer.named(visual.tiles, roster: roster)
        try await database.setPodcastLayout(videoID: video.id, layout: visual.layout,
                                            seamX: visual.seamX,
                                            confidence: visual.layoutConfidence, tiles: visual.tiles)
        if visual.layout == .grid {
            log("Podcast layout: grid of \(visual.tiles.count) tiles"
                + (visual.tiles.compactMap(\.personKey).isEmpty ? ""
                   : " (" + visual.tiles.map { "\($0.index): \($0.personKey ?? "?")" }.joined(separator: ", ") + ")"))
        }
        progress(0.60, "tracking who is talking")
        let corrections = Self.voiceCorrections(
            rows: (try? await database.fetchTranscripts(videoID: video.id)) ?? [], tiles: visual.tiles, log: log)
        let tracked = try await Self.resolveTurns(video: video, audioTurns: turns, visual: visual,
                                                  roster: roster, holdSeconds: holdSeconds,
                                                  corrections: corrections, log: log)
        let resolved = Self.cleaned(tracked.turns, words: segments.flatMap { $0.words ?? [] },
                                    audioTrust: tracked.audioTrust, log: log)
        try await database.replaceSpeakerTurns(videoID: video.id, turns: resolved)
        await Self.recutTranscriptBySpeaker(video: video, database: database, turns: resolved, log: log)
        let podcastSettings = capturedSettings ?? SettingsStore.loadSettings().podcast
        let enrichment = TranscriptFeatureAnalyzer.analyze(
            segments: segments, videoID: video.id,
            speakerKeys: Array(Set(resolved.compactMap(\.personKey))).sorted(),
            mediaDuration: video.duration,
            speakerHints: resolved.compactMap { turn in
                turn.personKey.map {
                    TranscriptSpeakerHint(startTime: turn.start, endTime: turn.end, personKey: $0)
                }
            },
            deadAirThreshold: podcastSettings.deadAirSeconds,
            fillerRunThreshold: podcastSettings.fillerRunSeconds)
        try await database.replaceTranscriptFeatures(videoID: video.id,
                                                     features: enrichment.features,
                                                     proposals: podcastSettings.cleanupCutPolicy.applied(to: enrichment.proposals))
        let topics = TopicSegmenter.segment(enrichment.features, videoID: video.id)
        try await database.replaceTopicRanges(videoID: video.id, topics: topics)
        let accepted = enrichment.proposals.count { podcastSettings.cleanupCutPolicy.decision(for: $0.kind) == .accepted }
        if accepted > 0 {
            log("Cleanup cuts: \(accepted) of \(enrichment.proposals.count) accepted by the \(podcastSettings.cleanupCutPolicy.label.lowercased()) policy")
        }

        progress(0.70, "grouping complete exchanges")
        let outcome: PodcastExchangeSegmenter.Outcome
        if let exchanges = state.exchanges {
            log("Resuming \(video.filename): the exchanges were grouped before the stop — reusing them")
            outcome = PodcastExchangeSegmenter.Outcome(
                exchanges: exchanges,
                provenance: AIProvenance(provider: state.exchangesProvider, model: state.exchangesModel, task: "exchanges"))
        } else {
            outcome = try await PodcastExchangeSegmenter(ai: ai).segment(
                segments: segments, turns: resolved, provider: provider, model: model, log: log, useLocal: useLocal)
            state.exchanges = outcome.exchanges
            state.exchangesProvider = outcome.provenance?.provider
            state.exchangesModel = outcome.provenance?.model
            await checkpointing?.save(state)
        }
        var tagRanges = Self.exchangeTagRanges(outcome.exchanges, layout: visual.layout,
                                               highlightThreshold: highlightThreshold)
        let chapters = Self.chapters(topics: topics, exchanges: outcome.exchanges)
        for (tag, ranges) in Self.chapterTagRanges(chapters) { tagRanges[tag, default: []].append(contentsOf: ranges) }
        if !chapters.isEmpty {
            log("Chapters: \(chapters.count) from the topic analysis, each holding two or more exchanges")
        }
        let runID = try await database.saveAnalysis(
            videoID: video.id, runName: runName,
            instructions: "Transcript-first podcast analysis; whole question-and-answer exchanges",
            sampleInterval: nil, notesJSON: nil, tagRanges: tagRanges, moments: [],
            analyzedTags: ["podcast"], provider: outcome.provenance?.provider,
            model: outcome.provenance?.model, mode: "speech")
        try await database.markAnalysisRunTranscribed(id: runID)

        let sceneRows = try await database.sceneRanges(runID: runID)
        let encoder = JSONEncoder()
        // Chapters: their story is their exchanges' titles; the exchanges
        // inside become their beats.
        for scene in sceneRows {
            guard let chapter = chapters.first(where: {
                abs($0.start - scene.start) < 0.02 && abs($0.end - scene.end) < 0.02
            }) else { continue }
            try await database.setSceneNarrative(scene.id, narrative: chapter.narrative, score: chapter.score)
            for beat in sceneRows where beat.id != scene.id
                && chapter.exchanges.contains(where: { abs($0.start - beat.start) < 0.02 && abs($0.end - beat.end) < 0.02 }) {
                try await database.setSceneParent(beat.id, parentID: scene.id)
            }
        }
        for scene in sceneRows {
            guard let exchange = outcome.exchanges.first(where: {
                abs($0.start - scene.start) < 0.02 && abs($0.end - scene.end) < 0.02
            }) else { continue }
            try await database.setSceneNarrative(scene.id,
                                                 narrative: "\(exchange.title) — \(exchange.summary)",
                                                 score: exchange.score)
            try await database.setSceneScore(scene.id, score: exchange.score,
                                             excitement: exchange.score / 10)
            try await database.setSceneFavorite(scene.id,
                                                favorite: Self.shouldFavorite(
                                                    score: exchange.score,
                                                    threshold: highlightThreshold))
            let path = PodcastSpeakerTimelineResolver.cameraPath(
                for: scene.start...scene.end, turns: resolved,
                layout: visual.layout, videoSize: CGSize(width: video.width, height: video.height),
                roster: roster, minimumHold: holdSeconds, tiles: visual.tiles)
            if !path.keyframes.isEmpty, let data = try? encoder.encode(path) {
                try await database.setSceneCenterStagePath(
                    scene.id, json: String(data: data, encoding: .utf8))
            }
        }
        progress(1, "podcast ready")
        return Result(runID: runID, newPeople: newPeople, suggestedFilename: suggestedFilename)
    }

    /// The tracked turns with mid-sentence hops folded back into the
    /// speaker around them (see SpeakerTurnCleanup).
    /// With a trusted voice (`audioTrust` near 1) a hop the voice backs at
    /// 60% or more is a short answer and stands.
    static func cleaned(_ turns: [SpeakerTurn], words: [TranscriptWord], audioTrust: Double = 0,
                        log: @Sendable (String) -> Void) -> [SpeakerTurn] {
        let voiceBacked = audioTrust >= 0.9
        let cleaned = SpeakerTurnCleanup.absorbInterjections(turns, words: words,
                                                             supported: { voiceBacked && $0.confidence >= 0.6 })
        let absorbed = turns.count - cleaned.count
        if absorbed > 0 {
            log("Speaker turns: \(absorbed) short hop\(absorbed == 1 ? "" : "s") to another tile fell inside a sentence — kept with the speaker"
                + (voiceBacked ? " (hops the voice backs were left alone)" : ""))
        }
        return cleaned
    }

    /// The turns the tracker resolved and how far its voice profiles are
    /// trusted (0 when the picture alone decided).
    struct Resolution: Sendable {
        var turns: [SpeakerTurn]
        var audioTrust: Double
    }

    /// Once the turns are known, rows that straddle a speaker change are
    /// split at the word gap so every row has one speaker (captions and the
    /// transcript editor both read better). A failure only logs: the turns
    /// are already saved and the rows still work unsplit.
    static func recutTranscriptBySpeaker(video: VideoRecord, database: Database, turns: [SpeakerTurn],
                                         log: @Sendable (String) -> Void) async {
        guard !turns.isEmpty, let rows = try? await database.transcriptRecutBase(videoID: video.id) else { return }
        let plan = TranscriptSpeakerRecut.plan(rows: rows, turns: turns)
        guard plan.hasChanges else { return }
        do {
            try await database.recutTranscript(videoID: video.id, pieces: plan.pieces)
            log("\(video.filename): transcript re-cut by speaker — \(plan.splitRows) row\(plan.splitRows == 1 ? "" : "s") split where the speaker changed")
        } catch {
            log("\(video.filename): could not re-cut the transcript by speaker — \(error.localizedDescription)")
        }
    }

    /// The speaker map alone, for talking footage the visual pipeline
    /// analyzes (interviews): voices from the transcript, the layout and its
    /// tiles from the picture, each turn placed and named, all persisted so
    /// the Wizard's speakers query and the speaker-follow camera can use
    /// them. Needs transcript rows; returns the turns it stored.
    @discardableResult
    static func mapSpeakers(video: VideoRecord, database: Database, holdSeconds: Double,
                            outcomeSink: (@Sendable (SpeakerTracker.Outcome) -> Void)? = nil,
                            log: @escaping @Sendable (String) -> Void) async throws -> [SpeakerTurn] {
        let rows = try await database.fetchTranscripts(videoID: video.id).filter { !$0.isTranslation }
        guard !rows.isEmpty else { return [] }
        let segments = rows.map { TranscriptSegment(start: $0.startTime, end: $0.endTime, text: $0.text, words: $0.words) }
        let turns = try await PodcastSpeakerSeparator.separate(video: video, segments: segments)
        guard !turns.isEmpty else { return [] }
        let roster = (try? await database.fetchVideoPeople(videoID: video.id)) ?? []
        var visual = await PodcastVisualAnalyzer.analyze(video: video, turns: turns)
        visual.tiles = PodcastVisualAnalyzer.named(visual.tiles, roster: roster)
        try await database.setPodcastLayout(videoID: video.id, layout: visual.layout, seamX: visual.seamX,
                                            confidence: visual.layoutConfidence, tiles: visual.tiles)
        let corrections = voiceCorrections(rows: rows, tiles: visual.tiles, log: log)
        let tracked = try await resolveTurns(video: video, audioTurns: turns, visual: visual,
                                             roster: roster, holdSeconds: holdSeconds,
                                             corrections: corrections, outcomeSink: outcomeSink, log: log)
        let resolved = cleaned(tracked.turns, words: segments.flatMap { $0.words ?? [] },
                               audioTrust: tracked.audioTrust, log: log)
        try await database.replaceSpeakerTurns(videoID: video.id, turns: resolved)
        await recutTranscriptBySpeaker(video: video, database: database, turns: resolved, log: log)
        let named = Set(resolved.compactMap(\.personKey)).count
        log("Speaker map for \(video.filename): \(resolved.count) turns, layout \(visual.layout.label.lowercased())"
            + (visual.tiles.isEmpty ? "" : " with \(visual.tiles.count) tiles") + ", \(named) named speaker(s)")
        return resolved
    }

    /// Who speaks when. With two or more face slots on screen the speaker
    /// tracker decides from voice clusters and mouth motion together, for any
    /// number of people; a single camera keeps the transcript-window turns
    /// and the side/portrait resolution.
    static func resolveTurns(video: VideoRecord, audioTurns: [SpeakerTurn], visual: PodcastVisualAnalyzer.Result,
                             roster: [VideoPersonRecord], holdSeconds: Double,
                             corrections: [SpeakerTracker.Correction] = [],
                             outcomeSink: (@Sendable (SpeakerTracker.Outcome) -> Void)? = nil,
                             log: @escaping @Sendable (String) -> Void) async throws -> Resolution {
        let fallback = Resolution(turns: PodcastSpeakerTimelineResolver.resolve(
            audioTurns: audioTurns, picture: visual.talkers, layout: visual.layout,
            roster: roster, minimumHold: holdSeconds, tiles: visual.tiles), audioTrust: 0)
        guard visual.tiles.count >= 2, !audioTurns.isEmpty else { return fallback }
        do {
            let outcome = try await trackSpeakers(video: video, speech: audioTurns.map { $0.start...$0.end },
                                                  tiles: visual.tiles, corrections: corrections, log: log)
            outcomeSink?(outcome)
            guard !outcome.turns.isEmpty else { return fallback }
            log(String(format: "Speaker tracking: %d voice(s) over %d slot(s), %d turns, margin %.2f",
                       outcome.clusterCount, visual.tiles.count, outcome.turns.count, outcome.margin))
            if let enrollment = outcome.enrollment {
                let accuracy = enrollment.heldOutAgreement.map {
                    String(format: ", %.0f%% right on %d held-out windows", $0 * 100, enrollment.heldOutWindows)
                } ?? ""
                log(String(format: "Voices learned from the border%@: %d of %d tiles, separation %.2f%@ — audio trusted %.0f%%",
                           enrollment.correctionWindows > 0 ? " and \(enrollment.correctionWindows) corrected windows" : "",
                           enrollment.slotCount, visual.tiles.count, enrollment.separation, accuracy, enrollment.trust * 100))
                let disagreement = outcome.disagreement
                if disagreement.bins > 0 {
                    log(String(format: "Voice vs border: the trusted voice named another tile than the lit one over %.1f s (%.1f s of it sure, %.1f s well inside a lit stretch) — the voice held %.0f%% of it",
                               Double(disagreement.bins) * VisualSpeechActivity.binSeconds,
                               Double(disagreement.confident) * VisualSpeechActivity.binSeconds,
                               Double(disagreement.interior) * VisualSpeechActivity.binSeconds,
                               Double(disagreement.followedAudio) / Double(disagreement.bins) * 100))
                }
            } else {
                log("Voices learned from the border: none — no tile was lit alone long enough, so the audio keeps its blind clustering")
            }
            return Resolution(turns: outcome.turns, audioTrust: outcome.enrollment?.trust ?? 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("Speaker tracking unavailable; keeping the side-based turns (\(error))")
            return fallback
        }
    }

    @concurrent
    static func trackSpeakers(video: VideoRecord, speech: [ClosedRange<Double>], tiles: [PodcastTile],
                              corrections: [SpeakerTracker.Correction] = [],
                              log: @escaping @Sendable (String) -> Void) async throws -> SpeakerTracker.Outcome {
        let audioURL = try await NormalizedAudioCache.shared.audio(source: video.url)
        // Neural voice embeddings when the bundled model loads; the
        // spectral averages otherwise — and the log always says which.
        var windows: [SpeakerFeatures.Window] = []
        var kind = SpeakerTracker.FeatureKind.spectral
        if SpeakerEmbedder.isAvailable {
            do {
                windows = try SpeakerEmbedder.windows(audioURL: audioURL, speech: speech)
                if windows.isEmpty {
                    log("Voice embeddings: no speech range was long enough for a window — using spectral voice features")
                } else {
                    kind = .embedding
                    log("Voice embeddings: \(windows.count) windows through the on-device ECAPA-TDNN model")
                }
            } catch {
                log("Voice embeddings unavailable (\(error.localizedDescription)) — using spectral voice features")
            }
        } else {
            log("Voice embedding model not loaded (\(SpeakerEmbedder.loadFailure?.localizedDescription ?? "unknown reason")) — using spectral voice features")
        }
        if windows.isEmpty {
            windows = try SpeakerFeatures.windows(audioURL: audioURL, speech: speech)
        }
        try Task.checkCancellation()
        let activity = try await VisualSpeechActivity.measure(url: video.url, tiles: tiles, duration: video.duration, log: log)
        try Task.checkCancellation()
        return SpeakerTracker.track(.init(audioWindows: windows, activity: activity, speech: speech,
                                          tiles: tiles, duration: video.duration, featureKind: kind,
                                          corrections: corrections), videoID: video.id)
    }

    /// The rows the user attributed by hand, as the tracker's corrections:
    /// each row whose person sits in a tile teaches that tile its voice.
    nonisolated static func voiceCorrections(rows: [TranscriptRow], tiles: [PodcastTile],
                                             log: (@Sendable (String) -> Void)? = nil) -> [SpeakerTracker.Correction] {
        let slotByPerson = Dictionary(tiles.compactMap { tile in tile.personKey.map { ($0, tile.index) } },
                                      uniquingKeysWith: { first, _ in first })
        let corrections = rows.compactMap { row -> SpeakerTracker.Correction? in
            guard !row.isTranslation, let key = row.speakerKey, !key.isEmpty, let slot = slotByPerson[key],
                  row.endTime > row.startTime else { return nil }
            return SpeakerTracker.Correction(range: row.startTime...row.endTime, slot: slot)
        }
        if !corrections.isEmpty {
            let seconds = Int(corrections.reduce(0) { $0 + $1.range.upperBound - $1.range.lowerBound })
            log?("Voice corrections: \(corrections.count) rows (\(seconds) s) attributed by hand teach the tracker")
        }
        return corrections
    }

    /// saveAnalysis creates a scene per distinct range. Every tag must use the
    /// whole exchange; question/answer subranges are deliberately not persisted.
    nonisolated static func exchangeTagRanges(_ exchanges: [PodcastExchange], layout: PodcastLayout,
                                              highlightThreshold: Double) -> [String: [(start: Double, end: Double)]] {
        var tagRanges: [String: [(start: Double, end: Double)]] = [:]
        for exchange in exchanges {
            let range = (start: exchange.start, end: exchange.end)
            // One tag for the whole question-and-answer: the pair "question"
            // + "answer" on a single scene read as if it had been split.
            for tag in ["podcast", "q&a", "podcast-exchange"] {
                tagRanges[tag, default: []].append(range)
            }
            if exchange.score >= highlightThreshold {
                tagRanges["reel-highlight", default: []].append(range)
            }
            if layout == .splitHorizontal {
                tagRanges["podcast:split", default: []].append(range)
            }
            if layout == .grid {
                tagRanges["podcast:grid", default: []].append(range)
            }
            for key in exchange.speakerKeys {
                tagRanges["person:\(key)", default: []].append(range)
            }
        }
        return tagRanges
    }

    /// A chapter: a topic of the conversation holding two or more whole
    /// exchanges, spanning exactly those exchanges so it never cuts an
    /// answer. The exchanges become its beats (children) so the Scenes
    /// screen and the Wizard can take the whole story or one exchange.
    nonisolated struct Chapter: Sendable, Equatable {
        var start: Double
        var end: Double
        var title: String
        var exchanges: [PodcastExchange]
        var speakerKeys: [String] { Array(Set(exchanges.flatMap(\.speakerKeys))).sorted() }
        var score: Double { exchanges.isEmpty ? 0 : exchanges.reduce(0) { $0 + $1.score } / Double(exchanges.count) }
        var narrative: String {
            let beats = exchanges.map(\.title).filter { !$0.isEmpty }.joined(separator: " · ")
            return beats.isEmpty ? title : "\(title) — \(beats)"
        }
    }

    /// Chapters from the transcript's topics: each topic takes the
    /// exchanges whose middle falls inside it; a topic with fewer than two
    /// is no chapter (the exchange already is the scene).
    nonisolated static func chapters(topics: [TopicRange], exchanges: [PodcastExchange]) -> [Chapter] {
        var result: [Chapter] = []
        for topic in topics.sorted(by: { $0.startTime < $1.startTime }) {
            let inside = exchanges
                .filter { ($0.start + $0.end) / 2 >= topic.startTime && ($0.start + $0.end) / 2 < topic.endTime }
                .sorted { $0.start < $1.start }
            guard inside.count >= 2, let first = inside.first, let last = inside.last else { continue }
            result.append(Chapter(start: first.start, end: last.end, title: topic.title, exchanges: inside))
        }
        return result
    }

    /// Tag ranges for chapters: the same scene machinery, one scene per chapter.
    nonisolated static func chapterTagRanges(_ chapters: [Chapter]) -> [String: [(start: Double, end: Double)]] {
        var tagRanges: [String: [(start: Double, end: Double)]] = [:]
        for chapter in chapters {
            let range = (start: chapter.start, end: chapter.end)
            tagRanges["podcast", default: []].append(range)
            tagRanges["chapter", default: []].append(range)
            for key in chapter.speakerKeys { tagRanges["person:\(key)", default: []].append(range) }
        }
        return tagRanges
    }

    nonisolated static func shouldFavorite(score: Double, threshold: Double) -> Bool {
        score >= threshold
    }

    nonisolated static func identitySampleTimes(turns: [SpeakerTurn], duration: Double) -> [Double] {
        // Three representative moments per voice, regardless of recording length.
        var times: [Double] = []
        for cluster in Set(turns.map(\.cluster)).sorted() {
            let matches = turns.filter { $0.cluster == cluster }
            for index in Set([0, matches.count / 2, matches.count - 1]).sorted() where index >= 0 {
                times.append((matches[index].start + matches[index].end) / 2)
            }
        }
        if times.isEmpty { times = [duration / 2] }
        return Array(Set(times.map { min(max(0, $0), max(0, duration - 0.1)) })).sorted()
    }
}

nonisolated enum PodcastSpeakerSeparator {
    /// Lightweight on-device voice embeddings (energy, sign changes and
    /// autocorrelation) clustered deterministically into at most two voices.
    @concurrent
    static func separate(video: VideoRecord, segments: [TranscriptSegment]) async throws -> [SpeakerTurn] {
        let segments = voiceWindows(segments)
        guard !segments.isEmpty else { return [] }
        let audioURL = try await NormalizedAudioCache.shared.audio(source: video.url)
        let file = try AVAudioFile(forReading: audioURL)
        let rate = file.processingFormat.sampleRate
        var vectors: [[Double]] = []
        for segment in segments {
            try Task.checkCancellation()
            let start = max(0, segment.start)
            let duration = min(4, max(0.12, segment.end - start))
            file.framePosition = AVAudioFramePosition(start * rate)
            let count = AVAudioFrameCount(duration * rate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: count) else {
                vectors.append(Array(repeating: 0, count: 24)); continue
            }
            try file.read(into: buffer, frameCount: count)
            vectors.append(embedding(buffer))
        }
        return turns(segments: segments, embeddings: vectors, videoID: video.id)
    }

    static func voiceWindows(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.flatMap { segment -> [TranscriptSegment] in
            guard let words = segment.words, !words.isEmpty else { return [segment] }
            var windows: [TranscriptSegment] = []
            var first = 0
            for index in words.indices {
                guard words[index].end - words[first].start >= 1 || index == words.count - 1 else { continue }
                let group = Array(words[first...index])
                windows.append(TranscriptSegment(start: words[first].start, end: words[index].end,
                                                  text: group.map(\.word).joined(separator: " "), words: group))
                first = index + 1
            }
            return windows
        }
    }

    static func turns(segments: [TranscriptSegment], embeddings: [[Double]],
                      videoID: Int64) -> [SpeakerTurn] {
        guard segments.count == embeddings.count, !segments.isEmpty else { return [] }
        let labels = cluster(embeddings)
        let raw = segments.enumerated().map { index, segment in
            SpeakerTurn(videoID: videoID, start: segment.start, end: segment.end,
                        cluster: labels[index], confidence: clusterConfidence(
                            embeddings[index], label: labels[index], embeddings: embeddings, labels: labels))
        }
        var merged: [SpeakerTurn] = []
        for turn in raw {
            if var last = merged.last, last.cluster == turn.cluster, turn.start - last.end <= 0.7 {
                last.end = max(last.end, turn.end)
                last.confidence = (last.confidence + turn.confidence) / 2
                merged[merged.count - 1] = last
            } else {
                merged.append(turn)
            }
        }
        return merged
    }

    static func cluster(_ vectors: [[Double]]) -> [Int] {
        guard vectors.count >= 3 else { return Array(repeating: 0, count: vectors.count) }
        // Compare timbre dimensions in standard-deviation units. Raw log
        // energy is numerically much larger than autocorrelation and would
        // otherwise hide a clear pitch difference.
        let normalized = standardize(vectors)
        var a = normalized[0]
        var b = normalized.max(by: { distance($0, a) < distance($1, a) }) ?? a
        guard distance(a, b) > 0.01 else { return Array(repeating: 0, count: vectors.count) }
        var labels = Array(repeating: 0, count: vectors.count)
        for _ in 0..<8 {
            labels = normalized.map { distance($0, a) <= distance($0, b) ? 0 : 1 }
            if labels.allSatisfy({ $0 == 0 }) || labels.allSatisfy({ $0 == 1 }) {
                return Array(repeating: 0, count: vectors.count)
            }
            a = centroid(normalized.enumerated().filter { labels[$0.offset] == 0 }.map(\.element))
            b = centroid(normalized.enumerated().filter { labels[$0.offset] == 1 }.map(\.element))
        }
        return labels
    }

    private static func embedding(_ buffer: AVAudioPCMBuffer) -> [Double] {
        guard let channel = buffer.floatChannelData?.pointee else { return Array(repeating: 0, count: 24) }
        let count = Int(buffer.frameLength)
        guard count > 2 else { return Array(repeating: 0, count: 24) }
        let samples = (0..<count).map { Double(channel[$0]) }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
        let zcr = zip(samples, samples.dropFirst()).reduce(0) { total, pair in
            total + ((pair.0 >= 0) != (pair.1 >= 0) ? 1 : 0)
        }
        func correlation(lag: Int) -> Double {
            guard samples.count > lag else { return 0 }
            let products = zip(samples.dropFirst(lag), samples.dropLast(lag)).map { pair in
                pair.0 * pair.1
            }
            return products.reduce(0, +) / Double(products.count)
        }
        // Fixed-rate spectral envelope adds voice timbre beyond pitch and
        // loudness. Average short Hann windows, then remove overall gain.
        let windowSize = min(512, samples.count)
        var spectrum = [Double](repeating: 0, count: 20)
        let starts = stride(from: 0, through: max(0, samples.count - windowSize),
                            by: max(windowSize, samples.count / 8))
        var windowCount = 0
        for start in starts {
            windowCount += 1
            for band in spectrum.indices {
                let mel = 200.0 + Double(band) * 120
                let frequency = 700 * (pow(10, mel / 2595) - 1)
                let coefficient = 2 * cos(2 * .pi * frequency / 16000)
                var previous = 0.0, older = 0.0
                for offset in 0..<windowSize {
                    let hann = 0.5 - 0.5 * cos(2 * .pi * Double(offset) / Double(windowSize - 1))
                    let value = samples[start + offset] * hann + coefficient * previous - older
                    older = previous
                    previous = value
                }
                spectrum[band] += max(0, previous * previous + older * older - coefficient * previous * older)
            }
        }
        spectrum = spectrum.map { log(max(1e-12, $0 / Double(max(1, windowCount)))) }
        let mean = spectrum.reduce(0, +) / Double(spectrum.count)
        return spectrum.map { $0 - mean }
            + [Double(zcr) / Double(samples.count), correlation(lag: 20) / max(1e-12, rms * rms),
               correlation(lag: 40) / max(1e-12, rms * rms), correlation(lag: 80) / max(1e-12, rms * rms)]
    }

    private static func normalize(_ vector: [Double]) -> [Double] {
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return length > 0 ? vector.map { $0 / length } : vector
    }
    private static func standardize(_ vectors: [[Double]]) -> [[Double]] {
        guard let first = vectors.first, !first.isEmpty else { return vectors }
        let means = first.indices.map { index in
            vectors.reduce(0) { $0 + $1[index] } / Double(vectors.count)
        }
        let deviations = first.indices.map { index in
            let variance = vectors.reduce(0) { $0 + pow($1[index] - means[index], 2) }
                / Double(vectors.count)
            return sqrt(variance)
        }
        return vectors.map { vector in
            vector.indices.map { index in
                deviations[index] > 0.000_001
                    ? (vector[index] - means[index]) / deviations[index] : 0
            }
        }
    }
    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        sqrt(zip(a, b).reduce(0) { $0 + pow($1.0 - $1.1, 2) })
    }
    private static func centroid(_ vectors: [[Double]]) -> [Double] {
        guard let first = vectors.first else { return [] }
        return first.indices.map { index in vectors.reduce(0) { $0 + $1[index] } / Double(vectors.count) }
    }
    private static func clusterConfidence(_ vector: [Double], label: Int,
                                          embeddings: [[Double]], labels: [Int]) -> Double {
        let own = centroid(embeddings.enumerated().filter { labels[$0.offset] == label }.map(\.element))
        let other = centroid(embeddings.enumerated().filter { labels[$0.offset] != label }.map(\.element))
        guard !other.isEmpty else { return 0.5 }
        let ownDistance = distance(normalize(vector), normalize(own))
        let otherDistance = distance(normalize(vector), normalize(other))
        return min(1, max(0, otherDistance / max(0.001, ownDistance + otherDistance)))
    }
}

nonisolated enum PodcastSpeakerTimelineResolver {
    static func resolve(audioTurns: [SpeakerTurn], picture: [PictureTalkerSignal],
                        layout: PodcastLayout, roster: [VideoPersonRecord],
                        minimumHold: Double, tiles: [PodcastTile] = []) -> [SpeakerTurn] {
        if layout == .grid, !tiles.isEmpty {
            return resolveGrid(audioTurns: audioTurns, picture: picture, roster: roster, tiles: tiles)
        }
        var clusterSides: [Int: PodcastSpeakerSide] = [:]
        for cluster in Set(audioTurns.map(\.cluster)) {
            let overlapping = picture.filter { signal in
                audioTurns.contains { $0.cluster == cluster && signal.end > $0.start && signal.start < $0.end }
            }
            let left = overlapping.filter { $0.side == .left }.reduce(0) { $0 + $1.confidence }
            let right = overlapping.filter { $0.side == .right }.reduce(0) { $0 + $1.confidence }
            clusterSides[cluster] = left == right ? .unknown : (left > right ? .left : .right)
        }
        var personBySide: [PodcastSpeakerSide: String] = [:]
        for person in roster {
            guard let box = person.portraitBox else { continue }
            let side: PodcastSpeakerSide = box.x + box.w / 2 < 0.5 ? .left : .right
            if personBySide[side] == nil { personBySide[side] = person.key }
        }
        var result: [SpeakerTurn] = []
        // Hold time belongs to the camera, never to the speaker identity.
        // A brief interjection must still be attributed to its actual speaker.
        for var turn in audioTurns {
            let strongest = picture.filter { $0.end > turn.start && $0.start < turn.end }
                .max { $0.confidence < $1.confidence }
            let audioSide = turn.resolvedSide != .unknown ? turn.resolvedSide : (clusterSides[turn.cluster] ?? .unknown)
            let pictureWins = strongest.map {
                $0.side != .unknown && ($0.confidence >= 0.7 || $0.confidence > turn.confidence)
            } ?? false
            var side = pictureWins ? (strongest?.side ?? audioSide) : audioSide
            if layout == .singleCamera, side == .unknown, roster.count == 1 { side = .full }
            turn.pictureSide = strongest?.side ?? .unknown
            turn.pictureConfidence = strongest?.confidence ?? 0
            turn.resolvedSide = side
            turn.personKey = personBySide[side]
                ?? (layout == .singleCamera && roster.count == 1 ? roster.first?.key : nil)
            result.append(turn)
        }
        return result
    }

    /// Grid layouts: a turn belongs to the tile whose mouth moved during it;
    /// a voice cluster's usual tile covers turns the picture could not read.
    /// The tile's person, when the People pass named one, is the speaker.
    static func resolveGrid(audioTurns: [SpeakerTurn], picture: [PictureTalkerSignal],
                            roster: [VideoPersonRecord], tiles: [PodcastTile]) -> [SpeakerTurn] {
        var clusterTiles: [Int: Int] = [:]
        for cluster in Set(audioTurns.map(\.cluster)) {
            var weight: [Int: Double] = [:]
            for signal in picture where signal.tile != nil {
                if audioTurns.contains(where: { $0.cluster == cluster && signal.end > $0.start && signal.start < $0.end }) {
                    weight[signal.tile!, default: 0] += signal.confidence
                }
            }
            clusterTiles[cluster] = weight.max { $0.value < $1.value }?.key
        }
        func person(in tile: Int?) -> String? {
            guard let tile, let cell = tiles.first(where: { $0.index == tile }) else { return nil }
            if let key = cell.personKey { return key }
            return roster.first { person in
                guard let box = person.portraitBox else { return false }
                return cell.contains(x: box.x + box.w / 2, y: box.y + box.h / 2)
            }?.key
        }
        var result: [SpeakerTurn] = []
        for var turn in audioTurns {
            let strongest = picture.filter { $0.tile != nil && $0.end > turn.start && $0.start < turn.end }
                .max { $0.confidence < $1.confidence }
            let pictureWins = strongest.map { $0.confidence >= 0.7 || $0.confidence > turn.confidence } ?? false
            let tile = pictureWins ? strongest?.tile : (clusterTiles[turn.cluster] ?? strongest?.tile)
            turn.tile = tile
            turn.pictureSide = strongest?.side ?? .unknown
            turn.pictureConfidence = strongest?.confidence ?? 0
            turn.resolvedSide = tile.flatMap { index in tiles.first { $0.index == index } }
                .map { $0.centerX < 0.5 ? PodcastSpeakerSide.left : .right } ?? .unknown
            turn.personKey = person(in: tile)
            result.append(turn)
        }
        return result
    }

    /// The largest 9:16 crop that fits inside a tile's picture, centered on it.
    static func tileCrop(_ cell: PodcastTile, aspect: Double, canvasAspect: Double = 9.0 / 16.0)
        -> (x: Double, y: Double, w: Double, h: Double) {
        let tile = cell.picture
        // A crop of normalized height h is w = h × canvas ÷ source in normalized width.
        var h = tile.h
        var w = h * canvasAspect / aspect
        if w > tile.w { w = tile.w; h = w * aspect / canvasAspect }
        return (x: min(1 - w, max(0, tile.centerX - w / 2)), y: min(1 - h, max(0, tile.centerY - h / 2)), w: w, h: h)
    }

    static func cameraPath(for range: ClosedRange<Double>, turns: [SpeakerTurn],
                           layout: PodcastLayout, videoSize: CGSize,
                           roster: [VideoPersonRecord] = [],
                           minimumHold: Double = 1.5, tiles: [PodcastTile] = []) -> SceneCameraPath {
        let relevant = turns.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
        guard !relevant.isEmpty else { return SceneCameraPath(camera: "podcast", keyframes: []) }
        let aspect = videoSize.height > 0 ? videoSize.width / videoSize.height : 16 / 9
        let cropWidth = min(layout == .splitHorizontal ? 0.5 : 1, (9.0 / 16.0) / aspect)
        let grid = layout == .grid && !tiles.isEmpty
        func frame(_ turn: SpeakerTurn, at time: Double) -> CameraPathKeyframe {
            if grid, let tile = tiles.first(where: { $0.index == turn.tile }) ?? tiles.first {
                let crop = tileCrop(tile, aspect: aspect)
                return CameraPathKeyframe(t: max(0, time - range.lowerBound), x: crop.x, y: crop.y, w: crop.w, h: crop.h)
            }
            let portraitCenter = roster.first(where: { $0.key == turn.personKey })?.portraitBox
                .map { $0.x + $0.w / 2 }
            let center = layout == .singleCamera ? (portraitCenter ?? 0.5)
                : turn.resolvedSide == .right ? 0.75 : turn.resolvedSide == .left ? 0.25 : 0.5
            return CameraPathKeyframe(t: max(0, time - range.lowerBound),
                                      x: min(1 - cropWidth, max(0, center - cropWidth / 2)),
                                      y: 0, w: cropWidth, h: 1)
        }
        var frames: [CameraPathKeyframe] = []
        var previous: SpeakerTurn?
        var heldSince = range.lowerBound
        for turn in relevant {
            var time = max(range.lowerBound, turn.start)
            let changed = previous.map {
                grid ? $0.tile != turn.tile
                    : layout == .singleCamera ? $0.personKey != turn.personKey : $0.resolvedSide != turn.resolvedSide
            } ?? false
            if changed {
                time = max(time, heldSince + max(0, minimumHold))
                guard time < min(turn.end, range.upperBound) else { continue }
            }
            if let previous, changed, time > range.lowerBound + 0.02 {
                frames.append(frame(previous, at: time - 0.01))
            }
            frames.append(frame(turn, at: time))
            if previous == nil || changed { heldSince = time }
            previous = turn
        }
        if let previous { frames.append(frame(previous, at: range.upperBound)) }
        return SceneCameraPath(camera: "podcast", keyframes: frames)
    }
}

actor PodcastVisualAnalyzer {
    struct Result: Sendable {
        var layout: PodcastLayout
        var seamX: Double?
        var layoutConfidence: Double
        var talkers: [PictureTalkerSignal]
        var tiles: [PodcastTile] = []
    }

    /// One detected face: its box normalized to the frame with a top-left
    /// origin, and how open the mouth is.
    struct FaceSample: Sendable, Hashable {
        var box: CGRect
        var aperture: Double
        var centerX: Double { box.midX }
        var centerY: Double { box.midY }
    }

    static func analyze(video: VideoRecord, turns: [SpeakerTurn]) async -> Result {
        let layoutTimes = stride(from: 0.1, through: max(0.1, video.duration - 0.1),
                                 by: max(1, video.duration / 5)).prefix(5).map { $0 }
        let layoutFrames = await ThumbnailService.jpegFrames(url: video.url, at: layoutTimes,
                                                              maxDimension: 720, quality: 0.75)
        let available = layoutFrames.compactMap { $0 }
        var splitHits = 0
        var faceSets: [[CGRect]] = []
        for jpeg in available {
            let faces = await faceSamples(jpeg)
            faceSets.append(faces.map(\.box))
            let metrics = sideMetrics(faces)
            if metrics.keys.contains(.left) && metrics.keys.contains(.right) && hasCenterSeam(jpeg) {
                splitHits += 1
            }
        }
        let tiles = withPictureBounds(withFaceCenters(inferTiles(faceSets: faceSets), faceSets: faceSets), frames: available)
        var layoutConfidence = available.isEmpty ? 0 : Double(splitHits) / Double(available.count)
        var layout: PodcastLayout = layoutConfidence >= 0.6 ? .splitHorizontal : .singleCamera
        // Three or more fixed feeds, or two stacked, is a grid: sides cannot
        // tell its speakers apart.
        if tiles.count >= 3 || (tiles.count == 2 && abs(tiles[0].centerY - tiles[1].centerY) > abs(tiles[0].centerX - tiles[1].centerX)) {
            layout = .grid
            layoutConfidence = max(layoutConfidence, tilePresence(faceSets: faceSets, tiles: tiles))
        }

        let sampled = turns.count <= 160 ? turns : turns.enumerated().compactMap {
            $0.offset.isMultiple(of: max(1, (turns.count + 159) / 160)) ? $0.element : nil
        }
        let times = sampled.flatMap { turn -> [Double] in
            let midpoint = (turn.start + turn.end) / 2
            return [max(0, midpoint - 0.12), min(video.duration, midpoint + 0.12)]
        }
        let frames = await ThumbnailService.jpegFrames(url: video.url, at: times,
                                                       maxDimension: 720, quality: 0.75)
        var signals: [PictureTalkerSignal] = []
        for (index, turn) in sampled.enumerated() {
            guard frames.indices.contains(index * 2 + 1),
                  let before = frames[index * 2], let after = frames[index * 2 + 1] else { continue }
            let firstFaces = await faceSamples(before)
            let secondFaces = await faceSamples(after)
            if layout == .grid {
                // The tile whose mouth moved most is the talker.
                let first = tileMetrics(firstFaces, tiles: tiles)
                let second = tileMetrics(secondFaces, tiles: tiles)
                let deltas = tiles.map { tile in (tile, abs((second[tile.index] ?? 0) - (first[tile.index] ?? 0))) }
                let total = deltas.reduce(0) { $0 + $1.1 }
                guard total > 0.002, let best = deltas.max(by: { $0.1 < $1.1 }) else { continue }
                signals.append(PictureTalkerSignal(start: turn.start, end: turn.end,
                                                    side: best.0.centerX < 0.5 ? .left : .right,
                                                    confidence: min(1, best.1 / total), tile: best.0.index))
                continue
            }
            let first = sideMetrics(firstFaces)
            let second = sideMetrics(secondFaces)
            let left = abs((second[.left] ?? 0) - (first[.left] ?? 0))
            let right = abs((second[.right] ?? 0) - (first[.right] ?? 0))
            let total = left + right
            guard total > 0.002 else { continue }
            let side: PodcastSpeakerSide = left > right ? .left : .right
            signals.append(PictureTalkerSignal(start: turn.start, end: turn.end, side: side,
                                                confidence: min(1, max(left, right) / total)))
        }
        return Result(layout: layout, seamX: layout == .splitHorizontal ? 0.5 : nil,
                      layoutConfidence: layoutConfidence, talkers: signals,
                      tiles: tiles.count >= 2 ? tiles : [])
    }

    /// Cells of a fixed multi-feed layout from the faces seen in a few
    /// frames: face centers that recur in the same place are one feed; the
    /// distinct columns and rows they form become the grid, and each feed
    /// gets the cell around it. Fewer than two feeds is not a grid.
    nonisolated static func inferTiles(faceSets: [[CGRect]], minimumFrames: Int? = nil) -> [PodcastTile] {
        guard !faceSets.isEmpty else { return [] }
        var clusters: [(x: Double, y: Double, hits: Int)] = []
        for faces in faceSets {
            var seen = Set<Int>()
            for face in faces {
                let cx = face.midX, cy = face.midY
                if let index = clusters.indices.first(where: { !seen.contains($0) && hypot(clusters[$0].x - cx, clusters[$0].y - cy) < 0.14 }) {
                    let c = clusters[index]
                    let n = Double(c.hits)
                    clusters[index] = ((c.x * n + cx) / (n + 1), (c.y * n + cy) / (n + 1), c.hits + 1)
                    seen.insert(index)
                } else {
                    clusters.append((cx, cy, 1)); seen.insert(clusters.count - 1)
                }
            }
        }
        let needed = minimumFrames ?? max(1, min(2, faceSets.count))
        let steady = clusters.filter { $0.hits >= needed }
        guard steady.count >= 2 else { return [] }
        func groups(_ values: [Double]) -> [Double] {
            var centers: [Double] = []
            for value in values.sorted() {
                if let last = centers.last, abs(last - value) < 0.2 { centers[centers.count - 1] = (last + value) / 2 }
                else { centers.append(value) }
            }
            return centers
        }
        let columns = groups(steady.map(\.x)), rows = groups(steady.map(\.y))
        // A fixed multi-feed layout divides the frame evenly; cells are the
        // uniform grid the feeds sit in, not the midpoints between faces.
        func edges(_ centers: [Double]) -> [Double] {
            (0...centers.count).map { Double($0) / Double(centers.count) }
        }
        let columnEdges = edges(columns), rowEdges = edges(rows)
        func slot(_ value: Double, _ centers: [Double]) -> Int {
            centers.indices.min { abs(centers[$0] - value) < abs(centers[$1] - value) } ?? 0
        }
        var tiles: [PodcastTile] = []
        for cluster in steady {
            let column = slot(cluster.x, columns), row = slot(cluster.y, rows)
            let tile = PodcastTile(index: 0, x: columnEdges[column], y: rowEdges[row],
                                   w: columnEdges[column + 1] - columnEdges[column],
                                   h: rowEdges[row + 1] - rowEdges[row])
            if !tiles.contains(where: { $0.x == tile.x && $0.y == tile.y }) { tiles.append(tile) }
        }
        tiles.sort { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
        return tiles.enumerated().map { index, tile in var t = tile; t.index = index; return t }
    }

    /// Each tile with the mean center of the faces seen inside it, so a
    /// crop of the feed can sit on the person rather than the cell's middle.
    nonisolated static func withFaceCenters(_ tiles: [PodcastTile], faceSets: [[CGRect]]) -> [PodcastTile] {
        tiles.map { tile in
            var tile = tile
            let centers = faceSets.flatMap { $0 }.map { ($0.midX, $0.midY) }.filter { tile.contains(x: $0.0, y: $0.1) }
            guard !centers.isEmpty else { return tile }
            tile.faceX = (centers.map(\.0).reduce(0, +) / Double(centers.count) * 10000).rounded() / 10000
            tile.faceY = (centers.map(\.1).reduce(0, +) / Double(centers.count) * 10000).rounded() / 10000
            return tile
        }
    }

    /// Each tile trimmed to the picture inside it: the bounding box of the
    /// rows and columns that are not black, per frame, then the median edge
    /// over the frames. A box under 40% of the cell is not trusted.
    nonisolated static func withPictureBounds(_ tiles: [PodcastTile], frames: [Data]) -> [PodcastTile] {
        guard !frames.isEmpty else { return tiles }
        var decoded: [FramePixels] = []
        for frame in frames { if let pixels = FramePixels(frame) { decoded.append(pixels) } }
        guard !decoded.isEmpty else { return tiles }
        func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted[sorted.count / 2] }
        return tiles.map { tile -> PodcastTile in
            var boxes: [CGRect] = []
            for pixels in decoded { if let box = pixels.pictureBounds(within: tile) { boxes.append(box) } }
            guard boxes.count >= max(1, decoded.count / 2) else { return tile }
            let left: Double = median(boxes.map { Double($0.minX) })
            let right: Double = median(boxes.map { Double($0.maxX) })
            let top: Double = median(boxes.map { Double($0.minY) })
            let bottom: Double = median(boxes.map { Double($0.maxY) })
            let w: Double = right - left
            let h: Double = bottom - top
            guard w > 0, h > 0, w * h >= 0.4 * tile.w * tile.h else { return tile }
            // No trimming to report when the picture fills the cell.
            guard w < tile.w - 0.005 || h < tile.h - 0.005 else { return tile }
            var trimmed = tile
            trimmed.pictureX = (left * 10000).rounded() / 10000
            trimmed.pictureY = (top * 10000).rounded() / 10000
            trimmed.pictureW = (w * 10000).rounded() / 10000
            trimmed.pictureH = (h * 10000).rounded() / 10000
            return trimmed
        }
    }

    /// A small RGBA copy of a frame for cheap scans.
    nonisolated struct FramePixels {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(_ jpeg: Data) {
            guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else { return nil }
            let width = 320
            let height = max(2, Int((Double(image.height) / Double(image.width) * Double(width)).rounded()))
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width; self.height = height; self.pixels = pixels
        }

        /// The bounding box (fractions of the frame, top-left origin) of the
        /// rows and columns inside `tile` where at least a twentieth of the
        /// pixels are brighter than near-black.
        func pictureBounds(within tile: PodcastTile, threshold: UInt8 = 28) -> CGRect? {
            // CGContext draws with a bottom-left origin: flip the rows.
            let x0 = max(0, Int(tile.x * Double(width))), x1 = min(width, Int((tile.x + tile.w) * Double(width)))
            let y0 = max(0, Int(tile.y * Double(height))), y1 = min(height, Int((tile.y + tile.h) * Double(height)))
            guard x1 - x0 >= 4, y1 - y0 >= 4 else { return nil }
            func bright(_ x: Int, _ y: Int) -> Bool {
                let offset = ((height - 1 - y) * width + x) * 4
                return max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) > threshold
            }
            let rows = (y0..<y1).map { y in (x0..<x1).count { bright($0, y) } }
            let columns = (x0..<x1).map { x in (y0..<y1).count { bright(x, $0) } }
            let rowNeed = max(1, (x1 - x0) / 20), columnNeed = max(1, (y1 - y0) / 20)
            guard let top = rows.firstIndex(where: { $0 >= rowNeed }), let bottom = rows.lastIndex(where: { $0 >= rowNeed }),
                  let left = columns.firstIndex(where: { $0 >= columnNeed }), let right = columns.lastIndex(where: { $0 >= columnNeed }) else { return nil }
            return CGRect(x: Double(x0 + left) / Double(width), y: Double(y0 + top) / Double(height),
                          width: Double(right - left + 1) / Double(width), height: Double(bottom - top + 1) / Double(height))
        }
    }

    /// Fraction of sampled frames in which every tile showed a face.
    nonisolated static func tilePresence(faceSets: [[CGRect]], tiles: [PodcastTile]) -> Double {
        guard !faceSets.isEmpty, !tiles.isEmpty else { return 0 }
        let full = faceSets.count { faces in
            tiles.allSatisfy { tile in faces.contains { tile.contains(x: $0.midX, y: $0.midY) } }
        }
        return Double(full) / Double(faceSets.count)
    }

    /// Tiles named by the People pass: the person whose portrait sits in
    /// the cell.
    nonisolated static func named(_ tiles: [PodcastTile], roster: [VideoPersonRecord]) -> [PodcastTile] {
        tiles.map { tile in
            var named = tile
            named.personKey = roster.first { person in
                guard let box = person.portraitBox else { return false }
                return tile.contains(x: box.x + box.w / 2, y: box.y + box.h / 2)
            }?.key
            return named
        }
    }

    nonisolated static func sideMetrics(_ faces: [FaceSample]) -> [PodcastSpeakerSide: Double] {
        var values: [PodcastSpeakerSide: Double] = [:]
        for face in faces {
            let side: PodcastSpeakerSide = face.centerX < 0.5 ? .left : .right
            values[side] = max(values[side] ?? 0, face.aperture)
        }
        return values
    }

    nonisolated static func tileMetrics(_ faces: [FaceSample], tiles: [PodcastTile]) -> [Int: Double] {
        var values: [Int: Double] = [:]
        for face in faces {
            guard let tile = tiles.first(where: { $0.contains(x: face.centerX, y: face.centerY) }) else { continue }
            values[tile.index] = max(values[tile.index] ?? 0, face.aperture)
        }
        return values
    }

    /// Two faces alone also describes an ordinary studio shot. Require a
    /// persistent image discontinuity near the center before pinning halves.
    static func hasCenterSeam(_ jpeg: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let width = 96, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        func edge(_ x: Int) -> Double {
            var total = 0.0
            for y in 4..<(height - 4) {
                for channel in 0..<3 {
                    let offset = (y * width + x) * 4 + channel
                    total += abs(Double(pixels[offset]) - Double(pixels[offset - 4]))
                }
            }
            return total / Double((height - 8) * 3)
        }
        let middle = (46...50).map(edge).max() ?? 0
        let background = ([40, 42, 44, 52, 54, 56].map(edge).reduce(0, +)) / 6
        return middle > 8 && middle > background * 1.8
    }

    /// Every face in the frame with its mouth opening. Vision's boxes have a
    /// bottom-left origin; these are flipped to the top-left frame the rest
    /// of the app uses.
    static func faceSamples(_ jpeg: Data) async -> [FaceSample] {
        guard let permit = try? await MediaWorkScheduler.current.acquire(.vision) else { return [] }
        defer { withExtendedLifetime(permit) {} }
        guard !Task.isCancelled else { return [] }
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        let request = DetectFaceLandmarksRequest(.revision3)
        let timing = PerfSignpost.begin("Vision", metadata: "podcast face landmarks")
        defer { PerfSignpost.end(timing) }
        let observations = (try? await request.perform(on: image)) ?? []
        guard !Task.isCancelled else { return [] }
        return observations.map { face in
            let rect = face.boundingBox.cgRect
            let box = CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
            let points = face.landmarks?.outerLips.points ?? []
            let aperture = points.isEmpty ? 0 : (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
            return FaceSample(box: box, aperture: aperture)
        }
    }
}

actor PodcastExchangeSegmenter {
    private let ai: AIService
    init(ai: AIService) { self.ai = ai }

    struct Outcome: Sendable {
        var exchanges: [PodcastExchange]
        var provenance: AIProvenance?
    }

    func segment(segments: [TranscriptSegment], turns: [SpeakerTurn],
                 provider: String?, model: String?,
                 log: @escaping @Sendable (String) -> Void, useLocal: Bool = false) async throws -> Outcome {
        let sentences = Self.sentenceSegments(segments, turns: turns)
        let candidates = Self.candidateExchanges(segments: sentences, turns: turns)
        var chunks: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var characters = 0
        for candidate in candidates {
            let rows = sentences.filter { $0.end > candidate.start && $0.start < candidate.end }
            let count = rows.reduce(0) { $0 + $1.text.count }
            // Keep each bounded candidate together within the request budget
            // so the model can assess its question and answer in context.
            if !current.isEmpty, characters + count > 12_000 {
                chunks.append(current)
                current = []
                characters = 0
            }
            current += rows
            characters += count
        }
        if !current.isEmpty { chunks.append(current) }
        var result = Outcome(exchanges: [], provenance: nil)
        // Keep serial: AI calls append to the run's shared provenance capture;
        // concurrent completion would reorder it and change failure ordering.
        for chunk in chunks {
            try Task.checkCancellation()
            let outcome = try await segmentChunk(segments: chunk, turns: turns,
                                                 provider: provider, model: model, log: log, useLocal: useLocal)
            result.exchanges += outcome.exchanges
            result.provenance = outcome.provenance ?? result.provenance
        }
        return result
    }

    private func segmentChunk(segments: [TranscriptSegment], turns: [SpeakerTurn],
                              provider: String?, model: String?,
                              log: @escaping @Sendable (String) -> Void, useLocal: Bool = false) async throws -> Outcome {
        let candidates = Self.candidateExchanges(segments: segments, turns: turns)
        guard !candidates.isEmpty else { return Outcome(exchanges: [], provenance: nil) }
        let locked = useLocal ? candidates.map { PodcastExchange(start: $0.start, end: $0.end, title: "", summary: "", score: 0, speakerKeys: $0.speakerKeys) }.filter { PodcastLocalRules.locked($0, segments: segments, turns: turns) } : []
        log(useLocal ? "Podcast boundaries locked where unambiguous — asking the model for scores and remaining boundaries" : "Podcast exchanges — asking the model")
        let lines = segments.enumerated().map { index, sentence in
            "[\(index)] \(sentence.start.timecode)-\(sentence.end.timecode): \(sentence.text)"
        }.joined(separator: "\n")
        let hints = candidates.map { candidate in
            let indices = segments.indices.filter {
                segments[$0].end > candidate.start && segments[$0].start < candidate.end
            }
            return "\(indices.first ?? 0)-\(indices.last ?? 0)\(locked.contains { $0.start == candidate.start && $0.end == candidate.end } ? " LOCKED: score and title only; never move these boundaries" : " open for repair")"
        }.joined(separator: ", ")
        let prompt = """
        You are editing a spoken podcast. The numbered rows below are word-safe sentence
        or speaker-turn units; punctuation may be absent. Proposed exchanges: \(hints).
        Split proposed exchanges at listed sentence indices when a new question begins,
        and merge adjacent exchanges when needed to keep a question with its full answer.
        Return contiguous inclusive sentence-index ranges using first_sentence and last_sentence.
        Cover every sentence exactly once in order, with no overlaps or omissions. Never split a word.
        For each exchange, write a short title, a one-sentence summary, and a reel score
        from 0 to 10 considering the opening hook, self-contained meaning, quotability,
        emotional/surprising content, and a 20-60 second sweet spot.

        \(lines)

        Return only JSON: {"exchanges":[{"first_sentence":0,"last_sentence":1,"title":"...","summary":"...","score":7.5}]}
        """
        do {
            let response = try await ai.call(prompt: prompt, task: "exchanges", model: model,
                                             provider: provider, timeout: 240, log: log)
            guard let object = AIResponseParser.jsonObject(from: response.text),
                  let raw = object["exchanges"] as? [[String: Any]] else {
                throw AIError.unusableResponse("Podcast exchange response was not valid JSON")
            }
            var exchanges = try Self.validatedExchanges(raw, segments: segments, turns: turns)
            exchanges = PodcastLocalRules.preserve(exchanges, locked: locked)
            var provenance = response.provenance
            if useLocal { provenance.technique = "locked-exchanges" }
            return Outcome(exchanges: exchanges, provenance: provenance)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("AI exchange grouping unavailable; keeping deterministic whole exchanges (\(error))")
            return Outcome(exchanges: candidates.enumerated().map { index, item in
                PodcastExchange(start: item.start, end: item.end,
                                title: "Exchange \(index + 1)",
                                summary: "A complete question-and-answer exchange.",
                                score: useLocal ? PodcastLocalRules.score(segments: segments, start: item.start, end: item.end) : Self.heuristicScore(duration: item.end - item.start),
                                speakerKeys: item.speakerKeys)
            }, provenance: useLocal ? .local(technique: "transcript-features") : nil)
        }
    }

    /// The model may split or merge candidates, but must cover the exact ordered
    /// sentence partition. Reject the entire response rather than losing speech.
    static func validatedExchanges(_ raw: [[String: Any]], segments: [TranscriptSegment],
                                   turns: [SpeakerTurn]) throws -> [PodcastExchange] {
        var next = 0
        var exchanges: [PodcastExchange] = []
        for entry in raw {
            guard let firstNumber = entry["first_sentence"] as? NSNumber,
                  let lastNumber = entry["last_sentence"] as? NSNumber,
                  firstNumber.doubleValue == Double(firstNumber.intValue),
                  lastNumber.doubleValue == Double(lastNumber.intValue) else {
                throw AIError.unusableResponse("Podcast exchange indices must be integers")
            }
            let first = firstNumber.intValue, last = lastNumber.intValue
            guard first == next, last >= first, segments.indices.contains(last) else {
                throw AIError.unusableResponse("Podcast exchange response omitted or overlapped sentences")
            }
            let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = (entry["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let score = (entry["score"] as? NSNumber)?.doubleValue ?? 0
            // D5: a validated AI exchange has no maximum duration. The safety
            // bound belongs only to deterministic candidates and fallback output.
            exchanges.append(PodcastExchange(
                start: segments[first].start, end: segments[last].end,
                title: title.isEmpty ? "Podcast exchange" : title,
                summary: summary.isEmpty ? "A complete question-and-answer exchange." : summary,
                score: score.isFinite ? min(10, max(0, score)) : 0,
                speakerKeys: speakerKeys(start: segments[first].start,
                                         end: segments[last].end, turns: turns)))
            next = last + 1
        }
        guard next == segments.count else {
            throw AIError.unusableResponse("Podcast exchange response omitted sentences")
        }
        return exchanges
    }

    private static func speakerKeys(start: Double, end: Double, turns: [SpeakerTurn]) -> [String] {
        Array(Set(turns.filter { $0.end > start && $0.start < end }.compactMap(\.personKey))).sorted()
    }

    /// Person, else tile, else voice cluster — the identity the cleanup
    /// and the re-cut use, so two unnamed tiles on one cluster still count
    /// as a change of speaker.
    private static func speakerChanged(_ first: SpeakerTurn, _ second: SpeakerTurn) -> Bool {
        SpeakerTurnCleanup.identity(first) != SpeakerTurnCleanup.identity(second)
    }

    private static func turnIndex(_ segment: TranscriptSegment, turns: [SpeakerTurn]) -> Int? {
        turns.indices.max { a, b in
            max(0, min(segment.end, turns[a].end) - max(segment.start, turns[a].start))
                < max(0, min(segment.end, turns[b].end) - max(segment.start, turns[b].start))
        }.flatMap { index in
            turns[index].end > segment.start && turns[index].start < segment.end ? index : nil
        }
    }

    private static func questionFlags(_ segments: [TranscriptSegment], turns: [SpeakerTurn]) -> [Bool] {
        let openers = ["why", "how", "what", "when", "where", "who", "did", "do", "does",
                       "is", "are", "can", "could", "would", "should", "tell me", "por que",
                       "como", "o que", "quando", "onde", "quem", "voce"]
        let indices = segments.map { turnIndex($0, turns: turns) }
        var questionTurns = Set<Int>()
        return segments.indices.map { index in
            let segment = segments[index]
            let turn = indices[index]
            let atStart = index == 0 || turn == nil || turn != indices[index - 1]
            let text = segment.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let opener = openers.contains { text == $0 || text.hasPrefix($0 + " ") }
            var shortQuestion = false
            if let turn, turns.indices.contains(turn + 1) {
                let current = turns[turn], next = turns[turn + 1]
                let changed = turn == 0 || speakerChanged(turns[turn - 1], current)
                shortQuestion = changed && current.end - current.start < 15
                    && next.end - next.start > current.end - current.start
                    && speakerChanged(current, next)
            }
            let explicit = segment.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            if explicit || (atStart && (opener || shortQuestion)) {
                if let turn { questionTurns.insert(turn) }
                return true
            }
            return turn.map { questionTurns.contains($0) } ?? false
        }
    }

    static func candidateExchanges(segments: [TranscriptSegment], turns: [SpeakerTurn])
        -> [(start: Double, end: Double, speakerKeys: [String])] {
        let segments = sentenceSegments(segments, turns: turns)
        guard !segments.isEmpty else { return [] }
        let questions = questionFlags(segments, turns: turns)
        var ranges: [ClosedRange<Int>] = []
        var first = 0
        var sawAnswer = false
        for index in segments.indices {
            var pausedChange = false
            if index > 0, segments[index].start - segments[index - 1].end >= 1.5,
               let previous = turnIndex(segments[index - 1], turns: turns),
               let current = turnIndex(segments[index], turns: turns) {
                pausedChange = speakerChanged(turns[previous], turns[current])
            }
            if index > first, sawAnswer, questions[index] || pausedChange {
                ranges += boundedRanges(segments: segments, first: first, last: index - 1, turns: turns)
                first = index
                sawAnswer = false
            }
            if !questions[index] { sawAnswer = true }
        }
        ranges += boundedRanges(segments: segments, first: first, last: segments.count - 1, turns: turns)
        return ranges.map { range in
            let start = segments[range.lowerBound].start, end = segments[range.upperBound].end
            return (start, end, speakerKeys(start: start, end: end, turns: turns))
        }
    }

    /// Prefer the longest pause at a turn boundary, then at a sentence boundary,
    /// within 180 seconds. This is a missing-signal fallback, not a reel length target.
    private static func boundedRanges(segments: [TranscriptSegment], first: Int, last: Int,
                                      turns: [SpeakerTurn]) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        var first = first
        while first < last, segments[last].end - segments[first].start > 180 {
            let eligible = ((first + 1)...last).filter {
                segments[$0 - 1].end - segments[first].start <= 180
            }
            let turnBoundaries = eligible.filter { index in
                guard let a = turnIndex(segments[index - 1], turns: turns),
                      let b = turnIndex(segments[index], turns: turns) else { return false }
                return speakerChanged(turns[a], turns[b])
            }
            let choices = turnBoundaries.isEmpty ? eligible : turnBoundaries
            guard let split = choices.max(by: { a, b in
                let gapA = segments[a].start - segments[a - 1].end
                let gapB = segments[b].start - segments[b - 1].end
                return gapA == gapB ? a < b : gapA < gapB
            }) else { break }
            ranges.append(first...(split - 1))
            first = split
        }
        ranges.append(first...last)
        return ranges
    }

    /// Keep punctuation boundaries, and recover word-safe units at speaker changes,
    /// long pauses, or the safety limit when SpeechTranscriber omits punctuation.
    static func sentenceSegments(_ segments: [TranscriptSegment], turns: [SpeakerTurn] = []) -> [TranscriptSegment] {
        segments.flatMap { segment -> [TranscriptSegment] in
            var words = segment.words ?? []
            if words.isEmpty {
                guard segment.end - segment.start > 180 else { return [segment] }
                // Legacy transcripts have no word times. Approximate timings only
                // for this safety fallback, retaining every complete word.
                let tokens = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !tokens.isEmpty else { return [segment] }
                let step = (segment.end - segment.start) / Double(tokens.count)
                words = tokens.enumerated().map { index, word in
                    TranscriptWord(word: word, start: segment.start + Double(index) * step,
                                   end: segment.start + Double(index + 1) * step)
                }
            }
            var result: [TranscriptSegment] = []
            var first = 0
            for index in words.indices {
                let text = words[index].word.trimmingCharacters(in: .whitespacesAndNewlines)
                let last = index == words.count - 1
                let next = last ? index : index + 1
                let turnBoundary = !last && turns.contains { turn in
                    turn.start > words[index].start && turn.start <= words[next].start
                }
                let pause = !last && words[next].start - words[index].end >= 1.5
                let limit = !last && words[next].end - words[first].start > 180
                guard text.last.map({ ".!?".contains($0) }) == true || last || turnBoundary || pause || limit else { continue }
                let sentence = Array(words[first...index])
                result.append(TranscriptSegment(start: words[first].start, end: words[index].end,
                                                text: sentence.map(\.word).joined(separator: " "), words: sentence))
                first = index + 1
            }
            return result
        }
    }

    private static func heuristicScore(duration: Double) -> Double {
        // Duration alone is not evidence of a good hook or quotable content.
        // Leave fallback scenes unscored rather than auto-favoriting them.
        0
    }
}

nonisolated enum PodcastFramingService {
    static func splitFeedWindows(sourceAspect: Double) -> (left: FreeCropRect, right: FreeCropRect) {
        let aspect = sourceAspect.isFinite && sourceAspect > 0 ? sourceAspect : 16.0 / 9.0
        let height = min(1, max(0.1, 0.5 * aspect / 1.125))
        let y = (1 - height) / 2
        return (FreeCropRect(xFrac: 0, yFrac: y, wFrac: 0.5, hFrac: height),
                FreeCropRect(xFrac: 0.5, yFrac: y, wFrac: 0.5, hFrac: height))
    }

    /// Build a vertical 50/50 frame from the two equal source halves. The
    /// Wizard then burns captions and lower thirds onto this normalized clip
    /// in its usual single encode pass.
    static func splitZoom(source: URL, start: Double, duration: Double,
                          output: URL) async throws {
        let width = RenderContext.settings.width
        let height = RenderContext.settings.height
        let halfHeight = height / 2
        let filter = """
        [0:v]crop=iw/2:ih:0:0,scale=\(width):\(halfHeight):force_original_aspect_ratio=increase,crop=\(width):\(halfHeight),setsar=1[left];\
        [0:v]crop=iw/2:ih:iw/2:0,scale=\(width):\(halfHeight):force_original_aspect_ratio=increase,crop=\(width):\(halfHeight),setsar=1[right];\
        [left][right]vstack=inputs=2[v]
        """
        var arguments = ["-y", "-ss", String(format: "%.3f", start),
                         "-t", String(format: "%.3f", duration), "-i", source.path,
                         "-filter_complex", filter, "-map", "[v]", "-map", "0:a?"]
        arguments += FFmpeg.encodeArgs
        arguments.append(output.path)
        try await FFmpeg.run(arguments, timeout: max(180, duration * 8))
    }
}
