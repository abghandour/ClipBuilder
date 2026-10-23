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
            guard kind == .vip || !tiles.isEmpty else { throw CropRecipePlanner.Failure(description: "no feed tiles") }
            guard kind == .vip || !turns.isEmpty else { throw CropRecipePlanner.Failure(description: "no speaker turns") }
            var recipe = CropRecipe(kind: kind)
            recipe.interviewZoom = options.interviewZoom ?? 0
            recipe.interviewZoomMoves = options.interviewZoomMoves ?? false
            recipe.interviewCuts = options.interviewCuts ?? false
            recipe.interviewPunchIn = InterviewPunchIn(rawValue: options.interviewPunchIn ?? "") ?? .vip
            plan = try CropRecipePlanner.plan(recipe, video: video, range: range,
                turns: turns, roster: roster, layouts: layouts, canvasAspect: settings.aspectRatio)
        } catch {
            log("Camera focus \(kind.name) could not be applied: \(error) — following speaker")
        }
        if let plan {
            for note in plan.notes { log(note) }
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
            // Framed file clips retain their scene identity for the later B-roll source lookup.
            if let sourceScene { builder.document.videoTrack[index].sceneID = sourceScene.id }
            if plan?.slots.first?.trackingSpans != nil {
                builder.document.videoTrack[index].sourceStart = (builder.document.videoTrack[index].sourceStart ?? 0) + range.lowerBound
                builder.document.videoTrack[index].sourceEnd = (builder.document.videoTrack[index].sourceEnd ?? duration) + range.lowerBound
            } else {
                builder.document.videoTrack[index].sourceStart = range.lowerBound
                builder.document.videoTrack[index].sourceEnd = range.upperBound
                builder.document.videoTrack[index].startTime = 0
                builder.document.videoTrack[index].duration = duration
            }
            builder.document.videoTrack[index].precision = .speech
            builder.document.videoTrack[index].captions = "none"
            if plan != nil { builder.document.videoTrack[index].wide = video.width > video.height }
            builder.document.videoTrack[index].transIn = nil
            builder.document.videoTrack[index].transOut = nil
            if plan == nil { builder.document.videoTrack[index].centerStage = sourceScene?.centerStagePath != nil }
        }
        for index in builder.document.cropBlocks.indices { builder.document.cropBlocks[index].duration = duration }
        if let plan, options.usesNameTags {
            let areas = NameTagPlanner.areas(plan: plan, tiles: plan.tiles.isEmpty ? tiles : plan.tiles, roster: roster, layouts: layouts,
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
