import CoreGraphics
import Foundation

extension BuilderTimelineModel {
    /// The clip whose picture is under the playhead at `time`: the focused
    /// track's clip when it is playing, else the first active one.
    func pictureClip(at time: Double) -> TimelineClip? {
        let active = document.videoTrack.filter {
            !$0.bumper && $0.startTime <= time + 0.001 && time < $0.startTime + $0.duration
        }
        return active.first { $0.track == focusedTrack } ?? active.first
    }

    /// How `clip`'s source frame reaches the output at `time`, the same way
    /// the preview pane lays it out: a hand-placed window or camera crop
    /// scaled into its area, or an aspect fill of the area or frame.
    func framePlacement(for clip: TimelineClip, atTimeline time: Double) -> ImageGeneration.Placement {
        let output = document.renderSettings.aspectRatio
        let sourceAspect = sourceAspect(for: clip) ?? 16.0 / 9.0
        let layout = document.cropBlock(at: time)?.layout
        let area: ScreenCropArea? = layout.flatMap { layout in
            let areas = layout.orderedAreas
            return clip.track < areas.count && !clip.coverAllAreas ? areas[clip.track] : nil
        }
        if clip.isCutaway, clip.coverAllAreas, let window = clip.cutawaySourceWindow {
            return ImageGeneration.Placement(window: window, box: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        if let area {
            let bounds = area.bounds
            let box = CGRect(x: bounds.x, y: bounds.y, width: bounds.w, height: bounds.h)
            let regionWindow: FreeCropRect? = clip.areaRegion.map { region in
                CropRecipePlanner.crop(
                    tile: PodcastTile(index: 0, x: region.xFrac, y: region.yFrac, w: region.wFrac, h: region.hFrac),
                    aspect: output * bounds.w / max(0.001, bounds.h),
                    sourceAspect: sourceAspect)
            }
            let cameraWindow: FreeCropRect? = clip.cameraPath == nil ? regionWindow
                : cameraRect(for: clip, atTimeline: time).map {
                    FreeCropRect(xFrac: $0.x, yFrac: $0.y, wFrac: $0.w, hFrac: $0.h)
                }
            if let window = clip.areaWindow ?? cameraWindow {
                return ImageGeneration.Placement(window: window, box: box)
            }
            return .filling(box: box, sourceAspect: sourceAspect, outputAspect: output)
        }
        let settings = document.trackSettings[safe: clip.track] ?? TrackSettings()
        let cropped = clip.wide && (clip.cropXFrac ?? settings.defaultCropXFrac) != nil
        if clip.wide, !clip.isCutaway, let rect = cameraRect(for: clip, atTimeline: time) {
            return ImageGeneration.Placement(
                window: FreeCropRect(xFrac: rect.x, yFrac: rect.y, wFrac: rect.w, hFrac: rect.h),
                box: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        if clip.wide, !cropped {
            let position = clip.position ?? settings.defaultPosition
            let slot = ["top": 0, "center": 1, "bottom": 2][position] ?? 0
            let box = CGRect(x: 0, y: Double(slot) / 3, width: 1, height: 1.0 / 3)
            return .filling(box: box, sourceAspect: sourceAspect, outputAspect: output)
        }
        return .filling(box: CGRect(x: 0, y: 0, width: 1, height: 1), sourceAspect: sourceAspect, outputAspect: output)
    }
}
