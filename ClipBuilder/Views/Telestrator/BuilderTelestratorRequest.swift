import SwiftUI

/// A snapshot of the Builder edit, held by the page until Save or Cancel.
@MainActor
struct BuilderTelestratorRequest: Identifiable {
    let id = UUID()
    let model: BuilderTimelineModel
    let clip: TimelineClip
    let timelineTime: Double
    let timelineID: Int64?
    let profileGeneration: Int
    let videoURL: URL
    let duration: Double
    let aspect: CGFloat
    let visibleRect: CGRect?
    let sourceTime: Double

    init?(clip: TimelineClip, store: AppStore) {
        let model = store.builder
        guard let url = model.sourceURL(for: clip) else { return nil }
        self.model = model
        self.clip = clip
        timelineTime = model.playhead
        timelineID = model.timelineID
        profileGeneration = store.profileGeneration
        videoURL = url
        let source = model.drawingSource(clip)
        let video = store.videos.first { $0.path == url.path }
        sourceTime = model.sourceTime(for: source, atTimeline: model.playhead)
        duration = model.scene(for: clip)?.videoDuration
            ?? video?.duration
            ?? max(source.sourceEnd ?? sourceTime, sourceTime + 1)
        if let known = model.sourceAspect(for: clip) {
            aspect = known
        } else if let video, video.width > 0, video.height > 0 {
            aspect = Double(video.width) / Double(video.height)
        } else {
            aspect = clip.wide ? 16.0 / 9.0 : 9.0 / 16.0
        }
        if let window = clip.areaWindow ?? (clip.framingPlan?.isStatic == true ? clip.freeCrops?.first?.src : nil) {
            visibleRect = CGRect(x: window.xFrac, y: window.yFrac, width: window.wFrac, height: window.hFrac)
        } else if let rect = model.cameraRect(for: clip, atTimeline: model.playhead) {
            visibleRect = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
        } else {
            visibleRect = nil
        }
    }

    /// Synchronous store work; the sheet's async callback has nothing to await here.
    func save(_ drawing: Telestration?, store: AppStore) -> String? {
        let failure: String?
        if store.builder !== model || store.profileGeneration != profileGeneration || model.timelineID != timelineID {
            failure = "The timeline or profile changed; reopen the drawing on the current timeline."
        } else if model.clip(clip.uid) != clip || model.sourceURL(for: clip) != videoURL
                    // Clip equality leaves the camera out; the sheet's crop guide was drawn from it.
                    || model.clip(clip.uid)?.cameraPath != clip.cameraPath {
            failure = "The clip changed while the drawing was open; reopen it to use the current clip."
        } else {
            let result: Result<Void, ClipEditFailure>
            if clip.hold == true {
                result = model.setDrawing(clip.uid, drawing: drawing)
            } else if let drawing {
                result = model.drawOnPause(clip.uid, at: timelineTime, drawing: drawing).map { _ in () }
            } else {
                result = .success(())
            }
            switch result {
            case .success: failure = nil
            case .failure(let error): failure = error.reason
            }
        }
        if let failure { ErrorLog.record("Builder drawing", failure) }
        return failure
    }
}
