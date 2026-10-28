import Foundation
import CoreGraphics

@MainActor
enum PodcastRecipeTimeline {
    /// Shared speech-precise composition for highlights and individual Wizard cuts.
    static func build(subject: Framing.Subject? = nil, video: VideoRecord, range: ClosedRange<Double>,
                      sourceScene: SceneRecord?, turns: [SpeakerTurn], roster: [VideoPersonRecord],
                      layouts: [ScreenCropLayout], settings: RenderSettings,
                      options: WizardOptions = WizardOptions(), hasBRoll: Bool = false, sources: [VideoRecord] = [],
                      brollCuts: [PodcastHighlightBRollPlanner.Cut] = [], scenes: [SceneRecord] = [], people: [PersonRecord] = [], tagText: [String: String],
                      captionStyle: CaptionStyle = CaptionStyle(), profile: BrandProfile = BrandProfile(name: "Default"),
                      imageAspects: [UUID: CGFloat] = [:],
                      log: (String) -> Void = { _ in }) -> TimelineDocument {
        let builder = BuilderTimelineModel(mode: .transient)
        builder.document.renderSettings = settings
        let duration = range.upperBound - range.lowerBound
        let tiles = CropRecipePlanner.tiles(video: video, roster: roster)
        var context = FramingContext(video: video, range: range, canvasAspect: settings.aspectRatio,
            roster: roster, turns: turns, storedPath: sourceScene?.centerStagePath,
            layouts: layouts, hasBRoll: hasBRoll, chosenSubject: subject)
        context.sources = sources
        context.brollCuts = brollCuts
        context.scenes = scenes
        var resolved = FramingPlanner.resolve(framing: options.requestedFraming, context: context)
        if let warning = FramingPlanner.warning(framing: options.requestedFraming, context: context) { log(warning) }
        var plan: CropRecipePlanner.Plan?
        do {
            plan = try FramingPlanner.composition(plan: resolved, context: context)
        } catch {
            log("Framing could not be applied: \(error) — using Center stage")
            var fallback = options.requestedFraming
            fallback.subject = .centerStage
            resolved = FramingPlanner.resolve(framing: fallback, context: context)
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
            if let sourceScene, builder.document.videoTrack[index].videoFile == video.url.path || plan?.areas == nil {
                builder.document.videoTrack[index].sceneID = sourceScene.id
            }
            if plan?.areas != nil {
                // Per-area source and composition clocks are already installed.
            } else if plan?.slots.contains(where: { $0.trackingSpans != nil }) == true {
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
            if plan != nil, plan?.areas == nil { builder.document.videoTrack[index].wide = video.width > video.height }
            builder.document.videoTrack[index].transIn = nil
            builder.document.videoTrack[index].transOut = nil
            builder.document.videoTrack[index].framingPlan = resolved
            FocusFrame.apply(resolved, to: &builder.document.videoTrack[index], replanned: plan != nil)
            if plan == nil {
                builder.document.videoTrack[index].centerStage = resolved.recipe?.centerStage == true
                if resolved.isStatic {
                    builder.document.videoTrack[index].wide = false
                    builder.document.videoTrack[index].cropXFrac = nil
                    builder.document.videoTrack[index].cameraPath = nil
                }
            }
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
