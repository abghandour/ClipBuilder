import Foundation
import CoreGraphics

nonisolated enum WizardPodcastTimeline {
    static func cutDocuments(plan: WizardPlan, sceneMap: [Int64: SceneRecord], options: WizardOptions,
                             database: Database, profile: BrandProfile = BrandProfile(name: "Default"),
                             captionStyle: CaptionStyle = CaptionStyle(),
                             log: @escaping @Sendable (String) -> Void) async throws -> [Int: TimelineDocument] {
        let recipe = ReelRecipe.recipe(id: options.formatPreset) ?? .custom
        guard options.requestedFraming.subject != .original,
              recipe.capabilities.podcastFraming || options.requestedFraming.subject == .layout else { return [:] }
        let videos = try await database.fetchVideos(projectID: options.projectID)
        let ids = Set(plan.clips.compactMap { sceneMap[$0.sceneID] }
            .map(\.videoID))
        var turns: [Int64: [SpeakerTurn]] = [:]
        var rosters: [Int64: [VideoPersonRecord]] = [:]
        for id in ids {
            turns[id] = try await database.fetchSpeakerTurns(videoID: id)
            rosters[id] = try await database.fetchVideoPeople(videoID: id)
        }
        // Interview focus frames from face positions seen in the clip itself.
        let subject = options.requestedFraming.subject == .auto ? plan.framing ?? .speakerFocus : options.requestedFraming.subject
        if subject == .speakerFocus {
            for id in ids.sorted() {
                guard let video = videos.first(where: { $0.id == id }), let roster = rosters[id] else { continue }
                let clips = plan.clips.filter { sceneMap[$0.sceneID]?.videoID == id && $0.end > $0.start }
                guard let start = clips.map(\.start).min(), let end = clips.map(\.end).max() else { continue }
                rosters[id] = await InterviewFaceSampling.refinedRoster(video: video, roster: roster, range: start...end,
                    turns: turns[id] ?? [], punchIn: .talker,
                    cuts: options.requestedFraming.moves == .cuts, log: log)
            }
        }
        let people = options.usesNameTags ? try await database.fetchPeople() : []
        let tagText = options.usesNameTags
            ? try await database.tagText(field: profile.tagStyle(id: options.nameTagStyleID).description.field) : [:]
        let imageAspects = await TextOverlayRenderer.tagImageAspects(profile.tagStyle(id: options.nameTagStyleID))
        let layoutScenes = options.requestedFraming.subject == .layout && options.useBRoll
            ? try await database.fetchScenes(projectID: options.projectID, scope: .active, includeExcluded: false) : []
        return await cutDocuments(plan: plan, sceneMap: sceneMap, options: options,
            videos: videos, turns: turns, rosters: rosters, layouts: ScreenCropStore.all(), brollScenes: layoutScenes, people: people, tagText: tagText,
            captionStyle: captionStyle, profile: profile, imageAspects: imageAspects, log: log)
    }

    @MainActor
    static func cutDocuments(plan: WizardPlan, sceneMap: [Int64: SceneRecord], options: WizardOptions,
                             videos: [VideoRecord], turns: [Int64: [SpeakerTurn]],
                             rosters: [Int64: [VideoPersonRecord]] = [:], layouts: [ScreenCropLayout], brollScenes: [SceneRecord] = [],
                             people: [PersonRecord] = [], tagText: [String: String] = [:], captionStyle: CaptionStyle = CaptionStyle(),
                             profile: BrandProfile = BrandProfile(name: "Default"), imageAspects: [UUID: CGFloat] = [:],
                             log: (String) -> Void = { _ in }) -> [Int: TimelineDocument] {
        let recipe = ReelRecipe.recipe(id: options.formatPreset) ?? .custom
        guard options.requestedFraming.subject != .original,
              recipe.capabilities.podcastFraming || options.requestedFraming.subject == .layout else { return [:] }
        let subject = options.requestedFraming.subject == .auto ? plan.framing ?? .speakerFocus : options.requestedFraming.subject
        var result: [Int: TimelineDocument] = [:]
        for (index, clip) in plan.clips.enumerated() {
            guard let scene = sceneMap[clip.sceneID], clip.end > clip.start else { continue }
            guard let video = videos.first(where: { $0.id == scene.videoID }) else {
                log("Camera focus \(subject.label(type: .podcast)) could not be applied: source video unavailable — following speaker")
                continue
            }
            guard video.type != .fight,
                  subject == .layout || (recipe.capabilities.podcastFraming && scene.tags.contains("podcast")) else { continue }
            let allScenes = brollScenes + Array(sceneMap.values)
            var cuts: [PodcastHighlightBRollPlanner.Cut] = []
            if subject == .layout, options.useBRoll {
                if let stored = clip.brollCuts {
                    cuts = stored.compactMap { cut in
                        guard let scene = allScenes.first(where: { $0.id == cut.sceneID }) else { return nil }
                        let lower = max(clip.start, cut.start), upper = min(clip.end, cut.end)
                        guard upper > lower else { return nil }
                        return .init(source: .scene(scene.id), sourceStart: scene.startTime + cut.sceneOffset + lower - cut.start,
                            start: lower - clip.start, duration: upper - lower, reason: cut.reason)
                    }
                } else {
                    let candidate = HighlightCandidate(sourceStart: clip.start, sourceEnd: clip.end,
                        title: "Layout", reason: "", score: 0, kind: .whole, speakerKeys: [])
                    let sources = PodcastHighlightBRollPlanner.sources(videoID: video.id, range: clip.start...clip.end,
                        turns: turns[video.id] ?? [], roster: rosters[video.id] ?? [], scenes: allScenes, segments: [], people: people)
                    cuts = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources,
                        turns: turns[video.id] ?? [], segments: [], tiles: CropRecipePlanner.tiles(video: video, roster: rosters[video.id] ?? []),
                        scenes: allScenes, threshold: 7, instructions: options.brollInstructions)
                }
            }
            var document = PodcastRecipeTimeline.build(subject: subject, video: video, range: clip.start...clip.end,
                sourceScene: scene, turns: turns[video.id] ?? [], roster: rosters[video.id] ?? [],
                layouts: layouts, settings: options.renderSettings, options: options, sources: videos, brollCuts: cuts, scenes: allScenes, people: people, tagText: tagText,
                captionStyle: captionStyle, profile: profile, imageAspects: imageAspects, log: log)
            // The transient Builder may append a Full Screen tail to its
            // cropping row. A cut owns only its chosen layout and exact span.
            document.cropBlocks = document.cropBlocks.prefix(1).map { block in
                var block = block
                block.startTime = 0
                block.duration = clip.end - clip.start
                return block
            }
            for track in document.videoTrack.indices {
                document.videoTrack[track].captions = options.addCaptions && document.videoTrack[track].track == 0
                    ? (options.captionPositionOverride ?? captionStyle.position) : "none"
            }
            result[index] = document
        }
        return result
    }
}

extension WizardEngine {
    /// Review, Builder pre-fill and proxy scoring use the same cut documents as assembly.
    nonisolated static func timelineDocument(from plan: WizardPlan, sceneMap: [Int64: SceneRecord],
                                             options: WizardOptions, database: Database,
                                             profile: BrandProfile = BrandProfile(name: "Default"),
                                             log: @escaping @Sendable (String) -> Void) async throws -> TimelineDocument {
        let sourceCuts = try await WizardPodcastTimeline.cutDocuments(plan: plan, sceneMap: sceneMap,
            options: options, database: database, profile: profile,
            captionStyle: profile.captionStyle(id: options.captionStyleID), log: log)
        let cuts = sourceCuts.reduce(into: [Int: TimelineDocument]()) { result, entry in
            result[entry.key] = WizardOrdinaryTimeline.retimed(entry.value, speed: plan.clips[entry.key].speed)
        }
        let videos = try await database.fetchVideos(projectID: options.projectID)
        let videoTypes = Dictionary(uniqueKeysWithValues: videos.compactMap { video in video.type.map { (video.id, $0) } })
        var document = timelineDocument(from: WizardNameTags.renderPlan(plan, options: options),
            sceneMap: sceneMap, renderSettings: options.renderSettings,
            pacing: options.pacing, framing: options.requestedFraming, podcastCuts: cuts, videoTypes: videoTypes)
        let people = options.usesNameTags ? try await database.fetchPeople() : []
        let tagText = options.usesNameTags
            ? try await database.tagText(field: profile.tagStyle(id: options.nameTagStyleID).description.field) : [:]
        let imageAspects = await TextOverlayRenderer.tagImageAspects(profile.tagStyle(id: options.nameTagStyleID))
        var cursor = 0.0
        for (index, clip) in plan.clips.enumerated() {
            guard let scene = sceneMap[clip.sceneID] else { continue }
            let duration = (clip.end - clip.start) / clip.speed
            if cuts[index] == nil {
                for var item in WizardNameTags.ordinary(scene: scene, duration: duration, people: people, tagText: tagText,
                                                       options: options, captionStyle: profile.captionStyle(id: options.captionStyleID),
                                                       profile: profile, imageAspects: imageAspects) {
                    item.startTime += cursor
                    item.endTime += cursor
                    document.textOverlays.append(item)
                }
            }
            cursor += duration
        }
        for index in document.videoTrack.indices {
            document.videoTrack[index].captions = options.addCaptions && document.videoTrack[index].track == 0
                ? (options.captionPositionOverride ?? profile.captionStyle(id: options.captionStyleID).position) : "none"
        }
        return document
    }
}
