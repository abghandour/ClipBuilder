import Foundation

@MainActor
enum PodcastHighlightTimeline {
    static func build(candidate: HighlightCandidate, video: VideoRecord, scenes: [SceneRecord],
                      turns: [SpeakerTurn], roster: [VideoPersonRecord], segments: [TranscriptSegment],
                      layouts: [ScreenCropLayout], settings: RenderSettings, threshold: Double = 7, options: WizardOptions = WizardOptions(),
                      plannedCuts: [PodcastHighlightBRollPlanner.Cut]? = nil, people: [PersonRecord] = [],
                      log: @Sendable (String) -> Void) -> TimelineDocument {
        let builder = BuilderTimelineModel(mode: .transient)
        let sourceScene = scenes.filter { $0.videoID == video.id && $0.startTime <= candidate.sourceStart && $0.endTime >= candidate.sourceEnd }
            .min { $0.duration < $1.duration }
        builder.document = PodcastRecipeTimeline.build(kind: candidate.framing, video: video,
            range: candidate.sourceStart...candidate.sourceEnd, sourceScene: sourceScene,
            turns: turns, roster: roster, layouts: layouts, settings: settings, options: options, people: people)
        let tiles = CropRecipePlanner.tiles(video: video, roster: roster)
        guard options.useBRoll else { log("B-roll off"); return builder.document }
        let sources = PodcastHighlightBRollPlanner.sources(videoID: video.id, range: candidate.sourceRange,
            speakerKeys: candidate.speakerKeys, turns: turns, roster: roster, scenes: scenes, segments: segments, people: people)
        let cuts = plannedCuts ?? PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
            segments: segments, tiles: tiles, scenes: scenes, threshold: threshold, instructions: options.brollInstructions)
        add(cuts: cuts, to: builder, video: video, tiles: tiles, scenes: scenes, log: log)
        if cuts.isEmpty { log("B-roll: no suitable sources.") }
        return builder.document
    }

    static func add(cuts: [PodcastHighlightBRollPlanner.Cut], to builder: BuilderTimelineModel,
                    video: VideoRecord, tiles: [PodcastTile], scenes: [SceneRecord], offset: Double = 0,
                    log: @Sendable (String) -> Void) {
        for cut in cuts {
            let source: CutawaySource
            var window: FreeCropRect?
            switch cut.source {
            case .reaction(let index):
                guard let tile = tiles.first(where: { $0.index == index }), video.width > 0, video.height > 0 else { continue }
                source = .file(url: video.url, duration: video.duration)
                window = CropRecipePlanner.crop(tile: tile, aspect: builder.document.renderSettings.aspectRatio,
                                               sourceAspect: Double(video.width) / Double(video.height))
            case .scene(let id):
                guard let scene = scenes.first(where: { $0.id == id }) else { continue }
                source = .scene(scene)
            }
            if case .added(let uid, _) = builder.addCutaway(source: source, at: offset + cut.start, duration: cut.duration,
                                                            sourceStart: cut.sourceStart, coverAll: true),
               let index = builder.document.videoTrack.firstIndex(where: { $0.uid == uid }) {
                // addCutaway snaps ordinary edits; retain the planner's exact bounds.
                builder.document.videoTrack[index].startTime = offset + cut.start
                builder.document.videoTrack[index].precision = .speech
                builder.document.videoTrack[index].cutawaySourceWindow = window
                log("B-roll: \(cut.start.timecode)–\((cut.start + cut.duration).timecode) · \(cut.reason)")
            }
        }
    }
}
