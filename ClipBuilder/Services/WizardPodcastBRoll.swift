import Foundation

/// One placement request sees all the reel's numbered sentences. Validation
/// maps them back to source spans before adding editable, muted cutaways.
enum WizardPodcastBRoll {
    nonisolated struct Cache: Sendable {
        fileprivate var plans: [Key: Planned] = [:]
    }

    nonisolated fileprivate struct Key: Hashable, Sendable {
        struct SourceSpan: Hashable, Sendable {
            var sceneID: Int64?
            var file: String?
            var start: Double?
            var end: Double?
            var time: Double
            var duration: Double
            var speed: Double?
        }
        var spans: [SourceSpan]
        var instructions: String
        var projectID: Int64?
    }

    nonisolated fileprivate struct Planned: Sendable {
        var spans: [Span]
        var cuts: [[PodcastHighlightBRollPlanner.Cut]]
        var scenes: [SceneRecord]
    }

    nonisolated fileprivate struct Span: Sendable {
        var clip: TimelineClip
        var video: VideoRecord
        var candidate: HighlightCandidate
        var sentences: [TranscriptSegment]
        var turns: [SpeakerTurn]
        var roster: [VideoPersonRecord]
        var tiles: [PodcastTile]
        var sources: PodcastHighlightBRollPlanner.Sources
    }

    static func adding(to document: TimelineDocument, options: WizardOptions, database: Database,
                       ai: AIService, log: @escaping @Sendable (String) -> Void) async throws -> TimelineDocument {
        var cache = Cache()
        return try await adding(to: document, options: options, database: database, ai: ai, cache: &cache, log: log)
    }

    static func adding(to document: TimelineDocument, options: WizardOptions, database: Database,
                       ai: AIService, cache: inout Cache,
                       log: @escaping @Sendable (String) -> Void) async throws -> TimelineDocument {
        guard (ReelRecipe.recipe(id: options.formatPreset) ?? .custom).capabilities.bRoll else { return document }
        guard options.useBRoll else { log("B-roll off"); return document }
        guard !options.brollInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return document }
        // Generated brand cards have new paths in every version and cannot
        // supply B-roll sentences; they must not invalidate the source cache.
        let main = document.videoTrack.filter { $0.track == 0 && !$0.isCutaway && !$0.bumper && $0.sceneID != nil }
            .sorted { $0.startTime < $1.startTime }
        let key = Key(spans: main.map {
            Key.SourceSpan(sceneID: $0.sceneID, file: $0.videoFile, start: $0.sourceStart, end: $0.sourceEnd,
                           time: $0.startTime, duration: $0.duration, speed: $0.speed)
        }, instructions: options.brollInstructions, projectID: options.projectID)
        let planned: Planned
        if let cached = cache.plans[key] {
            planned = cached
            log("B-roll: reusing placements for unchanged source spans and instructions.")
        } else {
            planned = try await plan(main: main, options: options, database: database, ai: ai, log: log)
            cache.plans[key] = planned
        }
        let builder = BuilderTimelineModel(mode: .transient)
        builder.document = document
        for (index, span) in planned.spans.enumerated() {
            try Task.checkCancellation()
            PodcastHighlightTimeline.add(cuts: planned.cuts[index], to: builder, video: span.video,
                tiles: span.tiles, scenes: planned.scenes, offset: span.clip.startTime, log: log)
        }
        return builder.document
    }

    private static func plan(main: [TimelineClip], options: WizardOptions, database: Database,
                             ai: AIService, log: @escaping @Sendable (String) -> Void) async throws -> Planned {
        let videos = try await database.fetchVideos(projectID: options.projectID)
        let scenes = try await database.fetchScenes(projectID: options.projectID, includeExcluded: false)
        let sceneMap = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        let sourceIDs = Set(main.compactMap { $0.sceneID.flatMap { sceneMap[$0]?.videoID } })
        // Transcript segmentation, speaker data and tile detection are properties
        // of a recording, shared by every selected span from that recording.
        var contexts: [Int64: (video: VideoRecord, sentences: [TranscriptSegment], turns: [SpeakerTurn],
                               roster: [VideoPersonRecord], tiles: [PodcastTile])] = [:]
        for video in videos where sourceIDs.contains(video.id) {
            try Task.checkCancellation()
            let rows = try await database.fetchTranscripts(videoID: video.id)
            let segments = rows.filter { !$0.isTranslation }.map {
                TranscriptSegment(start: $0.startTime, end: $0.endTime, text: $0.text,
                    words: $0.wordsJSON?.data(using: .utf8).flatMap { try? JSONDecoder().decode([TranscriptWord].self, from: $0) })
            }
            let turns = try await database.fetchSpeakerTurns(videoID: video.id)
            let roster = try await database.fetchVideoPeople(videoID: video.id)
            contexts[video.id] = (video, PodcastExchangeSegmenter.sentenceSegments(segments, turns: turns),
                                 turns, roster, CropRecipePlanner.tiles(video: video, roster: roster))
            log("B-roll: loaded source context for video \(video.id).")
        }
        let people = try await database.fetchPeople()
        var spans: [Span] = []
        for clip in main {
            try Task.checkCancellation()
            guard let sceneID = clip.sceneID, let scene = sceneMap[sceneID],
                  let context = contexts[scene.videoID],
                  context.video.type == .podcast || context.video.type == .interview || scene.tags.contains("podcast"),
                  let start = clip.sourceStart, let end = clip.sourceEnd, end > start,
                  (clip.speed ?? 1) == 1 else { continue }
            let video = context.video
            let turns = context.turns
            let candidate = HighlightCandidate(sourceStart: start, sourceEnd: end, title: video.filename,
                reason: scene.narrative ?? "", score: scene.score ?? 0, kind: .whole,
                speakerKeys: Array(Set(turns.filter { $0.end > start && $0.start < end }.compactMap(\.personKey))))
            let sentences = context.sentences
                .filter { $0.start >= start && $0.end <= end }.sorted { $0.start < $1.start }
            let sources = PodcastHighlightBRollPlanner.sources(videoID: video.id, range: start...end,
                speakerKeys: candidate.speakerKeys, turns: turns, roster: context.roster, scenes: scenes,
                segments: context.sentences, people: people)
            spans.append(Span(clip: clip, video: video, candidate: candidate, sentences: sentences,
                turns: turns, roster: context.roster, tiles: context.tiles, sources: sources))
        }
        guard !spans.isEmpty else { return Planned(spans: [], cuts: [], scenes: scenes) }
        // One pool for the whole reel: other moments of its recordings, and
        // footage of its people or of whoever it names. Nothing else is offered.
        let sources = PodcastHighlightBRollPlanner.Sources(merging: spans.map(\.sources))
        var planned = [[PodcastHighlightBRollPlanner.Cut]](repeating: [], count: spans.count)
        var sentences: [TranscriptSegment] = []
        var turns: [SpeakerTurn] = []
        var offsets: [Int] = []
        for span in spans {
            offsets.append(sentences.count)
            let shift = span.clip.startTime - span.candidate.sourceStart
            sentences += span.sentences.map {
                TranscriptSegment(start: $0.start + shift, end: $0.end + shift, text: $0.text, words: nil)
            }
            turns += span.turns.filter { $0.end > span.candidate.sourceStart && $0.start < span.candidate.sourceEnd }.map {
                var turn = $0
                turn.start = max(turn.start, span.candidate.sourceStart) + shift
                turn.end = min(turn.end, span.candidate.sourceEnd) + shift
                return turn
            }
        }
        var names = Dictionary(spans.flatMap(\.roster).map { ($0.key, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        names.merge(PodcastHighlightBRollPlanner.personNames(people)) { current, _ in current }
        let offered = PodcastHighlightBRollPlanner.offeredScenes(sources: sources, scenes: scenes, instructions: options.brollInstructions)
        log("B-roll: " + PodcastHighlightBRollPlanner.describe(sources, offered: offered, names: names))
        let duration = main.map { $0.startTime + $0.duration }.max() ?? 0
        do {
            let placements = try await PodcastHighlightBRollPlacement.request(sentences: sentences, turns: turns,
                names: names, scenes: offered, sources: sources, reactionKeys: Set(spans.flatMap(\.tiles).compactMap(\.personKey)),
                range: 0...duration, options: options, ai: ai, log: log)
            for (index, span) in spans.enumerated() {
                let offset = offsets[index]
                let local = placements.compactMap { placement -> PodcastHighlightBRollPlanner.Placement? in
                    guard placement.firstSentence >= offset,
                          placement.lastSentence < offset + span.sentences.count else { return nil }
                    var placement = placement
                    placement.firstSentence -= offset
                    placement.lastSentence -= offset
                    return placement
                }
                // Conservatively apply the hook and budget limits to each
                // constituent source span as well as the whole reel.
                planned[index] = PodcastHighlightBRollPlanner.validated(placements: local, candidate: span.candidate,
                    sentences: span.sentences, sources: sources, turns: span.turns, tiles: span.tiles,
                    scenes: offered, instructions: options.brollInstructions)
            }
            log(planned.allSatisfy(\.isEmpty)
                ? "B-roll: AI returned no usable placements; using deterministic planner."
                : "B-roll: using AI placements for the reel.")
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            log("B-roll: AI placement failed (\(error)); using deterministic planner.")
        }
        let useModel = planned.contains { !$0.isEmpty }
        for (index, span) in spans.enumerated() {
            try Task.checkCancellation()
            planned[index] = useModel ? planned[index] : PodcastHighlightBRollPlanner.plan(candidate: span.candidate,
                sources: sources, turns: span.turns, segments: span.sentences, tiles: span.tiles,
                scenes: scenes, threshold: 7, instructions: options.brollInstructions)
        }
        planned = spacedCuts(planned, offsets: spans.map { $0.clip.startTime })
        return Planned(spans: spans, cuts: planned, scenes: scenes)
    }

    /// Enforce spacing on the reel clock, including joins between recordings.
    nonisolated static func spacedCuts(_ cuts: [[PodcastHighlightBRollPlanner.Cut]], offsets: [Double])
        -> [[PodcastHighlightBRollPlanner.Cut]] {
        var result = cuts.map { _ in [PodcastHighlightBRollPlanner.Cut]() }
        let ordered = cuts.enumerated().flatMap { index, span in
            span.map { (index: index, cut: $0, time: offsets[index] + $0.start) }
        }.sorted { $0.time < $1.time }
        var lastEnd = -Double.infinity
        for item in ordered where item.time >= lastEnd + 2 {
            result[item.index].append(item.cut)
            lastEnd = item.time + item.cut.duration
        }
        return result
    }
}
