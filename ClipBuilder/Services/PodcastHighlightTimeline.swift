import Foundation
import CoreGraphics

@MainActor
enum PodcastHighlightTimeline {
    static func build(candidate: HighlightCandidate, video: VideoRecord, scenes: [SceneRecord],
                      turns: [SpeakerTurn], roster: [VideoPersonRecord], segments: [TranscriptSegment],
                      layouts: [ScreenCropLayout], settings: RenderSettings, threshold: Double = 7, options: WizardOptions = WizardOptions(),
                      plannedCuts: [PodcastHighlightBRollPlanner.Cut]? = nil, people: [PersonRecord] = [], tagText: [String: String],
                      profile: BrandProfile = BrandProfile(name: "Default"), imageAspects: [UUID: CGFloat] = [:],
                      log: @Sendable (String) -> Void) -> TimelineDocument {
        let builder = BuilderTimelineModel(mode: .transient)
        let sourceScene = scenes.filter { $0.videoID == video.id && $0.startTime <= candidate.sourceStart && $0.endTime >= candidate.sourceEnd }
            .min { $0.duration < $1.duration }
        let tiles = CropRecipePlanner.tiles(video: video, roster: roster)
        let sources = PodcastHighlightBRollPlanner.sources(videoID: video.id, range: candidate.sourceRange,
            speakerKeys: candidate.speakerKeys, turns: turns, roster: roster, scenes: scenes, segments: segments, people: people)
        let cuts = options.useBRoll ? plannedCuts ?? PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
            segments: segments, tiles: tiles, scenes: scenes, threshold: threshold, instructions: options.brollInstructions) : []
        builder.document = PodcastRecipeTimeline.build(subject: Framing.Subject.legacy(candidate.framing), video: video,
            range: candidate.sourceStart...candidate.sourceEnd, sourceScene: sourceScene,
            turns: turns, roster: roster, layouts: layouts, settings: settings, options: options, hasBRoll: !cuts.isEmpty,
            brollCuts: cuts, scenes: scenes, people: people, tagText: tagText,
            captionStyle: profile.renderCaptionStyle(id: options.captionStyleID), profile: profile, imageAspects: imageAspects)
        if builder.document.videoTrack.contains(where: { $0.framingPlan?.isComposed == true }) { return builder.document }
        guard options.useBRoll else { log("B-roll off"); return builder.document }
        add(cuts: cuts, to: builder, video: video, tiles: tiles, scenes: scenes, roster: roster, log: log)
        if cuts.isEmpty { log("B-roll: no suitable sources.") }
        return builder.document
    }

    static func add(cuts: [PodcastHighlightBRollPlanner.Cut], to builder: BuilderTimelineModel,
                    video: VideoRecord, tiles: [PodcastTile], scenes: [SceneRecord], offset: Double = 0,
                    roster: [VideoPersonRecord] = [], log: @Sendable (String) -> Void) {
        for cut in cuts {
            let source: CutawaySource
            var window: FreeCropRect?
            switch cut.source {
            case .reaction(let index):
                guard let tile = tiles.first(where: { $0.index == index }), video.width > 0, video.height > 0 else { continue }
                source = .file(url: video.url, duration: video.duration)
                // A reaction window is centred on the face like a feed cell
                // (the layout pass's face, else the roster portrait), not on
                // the tile: a tile-centred window slices a face that sits
                // near the tile's edge.
                let face = CropRecipePlanner.faceFocus(of: tile, roster: roster)
                window = CropRecipePlanner.crop(tile: tile, aspect: builder.document.renderSettings.aspectRatio,
                                               sourceAspect: Double(video.width) / Double(video.height),
                                               center: face.center, face: face.faceBox)
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
