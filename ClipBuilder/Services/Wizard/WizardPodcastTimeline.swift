import Foundation
import CoreGraphics

nonisolated enum WizardPodcastTimeline {
    static func cutDocuments(plan: WizardPlan, sceneMap: [Int64: SceneRecord], options: WizardOptions,
                             database: Database, profile: BrandProfile = BrandProfile(name: "Default"),
                             captionStyle: CaptionStyle = CaptionStyle(),
                             log: @escaping @Sendable (String) -> Void) async throws -> [Int: TimelineDocument] {
        let recipe = ReelRecipe.recipe(id: options.formatPreset) ?? .custom
        guard recipe.capabilities.podcastFraming, options.podcastFraming != .original,
              plan.clips.contains(where: { sceneMap[$0.sceneID]?.tags.contains("podcast") == true }) else { return [:] }
        let videos = try await database.fetchVideos(projectID: options.projectID)
        let ids = Set(plan.clips.compactMap { sceneMap[$0.sceneID] }
            .filter { $0.tags.contains("podcast") }.map(\.videoID))
        var turns: [Int64: [SpeakerTurn]] = [:]
        var rosters: [Int64: [VideoPersonRecord]] = [:]
        for id in ids {
            turns[id] = try await database.fetchSpeakerTurns(videoID: id)
            rosters[id] = try await database.fetchVideoPeople(videoID: id)
        }
        let people = options.usesNameTags ? try await database.fetchPeople() : []
        let tagText = options.usesNameTags
            ? try await database.tagText(field: profile.tagStyle(id: options.nameTagStyleID).description.field) : [:]
        let imageAspects = await TextOverlayRenderer.tagImageAspects(profile.tagStyle(id: options.nameTagStyleID))
        return await cutDocuments(plan: plan, sceneMap: sceneMap, options: options,
            videos: videos, turns: turns, rosters: rosters, layouts: ScreenCropStore.all(), people: people, tagText: tagText,
            captionStyle: captionStyle, profile: profile, imageAspects: imageAspects, log: log)
    }

    @MainActor
    static func cutDocuments(plan: WizardPlan, sceneMap: [Int64: SceneRecord], options: WizardOptions,
                             videos: [VideoRecord], turns: [Int64: [SpeakerTurn]],
                             rosters: [Int64: [VideoPersonRecord]] = [:], layouts: [ScreenCropLayout],
                             people: [PersonRecord] = [], tagText: [String: String] = [:], captionStyle: CaptionStyle = CaptionStyle(),
                             profile: BrandProfile = BrandProfile(name: "Default"), imageAspects: [UUID: CGFloat] = [:],
                             log: (String) -> Void = { _ in }) -> [Int: TimelineDocument] {
        let recipe = ReelRecipe.recipe(id: options.formatPreset) ?? .custom
        guard recipe.capabilities.podcastFraming, options.podcastFraming != .original else { return [:] }
        let kind = options.highlightFraming ?? (options.podcastFraming == .splitZoom ? .grid : plan.framing ?? .talker)
        var result: [Int: TimelineDocument] = [:]
        for (index, clip) in plan.clips.enumerated() {
            guard let scene = sceneMap[clip.sceneID], scene.tags.contains("podcast"), clip.end > clip.start else { continue }
            guard let video = videos.first(where: { $0.id == scene.videoID }) else {
                log("Camera focus \(kind.name) could not be applied: source video unavailable — following speaker")
                continue
            }
            var document = PodcastRecipeTimeline.build(kind: kind, video: video, range: clip.start...clip.end,
                sourceScene: scene, turns: turns[video.id] ?? [], roster: rosters[video.id] ?? [],
                layouts: layouts, settings: options.renderSettings, options: options, people: people, tagText: tagText,
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
        let cuts = try await WizardPodcastTimeline.cutDocuments(plan: plan, sceneMap: sceneMap,
            options: options, database: database, profile: profile,
            captionStyle: profile.captionStyle(id: options.captionStyleID), log: log)
        var document = timelineDocument(from: WizardNameTags.renderPlan(plan, options: options),
            sceneMap: sceneMap, renderSettings: options.renderSettings,
            pacing: options.pacing, podcastFraming: options.podcastFraming, podcastCuts: cuts)
        let people = options.usesNameTags ? try await database.fetchPeople() : []
        let tagText = options.usesNameTags
            ? try await database.tagText(field: profile.tagStyle(id: options.nameTagStyleID).description.field) : [:]
        let imageAspects = await TextOverlayRenderer.tagImageAspects(profile.tagStyle(id: options.nameTagStyleID))
        var cursor = 0.0
        for (index, clip) in plan.clips.enumerated() {
            guard let scene = sceneMap[clip.sceneID] else { continue }
            let duration = cuts[index] != nil ? clip.end - clip.start
                : ((clip.end - clip.start) / clip.speed * 10).rounded() / 10
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
