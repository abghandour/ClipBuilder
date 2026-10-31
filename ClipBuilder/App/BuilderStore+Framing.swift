import Foundation

// MARK: - Framing request (the Express controls, per clip)

extension BuilderTimelineModel {
    /// The evidence the planner sees for this clip: its scene when it has
    /// one, else the whole file. The roster and turns are read by the render.
    func framingContext(for clip: TimelineClip, type: VideoType?) -> FramingContext? {
        let aspect = document.renderSettings.aspectRatio
        if let scene = scene(for: clip) {
            let start = clip.sourceStart ?? scene.startTime
            return FramingContext(scene: scene, range: start...(start + clip.sourceSpan), canvasAspect: aspect, type: type)
        }
        guard let file = clip.videoFile else { return nil }
        let size = sourceSizeByPath[file] ?? CGSize(width: 1920, height: 1080)
        let start = clip.sourceStart ?? 0
        let video = VideoRecord(id: 0, hash: "", filename: URL(fileURLWithPath: file).lastPathComponent, path: file,
                                duration: start + clip.sourceSpan, width: Int(size.width), height: Int(size.height),
                                wide: clip.wide, videoType: (type ?? .other).rawValue)
        return FramingContext(video: video, range: start...(start + clip.sourceSpan), canvasAspect: aspect, type: type)
    }

    /// Store the request and resolve it onto the clip. One undo step per clip
    /// burst, like any inspector edit.
    func setFramingRequest(_ uid: UUID, _ framing: Framing, type: VideoType?) {
        guard let clip = clip(uid), !clip.bumper, !clip.isCutaway,
              let context = framingContext(for: clip, type: type) else { return }
        let plan = FramingPlanner.resolve(framing: framing, context: context)
        let scene = scene(for: clip)
        updateClip(uid) {
            $0.framingRequest = framing
            BuilderFraming.apply(plan, wide: scene?.wide ?? $0.wide, cropXFrac: scene?.cropXFrac,
                                 storedPath: scene?.centerStagePath, sceneStart: scene?.startTime ?? 0, to: &$0)
        }
    }

    /// Back to the analysis: no request, no plan, the scene's own crop.
    func clearFramingRequest(_ uid: UUID) {
        guard let clip = clip(uid), clip.framingRequest != nil || clip.framingPlan != nil else { return }
        let scene = scene(for: clip)
        updateClip(uid) {
            $0.framingRequest = nil
            BuilderFraming.apply(nil, wide: scene?.wide ?? $0.wide, cropXFrac: scene?.cropXFrac,
                                 storedPath: nil, sceneStart: scene?.startTime ?? 0, to: &$0)
        }
    }
}
