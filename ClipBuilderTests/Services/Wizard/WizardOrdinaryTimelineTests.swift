import Foundation
import Testing
@testable import Clip_Builder

struct WizardOrdinaryTimelineTests {
    @Test("ordinary documents retain exact source clocks, saved paths and framing for every footage kind", arguments: VideoType.allCases)
    func sourceClocks(_ type: VideoType) throws {
        var scene = Fixtures.scene(start: 2, end: 6)
        let path = SceneCameraPath(camera: "fastAction", keyframes: [
            CameraPathKeyframe(t: 0, x: 0.2, y: 0, w: 0.3, h: 1),
            CameraPathKeyframe(t: 4, x: 0.4, y: 0, w: 0.3, h: 1)])
        scene.centerStagePathJSON = String(data: try JSONEncoder().encode(path), encoding: .utf8)
        var clip = Fixtures.planClip(start: 2.5, end: 5.5)
        clip.speed = 1.5
        let context = FramingContext(scene: scene, range: clip.start...clip.end, canvasAspect: 9.0 / 16, type: type)
        let framing = FramingPlanner.resolve(framing: Framing(subject: .centerStage), context: context)
        let document = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene],
            settings: RenderSettings(), framingPlan: framing)
        let item = try #require(document.videoTrack.first)
        #expect(item.sourceStart == 2.5 && item.sourceEnd == 5.5)
        #expect(item.duration == 2 && item.effectiveSpeed == 1.5)
        #expect(item.precision == .speech)
        #expect(item.framingPlan == framing)
        #expect(item.cameraPath == CenterStageService.slice(path.keyframes, from: 0.5, duration: 3))
        let resolved = try #require(MultitrackRenderer.resolveClips(document: document, scenes: [scene]).first)
        #expect(resolved.transcriptStart(at: 1) == 4)
    }

    @Test("original and legacy cuts request no tracking")
    func staticCuts() throws {
        let scene = Fixtures.scene()
        for plan: FramingPlan? in [nil, .static(window: nil, fit: .fill, feather: 0.08, blur: 0.5),
                                  .static(window: FreeCropRect(xFrac: 0.5, wFrac: 0.5), fit: .fill, feather: 0.08, blur: 0.5)] {
            let document = WizardOrdinaryTimeline.cutDocument(clip: Fixtures.planClip(), sceneMap: [scene.id: scene],
                settings: RenderSettings(), framingPlan: plan)
            let clip = try #require(document.videoTrack.first)
            #expect(!clip.centerStage && clip.cameraPath == nil && clip.areaRegion == nil)
            if let window = plan?.sourceWindow { #expect(clip.freeCrops?.first?.src == window) }
            if plan == nil { #expect(clip.cropXFrac == 0.5 && clip.wide) }
        }
    }

    @Test("retiming recipe cuts moves visuals and decorations but preserves source and program audio offsets")
    func retimedRecipe() throws {
        var main = Fixtures.timelineClip(sourceStart: 10, duration: 3)
        main.framingProgramAudio = FramingProgramAudio(path: "/tmp/program.mp4", start: 20, visualStart: 10)
        var cutaway = Fixtures.timelineClip(sourceStart: 30, duration: 1.5, startTime: 1.5, track: 1)
        cutaway.role = .cutaway; cutaway.muted = true
        var source = Fixtures.timelineDocument(clips: [main, cutaway])
        source.textOverlays = [TextOverlayItem(text: "Tag", startTime: 1.5, endTime: 3)]
        source.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 3)]
        let result = WizardOrdinaryTimeline.retimed(source, speed: 1.5)
        #expect(result.videoTrack.map(\.sourceStart) == [10, 30])
        #expect(result.videoTrack.map(\.duration) == [2, 1])
        #expect(result.videoTrack.map(\.startTime) == [0, 1])
        #expect(result.videoTrack.allSatisfy { $0.effectiveSpeed == 1.5 })
        #expect(result.videoTrack[0].framingProgramAudio == main.framingProgramAudio)
        #expect(result.textOverlays[0].startTime == 1 && result.textOverlays[0].endTime == 2)
        #expect(result.cropBlocks[0].duration == 2)
        #expect(result.videoTrack[1].muted)
    }
}
