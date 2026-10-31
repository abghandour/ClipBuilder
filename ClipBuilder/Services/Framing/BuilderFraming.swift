import Foundation

/// Pure rules behind the Builder's framing request: how a resolved plan is
/// installed on a clip, and how a window dragged in the preview flows back
/// into the request. Mirrors `WizardOrdinaryTimeline.apply` for clips that
/// may have no scene record.
nonisolated enum BuilderFraming {
    /// Install `plan` on `clip`, replacing every hand-set framing field. Nil
    /// returns the clip to the analysis defaults (`wide`, `cropXFrac`).
    static func apply(_ plan: FramingPlan?, wide: Bool, cropXFrac: Double?,
                      storedPath: SceneCameraPath?, sceneStart: Double, to clip: inout TimelineClip) {
        clip.framingPlan = plan
        clip.wide = wide
        clip.cropXFrac = cropXFrac
        clip.centerStage = false
        clip.cameraPath = nil
        clip.cameraPathSource = nil
        clip.areaRegion = nil
        clip.areaWindow = nil
        clip.areaFocus = nil
        clip.freeCrops = nil
        if let plan {
            if plan.isStatic {
                clip.wide = false
                clip.cropXFrac = nil
            } else if plan.recipe?.centerStage == true {
                clip.centerStage = true
                clip.areaRegion = plan.sourceWindow ?? FreeCropRect()
                if plan.sourceWindow == nil, let stored = storedPath {
                    let path = CenterStageService.slice(stored.keyframes,
                        from: (clip.sourceStart ?? sceneStart) - sceneStart, duration: clip.sourceSpan)
                    if path.count >= 2 { clip.cameraPath = path }
                }
            }
            FocusFrame.apply(plan, to: &clip)
        } else if wide {
            clip.cropXFrac = cropXFrac ?? 0.5
        }
    }

    /// A static window dragged in the preview lives in `freeCrops`; the
    /// request's focus frame follows it so Zoom and Reset stay truthful.
    static func mirrorFocusFrame(before: TimelineClip, after clip: inout TimelineClip) {
        guard clip.framingRequest != nil, clip.framingPlan?.isStatic == true,
              let window = clip.freeCrops?.first?.src, window != before.freeCrops?.first?.src else { return }
        clip.framingRequest?.focusFrame = window
        if case .static(_, let fit, let feather, let blur)? = clip.framingPlan {
            clip.framingPlan = .static(window: window, fit: fit, feather: feather, blur: blur)
        }
    }
}
