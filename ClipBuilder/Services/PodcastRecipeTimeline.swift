import Foundation
import CoreGraphics

@MainActor
enum PodcastRecipeTimeline {
    /// Shared speech-precise composition for highlights and individual Wizard cuts.
    static func build(kind: CropRecipe.Kind, video: VideoRecord, range: ClosedRange<Double>,
                      sourceScene: SceneRecord?, turns: [SpeakerTurn], roster: [VideoPersonRecord],
                      layouts: [ScreenCropLayout], settings: RenderSettings,
                      options: WizardOptions = WizardOptions(), people: [PersonRecord] = [], tagText: [String: String],
                      captionStyle: CaptionStyle = CaptionStyle(), profile: BrandProfile = BrandProfile(name: "Default"),
                      imageAspects: [UUID: CGFloat] = [:],
                      log: (String) -> Void = { _ in }) -> TimelineDocument {
        let builder = BuilderTimelineModel(mode: .transient)
        builder.document.renderSettings = settings
        let duration = range.upperBound - range.lowerBound
        let tiles = CropRecipePlanner.tiles(video: video, roster: roster)
        var plan: CropRecipePlanner.Plan?
        do {
            guard !tiles.isEmpty else { throw CropRecipePlanner.Failure(description: "no feed tiles") }
            guard !turns.isEmpty else { throw CropRecipePlanner.Failure(description: "no speaker turns") }
            plan = try CropRecipePlanner.plan(CropRecipe(kind: kind), video: video, range: range,
                turns: turns, roster: roster, layouts: layouts, canvasAspect: settings.aspectRatio)
        } catch {
            log("Camera focus \(kind.name) could not be applied: \(error) — following speaker")
        }
        if let plan {
            // compose uses the source's duration. The selected source window is
            // installed exactly afterwards, preserving speech timing precision.
            var slice = video
            slice.duration = duration
            builder.document.trackCount = max(1, plan.slots.count)
            builder.compose(plan, source: .video(slice), highlightTalker: false)
        } else if let sourceScene {
            builder.addScene(sourceScene)
        } else {
            builder.addVideo(video)
        }
        for index in builder.document.videoTrack.indices {
            builder.document.videoTrack[index].sourceStart = range.lowerBound
            builder.document.videoTrack[index].sourceEnd = range.upperBound
            builder.document.videoTrack[index].startTime = 0
            builder.document.videoTrack[index].duration = duration
            builder.document.videoTrack[index].precision = .speech
            builder.document.videoTrack[index].captions = "none"
            if plan != nil { builder.document.videoTrack[index].wide = video.width > video.height }
            builder.document.videoTrack[index].transIn = nil
            builder.document.videoTrack[index].transOut = nil
            if plan == nil { builder.document.videoTrack[index].centerStage = sourceScene?.centerStagePath != nil }
        }
        for index in builder.document.cropBlocks.indices { builder.document.cropBlocks[index].duration = duration }
        if let plan, options.usesNameTags {
            let areas = NameTagPlanner.areas(plan: plan, tiles: tiles, roster: roster, layouts: layouts,
                canvas: CGSize(width: settings.width, height: settings.height), duration: duration,
                sourceAspect: Double(video.width) / Double(max(1, video.height)))
            builder.document.textOverlays += WizardNameTags.overlays(areas: areas, people: people, tagText: tagText,
                options: options, captionStyle: captionStyle, profile: profile, imageAspects: imageAspects)
        } else if let sourceScene, options.usesNameTags {
            builder.document.textOverlays += WizardNameTags.ordinary(scene: sourceScene, duration: duration,
                people: people, tagText: tagText, options: options, captionStyle: captionStyle, profile: profile, imageAspects: imageAspects)
        }
        return builder.document
    }
}
