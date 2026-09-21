import Foundation

nonisolated enum PodcastHighlightBRollPlacement {
    static func plan(candidate: HighlightCandidate, video: VideoRecord, scenes: [SceneRecord],
                     turns: [SpeakerTurn], roster: [VideoPersonRecord], segments: [TranscriptSegment],
                     options: WizardOptions, threshold: Double = 7, ai: AIService? = nil, people: [PersonRecord] = [],
                     log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [PodcastHighlightBRollPlanner.Cut] {
        guard options.useBRoll else { log("B-roll off"); return [] }
        let tiles = CropRecipePlanner.tiles(video: video, roster: roster)
        let instructions = options.brollInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only this recording's other moments and footage of its people, or of
        // whoever it names, are ever offered: nothing out of context on screen.
        let sources = PodcastHighlightBRollPlanner.sources(videoID: video.id, range: candidate.sourceRange,
            speakerKeys: candidate.speakerKeys, turns: turns, roster: roster, scenes: scenes, segments: segments, people: people)
        if !instructions.isEmpty, let ai {
            let sentences = PodcastExchangeSegmenter.sentenceSegments(segments, turns: turns)
                .filter { $0.start >= candidate.sourceStart && $0.end <= candidate.sourceEnd }
                .sorted { $0.start < $1.start }
            var names = Dictionary(roster.map { ($0.key, $0.displayName) }, uniquingKeysWith: { first, _ in first })
            names.merge(PodcastHighlightBRollPlanner.personNames(people)) { current, _ in current }
            let offered = PodcastHighlightBRollPlanner.offeredScenes(sources: sources, scenes: scenes, instructions: instructions)
            log("B-roll · \(candidate.title): " + PodcastHighlightBRollPlanner.describe(sources, offered: offered, names: names))
            do {
                let placements = try await request(sentences: sentences, turns: turns, names: names, scenes: offered, sources: sources,
                    reactionKeys: Set(tiles.compactMap(\.personKey)), range: candidate.sourceStart...candidate.sourceEnd,
                    options: options, ai: ai, log: log)
                let cuts = PodcastHighlightBRollPlanner.validated(placements: placements, candidate: candidate,
                    sentences: sentences, sources: sources, turns: turns, tiles: tiles, scenes: offered, instructions: instructions)
                if !cuts.isEmpty {
                    log("B-roll · \(candidate.title): using \(cuts.count) AI placement(s).")
                    return cuts
                }
                log("B-roll · \(candidate.title): AI returned no usable placements; using deterministic planner.")
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                log("B-roll · \(candidate.title): AI placement failed (\(error)); using deterministic planner.")
            }
        } else if !instructions.isEmpty {
            log("B-roll · \(candidate.title): no provider; using deterministic planner.")
        }
        return PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
            segments: segments, tiles: tiles, scenes: scenes, threshold: threshold, instructions: instructions)
    }

    /// Shared by highlights and single reels; one model call sees the entire reel.
    /// `scenes` is the already in-context pool; each line says why it qualifies.
    static func request(sentences: [TranscriptSegment], turns: [SpeakerTurn], names: [String: String],
                        scenes: [SceneRecord], sources: PodcastHighlightBRollPlanner.Sources,
                        reactionKeys: Set<String>, range: ClosedRange<Double>,
                        options: WizardOptions, ai: AIService,
                        log: @escaping @Sendable (String) -> Void) async throws -> [PodcastHighlightBRollPlanner.Placement] {
        let sceneLines = scenes.map {
            "scene:\($0.id) | \($0.videoFilename) | \($0.startTime)–\($0.endTime)s | \(sources.label(for: $0, names: names))"
                + " | tags: \($0.tags.joined(separator: ", ")) | \($0.narrative ?? "") | score: \($0.score ?? 0)"
        }
        let reactions = options.brollInstructions.lowercased().contains("no reaction") ? [] : reactionKeys.sorted().map {
            "reaction:\($0) | \(names[$0] ?? $0), only while this person is not speaking"
        }
        let prompt = """
        Place B-roll over this podcast/interview reel. Preserve the underlying speech.
        User's B-roll instructions: \(options.brollInstructions)
        Reel time range: \(range.lowerBound)–\(range.upperBound)s.
        Rules: never cover the first 2 seconds of the reel; at most 3 seconds per cutaway;
        at most 40% of the reel covered; no overlaps and leave 2 seconds between cutaways.
        Use inclusive numbered sentence indices. A long sentence range will be clamped to 3 seconds.
        Choose only offered source IDs. Reactions must show a listener, never the current speaker.
        Every offered scene is in context: another moment of this recording, or footage showing one of
        the reel's people or someone they name; its label says which. Cut to footage that illustrates
        what is being said at that moment, preferring the person being discussed. When nothing offered
        fits a moment, leave that moment uncovered rather than showing unrelated footage.
        Return only JSON: {"placements":[{"first_sentence":1,"last_sentence":1,"source":"scene:123","reason":"Illustrates the guest's fight"}]}.
        An empty placements array is valid.

        Sentences:
        \(PodcastHighlightFinder.lines(sentences, turns: turns, names: names))

        Available B-roll:
        \((sceneLines + reactions).joined(separator: "\n"))
        """
        let response = try await ai.call(prompt: prompt, task: "broll", model: options.modelOverride, log: log).text
        let object = AIResponseParser.jsonObject(from: response)
        guard let raw = object?["placements"] as? [Any] else {
            throw AIError.unusableResponse("Expected a B-roll placements array.")
        }
        return raw.compactMap { value in
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                  let placement = try? JSONDecoder().decode(PodcastHighlightBRollPlanner.Placement.self, from: data) else {
                log("B-roll: rejected malformed placement.")
                return nil
            }
            return placement
        }
    }
}
