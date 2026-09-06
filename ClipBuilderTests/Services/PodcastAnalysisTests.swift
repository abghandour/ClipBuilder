import Foundation
import Testing
@testable import Clip_Builder

@Suite("Podcast analysis")
struct PodcastAnalysisTests {
    @Test("language selection prefers a confident primary locale")
    func languageSelection() {
        let chosen = TranscriptionService.choosePodcastLanguage(
            primary: [.init(identifier: "en-US", confidence: 0.62),
                      .init(identifier: "pt-BR", confidence: 0.41)],
            installed: [.init(identifier: "es-ES", confidence: 0.91)])
        #expect(chosen?.identifier == "en-US")

        let fallback = TranscriptionService.choosePodcastLanguage(
            primary: [.init(identifier: "en-US", confidence: 0.2),
                      .init(identifier: "pt-BR", confidence: 0.3)],
            installed: [.init(identifier: "es-ES", confidence: 0.8)])
        #expect(fallback?.identifier == "es-ES")
    }

    @Test("speaker turns retain transcript word-safe boundaries")
    func turnBoundaries() {
        let segments = [
            TranscriptSegment(start: 0, end: 1.2, text: "Question?",
                              words: [.init(word: "Question?", start: 0, end: 1.2)]),
            TranscriptSegment(start: 1.4, end: 2.8, text: "Answer.",
                              words: [.init(word: "Answer.", start: 1.4, end: 2.8)]),
            TranscriptSegment(start: 3, end: 4, text: "More.",
                              words: [.init(word: "More.", start: 3, end: 4)]),
        ]
        let turns = PodcastSpeakerSeparator.turns(
            segments: segments,
            embeddings: [[1, 0], [0, 1], [1, 0]], videoID: 9)
        let boundaries = Set(segments.flatMap { [$0.start, $0.end] })
        #expect(turns.allSatisfy { boundaries.contains($0.start) && boundaries.contains($0.end) })
    }

    @Test("exchange grouping keeps each question with its answer")
    func exchangeGrouping() {
        let segments = [
            TranscriptSegment(start: 0, end: 2, text: "Why did you start?", words: nil),
            TranscriptSegment(start: 2, end: 8, text: "I wanted to help people.", words: nil),
            TranscriptSegment(start: 8, end: 10, text: "What changed?", words: nil),
            TranscriptSegment(start: 10, end: 16, text: "Everything changed after that.", words: nil),
        ]
        let candidates = PodcastExchangeSegmenter.candidateExchanges(segments: segments, turns: [])
        #expect(candidates.count == 2)
        #expect(candidates[0].start == 0)
        #expect(candidates[0].end == 8)
        #expect(candidates[1].start == 8)
        #expect(candidates[1].end == 16)
    }

    @Test("exchange speaker tags are derived from the final time range")
    func exchangeSpeakerKeys() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "Why?", words: nil),
            TranscriptSegment(start: 1, end: 2, text: "And specifically?", words: nil),
            TranscriptSegment(start: 2, end: 5, text: "Because it mattered.", words: nil),
        ]
        let turns = [
            SpeakerTurn(videoID: 1, start: 0, end: 2, cluster: 0,
                        confidence: 1, personKey: "host"),
            SpeakerTurn(videoID: 1, start: 2, end: 5, cluster: 1,
                        confidence: 1, personKey: "guest"),
        ]
        let candidates = PodcastExchangeSegmenter.candidateExchanges(
            segments: segments, turns: turns)
        #expect(candidates.count == 1)
        #expect(candidates.first?.end == 5)
        #expect(candidates.flatMap(\.speakerKeys).contains("host"))
        #expect(candidates.flatMap(\.speakerKeys).contains("guest"))
    }

    @Test("highlight threshold controls automatic favorites")
    func favorites() {
        #expect(PodcastAnalysisService.shouldFavorite(score: 7, threshold: 7))
        #expect(!PodcastAnalysisService.shouldFavorite(score: 6.99, threshold: 7))
    }

    @Test("picture talker wins when audio mapping disagrees")
    func pictureTieBreak() {
        let audio = [SpeakerTurn(videoID: 1, start: 0, end: 3, cluster: 0,
                                 confidence: 0.9, resolvedSide: .left)]
        let picture = [PictureTalkerSignal(start: 0, end: 3, side: .right, confidence: 0.9)]
        let resolved = PodcastSpeakerTimelineResolver.resolve(
            audioTurns: audio, picture: picture, layout: .splitHorizontal,
            roster: [], minimumHold: 1.5)
        #expect(resolved.first?.resolvedSide == .right)
        #expect(resolved.first?.pictureSide == .right)
    }

    @Test("camera hold never changes the attributed speaker")
    func cameraHold() {
        let turns = [
            SpeakerTurn(videoID: 1, start: 0, end: 0.5, cluster: 0, confidence: 1),
            SpeakerTurn(videoID: 1, start: 0.5, end: 3, cluster: 1, confidence: 1),
            SpeakerTurn(videoID: 1, start: 3, end: 5, cluster: 1, confidence: 1),
        ]
        let picture = turns.enumerated().map { index, turn in
            PictureTalkerSignal(start: turn.start, end: turn.end,
                                side: index == 0 ? .right : .left, confidence: 1)
        }
        let resolved = PodcastSpeakerTimelineResolver.resolve(
            audioTurns: turns, picture: picture, layout: .splitHorizontal,
            roster: [], minimumHold: 1.5)
        #expect(resolved[0].resolvedSide == .right)
        #expect(resolved[1].resolvedSide == .left)
        let path = PodcastSpeakerTimelineResolver.cameraPath(
            for: 0...5, turns: resolved, layout: .splitHorizontal,
            videoSize: CGSize(width: 1920, height: 1080), minimumHold: 1.5)
        #expect(path.keyframes.first!.x > 0.5)
        #expect(path.keyframes.filter { $0.t < 1.5 }.allSatisfy { $0.x > 0.5 })
        #expect(path.keyframes.last!.x < 0.5)
    }

    @Test("multi-sentence speech results split only at timestamped word ends")
    func sentenceBoundaries() {
        let words = [TranscriptWord(word: "Why?", start: 0, end: 1),
                     TranscriptWord(word: "Because.", start: 1.2, end: 3),
                     TranscriptWord(word: "When?", start: 3.2, end: 4),
                     TranscriptWord(word: "Tomorrow.", start: 4.2, end: 6)]
        let segments = [TranscriptSegment(start: 0, end: 6,
                                          text: "Why? Because. When? Tomorrow.", words: words)]
        let ranges = PodcastExchangeSegmenter.candidateExchanges(segments: segments, turns: [])
        #expect(ranges.count == 2)
        #expect(ranges[0].end == 3)
        #expect(ranges[1].start == 3.2)
    }

    @Test("identity sampling stays sparse for a thirty-minute recording")
    func sparseIdentitySampling() {
        let turns = (0..<600).map { index in
            SpeakerTurn(videoID: 1, start: Double(index * 3), end: Double(index * 3 + 3),
                        cluster: index % 2, confidence: 1)
        }
        #expect(PodcastAnalysisService.identitySampleTimes(turns: turns, duration: 1800).count <= 6)
    }

    @Test("voice windows can separate speakers within one speech result")
    func voiceWindows() {
        let words = (0..<6).map { TranscriptWord(word: "word", start: Double($0), end: Double($0 + 1)) }
        let windows = PodcastSpeakerSeparator.voiceWindows([
            TranscriptSegment(start: 0, end: 6, text: "words", words: words),
        ])
        #expect(windows.count == 6)
        #expect(windows.last?.end == 6)
    }

    @Test("profile portraits and merged speaker identities survive People review")
    func profilePortraitsAndMerge() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo(sceneCount: 0)
        try await temp.database.upsertPerson(key: "guest", descriptor: "Guest")
        try await temp.database.upsertPerson(key: "known", descriptor: "Known guest")
        let people = try await temp.database.fetchPeople()
        let guest = try #require(people.first { $0.key == "guest" })
        let known = try #require(people.first { $0.key == "known" })
        try await temp.database.replaceVideoPeople(videoID: videoID, entries: [
            (guest.id, 1, "{\"x\":0.1,\"y\":0.2,\"w\":0.3,\"h\":0.4}", nil),
        ])
        let references = try await temp.database.podcastPortraitReferences()
        #expect(references.first?.key == "guest")
        #expect(references.first?.time == 1)
        try await temp.database.replaceSpeakerTurns(videoID: videoID, turns: [
            SpeakerTurn(videoID: videoID, start: 0, end: 3, cluster: 0,
                        confidence: 1, personKey: guest.key),
        ])
        try await temp.database.mergePeople(source: guest, into: known)
        #expect(try await temp.database.fetchSpeakerTurns(videoID: videoID).first?.personKey == known.key)
        try await temp.database.deletePerson(known)
        #expect(try await temp.database.fetchSpeakerTurns(videoID: videoID).first?.personKey == nil)
    }

    @Test("speaker turns persist with resolved identity and picture evidence")
    func speakerTurnPersistence() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo(sceneCount: 0)
        let turn = SpeakerTurn(videoID: videoID, start: 1, end: 4, cluster: 1,
                               confidence: 0.75, pictureSide: .right,
                               pictureConfidence: 0.88, resolvedSide: .right,
                               personKey: "guest")
        try await temp.database.replaceSpeakerTurns(videoID: videoID, turns: [turn])
        let fetched = try await temp.database.fetchSpeakerTurns(videoID: videoID)
        #expect(fetched.count == 1)
        #expect(fetched[0].personKey == "guest")
        #expect(fetched[0].pictureConfidence == 0.88)
    }

    @Test("podcast Wizard keeps a short exchange whole and sentence-trims an overlong one")
    func wizardBoundaries() async throws {
        let engine = WizardEngine(ai: AIService(config: AppSettings().ai), render: RenderEngine())
        var short = Fixtures.scene(start: 2, end: 12)
        short.tags = ["podcast", "reel-highlight"]
        var options = WizardOptions()
        options.formatPreset = "podcast"
        options.targetDurationSeconds = 20
        let raw: [String: Any] = ["target_duration": 20,
                                  "clips": [["scene_id": 1, "start": 4, "end": 9]]]
        let whole = try #require(await engine.validatePlan(
            raw, scenes: [1: short], musicNames: [], options: options))
        #expect(whole.clips[0].start == 2)
        #expect(whole.clips[0].end == 12)

        var long = short
        long.endTime = 62
        let trimmed = try #require(await engine.validatePlan(
            raw, scenes: [1: long], musicNames: [], options: options,
            podcastSentenceEnds: [1: [7, 12, 18, 25]]))
        #expect(trimmed.clips[0].start == 2)
        #expect(trimmed.clips[0].end == 7)

        let untrimmedAI: [String: Any] = ["target_duration": 20,
                                          "clips": [["scene_id": 1, "start": 2, "end": 62]]]
        let capped = try #require(await engine.validatePlan(
            untrimmedAI, scenes: [1: long], musicNames: [], options: options,
            podcastSentenceEnds: [1: [7, 12, 18, 25]]))
        #expect(capped.clips[0].end == 18)
        #expect(capped.clips[0].end - capped.clips[0].start <= 20)
    }

    @Test("split Zoom timeline creates pinned synchronized tracks")
    func splitTimeline() {
        var scene = Fixtures.scene(start: 0, end: 10)
        scene.tags = ["podcast", "podcast:split", "reel-highlight"]
        let document = WizardEngine.timelineDocument(
            from: Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 10)], targetDuration: 10),
            sceneMap: [scene.id: scene], podcastFraming: .splitZoom)
        #expect(document.videoTrack.count == 2)
        #expect(document.videoTrack.map(\.track) == [0, 1])
        #expect(document.videoTrack[0].areaWindow?.xFrac == 0)
        #expect(document.videoTrack[1].areaWindow?.xFrac == 0.5)
        #expect(document.videoTrack[1].muted)
        #expect(document.cropBlocks.first?.layout.name == "50-50 Horizontal")
    }
    @Test("unpunctuated alternating turns produce complete question-answer exchanges")
    func unpunctuatedTurns() {
        let rows = [
            TranscriptSegment(start: 0, end: 3, text: "your next challenge", words: nil),
            TranscriptSegment(start: 3, end: 25, text: "I started working on a new project", words: nil),
            TranscriptSegment(start: 25, end: 29, text: "your biggest surprise", words: nil),
            TranscriptSegment(start: 29, end: 55, text: "The response changed everything", words: nil),
        ]
        let turns = rows.enumerated().map { index, row in
            SpeakerTurn(videoID: 1, start: row.start, end: row.end, cluster: index % 2,
                        confidence: 0.9, personKey: index % 2 == 0 ? "host" : "guest")
        }
        let ranges = PodcastExchangeSegmenter.candidateExchanges(segments: rows, turns: turns)
        #expect(ranges.count == 2)
        #expect(ranges.map(\.start) == [0, 25])
        #expect(ranges.map(\.end) == [25, 55])
        let words = rows.map { TranscriptWord(word: $0.text, start: $0.start, end: $0.end) }
        let combined = [TranscriptSegment(start: 0, end: 55, text: rows.map(\.text).joined(separator: " "), words: words)]
        #expect(PodcastExchangeSegmenter.candidateExchanges(segments: combined, turns: turns).count == 2)
    }

    @Test("interrogative openers work in English and Portuguese without question marks")
    func questionOpeners() {
        for opener in ["why", "how", "what", "when", "where", "who", "did", "do", "does", "is", "are",
                       "can", "could", "would", "should", "tell me", "por que", "como", "o que",
                       "quando", "onde", "quem", "você"] {
            let rows = [
                TranscriptSegment(start: 0, end: 20, text: "\(opener) this happened", words: nil),
                TranscriptSegment(start: 20, end: 40, text: "My answer", words: nil),
                TranscriptSegment(start: 40, end: 60, text: "\(opener) it changed", words: nil),
                TranscriptSegment(start: 60, end: 80, text: "My next answer", words: nil),
            ]
            let turns = rows.enumerated().map { index, row in
                SpeakerTurn(videoID: 1, start: row.start, end: row.end, cluster: index % 2, confidence: 1)
            }
            #expect(PodcastExchangeSegmenter.candidateExchanges(segments: rows, turns: turns).count == 2)
        }
    }

    @Test("long pauses split only with speaker changes and preserve the first answer")
    func pauseBoundaries() {
        let rows = [TranscriptSegment(start: 0, end: 20, text: "A story", words: nil),
                    TranscriptSegment(start: 21.5, end: 41.5, text: "Another story", words: nil)]
        var turns = [SpeakerTurn(videoID: 1, start: 0, end: 20, cluster: 0, confidence: 1),
                     SpeakerTurn(videoID: 1, start: 21.5, end: 41.5, cluster: 1, confidence: 1)]
        #expect(PodcastExchangeSegmenter.candidateExchanges(segments: rows, turns: turns).count == 2)
        turns[1].cluster = 0
        #expect(PodcastExchangeSegmenter.candidateExchanges(segments: rows, turns: turns).count == 1)
    }

    @Test("monologue fallback is bounded while AI-confirmed exchanges retain their full length")
    func monologueSafetyNet() throws {
        let words = (0..<1800).map { TranscriptWord(word: "word\($0)", start: Double($0), end: Double($0 + 1)) }
        let row = TranscriptSegment(start: 0, end: 1800, text: words.map(\.word).joined(separator: " "), words: words)
        for transcript in [[row], [TranscriptSegment(start: 0, end: 1800, text: row.text, words: nil)]] {
            let sentences = PodcastExchangeSegmenter.sentenceSegments(transcript)
            #expect(sentences.map(\.text).joined(separator: " ") == row.text)
            let ranges = PodcastExchangeSegmenter.candidateExchanges(segments: transcript, turns: [])
            #expect(ranges.count >= 10)
            #expect(ranges.allSatisfy { $0.end - $0.start <= 180 })
            #expect(ranges.first?.start == 0)
            #expect(ranges.last?.end == 1800)
            let merged = try PodcastExchangeSegmenter.validatedExchanges(
                [["first_sentence": 0, "last_sentence": sentences.count - 1]], segments: sentences, turns: [])
            #expect(merged.count == 1)
            #expect(merged.first?.start == 0)
            #expect(merged.first?.end == 1800)
        }
    }

    @Test("AI can split and merge sentence ranges but cannot omit or overlap speech")
    func aiSentencePartition() throws {
        let rows = (0..<4).map { TranscriptSegment(start: Double($0 * 10), end: Double(($0 + 1) * 10), text: "speech", words: nil) }
        #expect(PodcastExchangeSegmenter.candidateExchanges(segments: rows, turns: []).count == 1)
        let split = try PodcastExchangeSegmenter.validatedExchanges(
            [["first_sentence": 0, "last_sentence": 1], ["first_sentence": 2, "last_sentence": 3]], segments: rows, turns: [])
        #expect(split.map(\.start) == [0, 20])
        #expect(split.map(\.end) == [20, 40])
        let merged = try PodcastExchangeSegmenter.validatedExchanges(
            [["first_sentence": 0, "last_sentence": 3]], segments: rows, turns: [])
        #expect(merged.count == 1)
        let invalidResponses: [[[String: Any]]] = [
            [["first_sentence": 0, "last_sentence": 2]],
            [["first_sentence": 0, "last_sentence": 2], ["first_sentence": 2, "last_sentence": 3]],
            [["first_sentence": 0, "last_sentence": 4]],
            [["first_sentence": 0.5, "last_sentence": 3]],
            [],
        ]
        for invalid in invalidResponses {
            #expect(throws: (any Error).self) {
                try PodcastExchangeSegmenter.validatedExchanges(invalid, segments: rows, turns: [])
            }
        }
    }

    @Test("two exchanges persist exactly two scenes with whole-exchange role tags")
    func exchangeSceneRanges() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo(sceneCount: 0)
        let segments = [
            TranscriptSegment(start: 0, end: 3, text: "Why this", words: nil),
            TranscriptSegment(start: 3, end: 20, text: "My explanation", words: nil),
            TranscriptSegment(start: 20, end: 23, text: "What changed", words: nil),
            TranscriptSegment(start: 23, end: 40, text: "Everything changed", words: nil),
        ]
        let turns = segments.enumerated().map { index, segment in
            SpeakerTurn(videoID: videoID, start: segment.start, end: segment.end,
                        cluster: index % 2, confidence: 1,
                        personKey: index % 2 == 0 ? "host" : "guest")
        }
        let candidates = PodcastExchangeSegmenter.candidateExchanges(segments: segments, turns: turns)
        #expect(candidates.count == 2)
        let exchanges = candidates.enumerated().map { index, candidate in
            PodcastExchange(start: candidate.start, end: candidate.end, title: "Exchange", summary: "",
                            score: index == 0 ? 8 : 0, speakerKeys: candidate.speakerKeys)
        }
        let tags = PodcastAnalysisService.exchangeTagRanges(exchanges, layout: .splitHorizontal, highlightThreshold: 7)
        let runID = try await temp.database.saveAnalysis(
            videoID: videoID, runName: "Podcast", instructions: "", sampleInterval: nil, notesJSON: nil,
            tagRanges: tags, moments: [], analyzedTags: ["podcast"], provider: nil, model: nil, mode: "speech")
        let ranges = try await temp.database.sceneRanges(runID: runID).sorted { $0.start < $1.start }
        #expect(ranges.count == 2)
        #expect(ranges.map(\.start) == [0, 20])
        #expect(ranges.map(\.end) == [20, 40])
        let scenes = try await temp.database.fetchScenes().filter { $0.runID == runID }
        let required = Set(["podcast", "question", "answer", "person:host", "person:guest", "podcast:split"])
        #expect(scenes.allSatisfy { required.isSubset(of: Set($0.tags)) })
        #expect(scenes.filter { $0.tags.contains("reel-highlight") }.map(\.startTime) == [0])
    }

    @Test("Wizard trims unpunctuated exchanges at recovered turn and pause boundaries")
    func wizardUnpunctuatedTrim() async throws {
        let words = (0..<60).map { index in
            let start = Double(index < 20 ? index : index + 2)
            return TranscriptWord(word: "word\(index)", start: start, end: start + 1)
        }
        let segments = [TranscriptSegment(start: 0, end: 62,
                                          text: words.map(\.word).joined(separator: " "), words: words)]
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 10, cluster: 0, confidence: 1),
                     SpeakerTurn(videoID: 1, start: 10, end: 62, cluster: 1, confidence: 1)]
        var scene = Fixtures.scene(start: 0, end: 62)
        scene.tags = ["podcast"]
        // This is the same helper used when loading PlanningInputs.
        let ends = WizardEngine.podcastTrimPoints(segments: segments, turns: turns, scene: scene)
        #expect(ends == [10, 20])
        let engine = WizardEngine(ai: AIService(config: AppSettings().ai), render: RenderEngine())
        let raw: [String: Any] = ["clips": [["scene_id": scene.id, "start": 0, "end": 62]]]
        for (target, expectedEnd) in [(15, 10.0), (25, 20.0)] {
            var options = WizardOptions()
            options.formatPreset = "podcast"
            options.targetDurationSeconds = target
            let plan = try #require(await engine.validatePlan(
                raw, scenes: [scene.id: scene], musicNames: [], options: options,
                podcastSentenceEnds: [scene.id: ends]))
            #expect(plan.clips.first?.start == 0)
            #expect(plan.clips.first?.end == expectedEnd)
        }
    }

    @Test("Wizard falls back to podcast scenes only when highlights are absent")
    func wizardHighlightFallback() {
        var podcast = Fixtures.scene(id: 1)
        podcast.tags = ["podcast"]
        var highlight = Fixtures.scene(id: 2)
        highlight.tags = ["podcast", "reel-highlight"]
        let unrelated = Fixtures.scene(id: 3)
        var messages: [String] = []
        let fallback = WizardEngine.podcastScenes([podcast, unrelated], log: { messages.append($0) })
        #expect(fallback.map(\.id) == [1])
        #expect(messages.contains { $0.contains("falling back to all podcast scenes") })
        messages = []
        let preferred = WizardEngine.podcastScenes([podcast, highlight, unrelated], log: { messages.append($0) })
        #expect(preferred.map(\.id) == [2])
        #expect(messages.isEmpty)
        #expect(WizardEngine.podcastScenes([unrelated], log: { _ in }).isEmpty)
    }

    @Test("podcast cache bypasses detection and the shared manual/batch route preserves language")
    func podcastCacheAndManualRouting() async throws {
        let temp = try TempDatabase()
        let id = try await temp.seedVideo(sceneCount: 0)
        var video = try #require(try await temp.database.fetchVideos().first)
        video.videoType = "podcast"
        // Deliberately not media: a cache hit must never try FFmpeg or Speech.
        try Data("cached podcast fixture".utf8).write(to: video.url)
        let directory = try TempDirectory()
        let service = TranscriptionService(cacheDirectory: directory.url)
        let hash = String(try ContentHash.fingerprint(of: video.url).prefix(32))
        let cached = TranscriptionService.CachedTranscript(
            provider: "apple", model: "SpeechTranscriber", language: "pt", detectedLanguage: "pt-BR",
            translate: false, segments: [TranscriptSegment(start: 0, end: 4, text: "Uma conversa", words: nil)])
        let cacheURL = directory.url.appendingPathComponent("\(hash).apple.SpeechTranscriber.pt.json")
        try JSONEncoder().encode(cached).write(to: cacheURL)
        // A corrupt earlier entry cannot hide a valid cache in another language.
        try Data("invalid".utf8).write(to: directory.url.appendingPathComponent("\(hash).apple.SpeechTranscriber.en.json"))
        let result = try await service.transcribeForVideo(video: video, database: temp.database, log: { _ in })
        #expect(result.map(\.text) == ["Uma conversa"])
        let persisted = try await temp.database.fetchTranscripts(videoID: id)
        #expect(persisted.first?.language == "pt-BR")
        #expect(try await service.cachedPodcast(video: video, force: true) == nil)
        try FileManager.default.removeItem(at: cacheURL)
        #expect(try await service.cachedPodcast(video: video, force: false) == nil)
    }

    @Test("ambiguous picture cannot override confident audio but clear or stronger picture can")
    func pictureConfidenceThreshold() {
        let cases: [(Double, Double, PodcastSpeakerSide)] = [
            (0.55, 0.9, .left), (0.69, 0.9, .left), (0.7, 0.9, .right), (0.6, 0.5, .right),
        ]
        for (pictureConfidence, audioConfidence, expected) in cases {
            let audio = [SpeakerTurn(videoID: 1, start: 0, end: 5, cluster: 0,
                                     confidence: audioConfidence, resolvedSide: .left)]
            let picture = [PictureTalkerSignal(start: 0, end: 5, side: .right, confidence: pictureConfidence)]
            let result = PodcastSpeakerTimelineResolver.resolve(audioTurns: audio, picture: picture,
                                                                 layout: .splitHorizontal, roster: [], minimumHold: 1.5)
            #expect(result.first?.resolvedSide == expected)
        }
    }

    @Test("source dimensions flow through database into aspect-aware Wizard windows")
    func splitFeedSourceDimensions() async throws {
        let temp = try TempDatabase()
        _ = try await temp.seedVideo()
        let stored = try #require(try await temp.database.fetchScenes().first)
        #expect(stored.videoWidth == 1920)
        #expect(stored.videoHeight == 1080)
        for (width, height) in [(1920, 1080), (1440, 1080), (2560, 1080)] {
            var scene = Fixtures.scene(start: 0, end: 10)
            scene.tags = ["podcast", "podcast:split"]
            scene.videoWidth = width
            scene.videoHeight = height
            let document = WizardEngine.timelineDocument(
                from: Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 10)]),
                sceneMap: [scene.id: scene], podcastFraming: .splitZoom)
            let expectedHeight = min(1, 0.5 * Double(width) / Double(height) / 1.125)
            let left = try #require(document.videoTrack.first?.areaWindow)
            #expect(abs(left.hFrac - expectedHeight) < 0.00001)
            #expect(abs(left.yFrac - (1 - expectedHeight) / 2) < 0.00001)
            #expect(document.videoTrack[1].areaWindow?.hFrac == left.hFrac)
        }
    }

    @MainActor
    @Test("Builder and Wizard use identical split-feed source windows")
    func builderSplitFeedWindows() throws {
        let model = BuilderTimelineModel()
        defer { model.cancelPendingAutosave() }
        for aspect in [16.0 / 9.0, 4.0 / 3.0, 21.0 / 9.0] {
            let clip = Fixtures.timelineClip()
            model.loadDocument(Fixtures.timelineDocument(clips: [clip]))
            model.splitZoomFeeds(clip.uid, leftName: "Host", rightName: "Guest", sourceAspect: aspect)
            let windows = PodcastFramingService.splitFeedWindows(sourceAspect: aspect)
            #expect(model.document.videoTrack.count == 2)
            #expect(model.document.videoTrack[0].areaWindow == windows.left)
            #expect(model.document.videoTrack[1].areaWindow == windows.right)
            #expect(model.document.videoTrack[1].muted)
        }
    }

    @Test("split-feed windows follow source aspect and remain inside their source halves")
    func splitFeedWindowGeometry() {
        for aspect in [16.0 / 9.0, 4.0 / 3.0, 21.0 / 9.0] {
            let windows = PodcastFramingService.splitFeedWindows(sourceAspect: aspect)
            let height = min(1, 0.5 * aspect / 1.125)
            #expect(abs(windows.left.hFrac - height) < 0.00001)
            #expect(abs(windows.left.yFrac - (1 - height) / 2) < 0.00001)
            #expect(windows.left.xFrac == 0)
            #expect(windows.right.xFrac == 0.5)
            #expect(windows.left.wFrac == 0.5)
            #expect(windows.right.wFrac == 0.5)
            #expect(windows.left.hFrac == windows.right.hFrac)
        }
    }

}
