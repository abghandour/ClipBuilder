import Foundation
import Testing
@testable import Clip_Builder

@Suite("Bumper rendering")
struct BumperRenderingTests {
    private func bumper(at time: Double = 4) -> TimelineClip {
        BumperAsset(path: "/bumper.mp4", displayName: "Subscribe", duration: 2).clip(at: time)!
    }

    @Test("bumper resolution ignores scene, captions, camera and all crops")
    func resolution() throws {
        var clip = bumper()
        clip.sceneID = 1
        clip.wide = true
        clip.centerStage = true
        clip.captions = "top"
        clip.cropXFrac = 0.8
        clip.screenCrop = "50-50 Horizontal/Top"
        clip.areaWindow = FreeCropRect(xFrac: 0, yFrac: 0, wFrac: 0.5, hFrac: 0.5)
        clip.freeCrops = [FreeCrop(src: clip.areaWindow!, dst: clip.areaWindow!)]
        var document = Fixtures.timelineDocument(clips: [clip])
        document.trackSettings[0].captions = "bottom"
        document.trackSettings[0].defaultCropXFrac = 0.1
        let resolved = try #require(MultitrackRenderer.resolveClips(document: document, scenes: [Fixtures.scene()]).first)
        #expect(resolved.bumper && resolved.sourcePath == "/bumper.mp4")
        #expect(resolved.videoID == nil && resolved.cameraPath == nil && !resolved.centerStage)
        #expect(resolved.captionsPosition == nil && !resolved.wide)
        #expect(resolved.effectiveCropXFrac == nil && resolved.freeCrops == nil)
        #expect(resolved.screenCrop == nil && resolved.areaWindow == nil)
        document.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 5),
                               CropBlockItem(layout: .fullScreen, startTime: 5, duration: 5)]
        let pieces = MultitrackRenderer.applyCropBlocks([resolved], document: document)
        #expect(pieces.count == 1 && pieces[0].duration == 2 && pieces[0].startTime == 4)
        #expect(pieces[0].screenCrop == nil)
    }

    @Test("bumper owns every overlapping segment and prevents overlay fusion")
    func segments() {
        let document = Fixtures.timelineDocument(clips: [bumper(),
            Fixtures.timelineClip(duration: 10, track: 1)])
        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [Fixtures.scene()])
        let segments = MultitrackRenderer.buildLayeredSegments(resolved)
        #expect(segments.map(\.start) == [0, 4, 6])
        #expect(segments[1].clips.count == 1 && segments[1].clips[0].bumper)
        let overlay = MultitrackRenderer.TimedOverlayPNG(png: URL(fileURLWithPath: "/logo.png"),
            startTime: 4.2, endTime: 5.8, transIn: "fade", transOut: "fade")
        let plan = MultitrackRenderer.partitionOverlays([overlay], segments: segments)
        #expect(plan.bySegment.isEmpty && plan.remaining.count == 1)
        #expect(MultitrackRenderer.overlayWindows(plan.remaining, excluding: [4..<6]).isEmpty)
    }

    @Test("final overlay windows split around all bumpers with half-open boundaries")
    func overlays() {
        let overlay = MultitrackRenderer.TimedOverlayPNG(png: URL(fileURLWithPath: "/headline.png"),
            startTime: 1, endTime: 10, transIn: "fade", transOut: "slide_up")
        let windows = MultitrackRenderer.overlayWindows([overlay], excluding: [4..<6, 7..<8])
        #expect(windows.map(\.startTime) == [1, 6, 8])
        #expect(windows.map(\.endTime) == [4, 7, 10])
        #expect(windows[0].transIn == "fade" && windows[0].transOut == "none")
        #expect(windows[1].transIn == "none" && windows[1].transOut == "none")
        #expect(windows[2].transOut == "slide_up")
    }

    @Test("missing edge bumpers close gaps; interior bumpers keep black exclusive time")
    func missing() {
        var doc = Fixtures.timelineDocument(clips: [bumper(at: 0),
            Fixtures.timelineClip(duration: 2, startTime: 2), bumper(at: 4),
            Fixtures.timelineClip(duration: 2, startTime: 6), bumper(at: 8)])
        var overlay = TextOverlayItem()
        overlay.startTime = 2; overlay.endTime = 8
        doc.textOverlays = [overlay]
        var log: [String] = []
        let trimmed = MultitrackRenderer.removingMissingEdgeBumpers(doc, exists: { $0 != "/bumper.mp4" }, emit: { log.append($0) })
        #expect(log == ["Bumper 'Subscribe' is missing; skipped"])
        #expect(trimmed.videoTrack.map(\.startTime) == [0, 2, 4])
        #expect(trimmed.videoTrack.filter(\.bumper).count == 1)
        #expect(trimmed.textOverlays[0].startTime == 0 && trimmed.textOverlays[0].endTime == 6)
        let segments = MultitrackRenderer.buildLayeredSegments(MultitrackRenderer.resolveClips(document: trimmed, scenes: [Fixtures.scene()]))
        #expect(segments[1].clips.count == 1 && segments[1].clips[0].bumper)
    }
}
