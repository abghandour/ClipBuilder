import Foundation

/// Ordinary cuts use the same source-clock document as Builder. Decorations are
/// burned by the shared extraction compositor; transitions and bumpers belong to
/// the assembled reel. No intermediate framing movie is produced here.
nonisolated enum WizardOrdinaryTimeline {
    static func cutDocument(clip: WizardPlanClip, sceneMap: [Int64: SceneRecord],
                            settings: RenderSettings, pacing: EditPacing = EditPacing(),
                            framingPlan: FramingPlan?) -> TimelineDocument {
        var document = TimelineDocument()
        document.renderSettings = settings
        document.pacing = pacing
        guard let scene = sceneMap[clip.sceneID], clip.end > clip.start, clip.speed > 0 else { return document }
        let duration = (clip.end - clip.start) / clip.speed
        var main = TimelineClip()
        main.sceneID = scene.id
        main.videoFile = scene.videoPath
        main.sourceStart = clip.start
        main.sourceEnd = clip.end
        main.duration = duration
        main.speed = clip.speed == 1 ? nil : clip.speed
        main.precision = .speech
        main.captions = "none"
        main.sceneFullDuration = scene.duration
        main.screenCrop = clip.screenCrop
        apply(framingPlan, scene: scene, to: &main)
        document.videoTrack = [main]
        if let name = clip.layout, !(framingPlan?.isStatic == true && framingPlan?.sourceWindow != nil) {
            for (slot, area) in clip.areaClips.enumerated() where slot + 1 < TimelineDocument.maxTracks {
                guard let source = sceneMap[area.sceneID] else { continue }
                var extra = main
                extra.uid = UUID()
                extra.sceneID = source.id
                extra.videoFile = source.videoPath
                extra.sourceStart = area.start
                let end = min(area.end, area.start + clip.end - clip.start)
                extra.sourceEnd = end
                extra.duration = max(0, (end - area.start) / clip.speed)
                extra.track = slot + 1
                extra.muted = true
                extra.screenCrop = ScreenCropStore.reference(layout: name, area: area.area)
                apply(framingPlan, scene: source, to: &extra)
                document.videoTrack.append(extra)
                document.trackCount = max(document.trackCount, extra.track + 1)
                document.trackSequential[extra.track] = false
            }
        }
        return document
    }

    /// Recipe/role builders and reviewed B-roll use source seconds. Retime
    /// their completed cut once, leaving all source and transcript offsets intact.
    static func retimed(_ source: TimelineDocument, speed: Double) -> TimelineDocument {
        guard speed > 0, speed != 1 else { return source }
        var document = source.expandingOverlayBlocks()
        for index in document.videoTrack.indices {
            let rate = document.videoTrack[index].effectiveSpeed * speed
            document.videoTrack[index].speed = rate == 1 ? nil : rate
            document.videoTrack[index].startTime /= speed
            document.videoTrack[index].duration /= speed
        }
        for index in document.textOverlays.indices {
            document.textOverlays[index].startTime /= speed
            document.textOverlays[index].endTime /= speed
        }
        for index in document.imageOverlays.indices {
            document.imageOverlays[index].startTime /= speed
            document.imageOverlays[index].endTime /= speed
        }
        for index in document.cropBlocks.indices {
            document.cropBlocks[index].startTime /= speed
            document.cropBlocks[index].duration /= speed
        }
        return document
    }

    /// Shared by the saved editable document and extraction. Saved scene paths
    /// are sliced onto the cut's source clock, never onto its retimed output clock.
    static func apply(_ plan: FramingPlan?, scene: SceneRecord, to clip: inout TimelineClip) {
        clip.framingPlan = plan
        clip.wide = scene.wide
        clip.cropXFrac = scene.cropXFrac
        clip.centerStage = false
        clip.cameraPath = nil
        clip.areaRegion = nil
        if let plan {
            if plan.isStatic {
                clip.wide = false
                clip.cropXFrac = nil
            } else if plan.recipe?.centerStage == true {
                clip.centerStage = true
                // Area framing fuses saved paths into the segment graph and
                // plans missing paths with the same bounded tracking service.
                clip.areaRegion = plan.sourceWindow ?? FreeCropRect()
                if plan.sourceWindow == nil, let stored = scene.centerStagePath {
                    let path = CenterStageService.slice(stored.keyframes,
                        from: (clip.sourceStart ?? scene.startTime) - scene.startTime,
                        duration: clip.duration * clip.effectiveSpeed)
                    if path.count >= 2 { clip.cameraPath = path }
                }
            }
            FocusFrame.apply(plan, to: &clip)
        } else if scene.wide {
            // Legacy cuts keep the analyzed crop (centre when absent), followed
            // by the existing crop + scale + pad placement graph.
            clip.cropXFrac = scene.cropXFrac ?? 0.5
        }
    }
}
