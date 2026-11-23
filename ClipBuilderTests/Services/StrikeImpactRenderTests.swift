import Foundation
import Testing
@testable import Clip_Builder

@Suite("Strike impact render graph")
struct StrikeImpactRenderTests {
    @Test func audioStrings() {
        #expect(StrikeImpactRender.audioTempo(speed: 1) == "")
        #expect(StrikeImpactRender.audioTempo(speed: 0.5) == "atempo=0.5000,")
        #expect(StrikeImpactRender.audioTempo(speed: 0.4) == "atempo=0.5000,atempo=0.8000,")
        #expect(StrikeImpactRender.audioTempo(speed: 0.25) == "atempo=0.5000,atempo=0.5000,")
        for speed in [0.5, 0.75, 1, 1.5, 2, 3] {
            let old = speed == 1 ? "" : String(format: "atempo=%.4f,", min(2, max(0.5, speed)))
            #expect(StrikeImpactRender.audioTempo(speed: speed) == old)
        }
    }

    @Test func flashStrings() {
        #expect(StrikeImpactRender.flash(nil, speed: 1, hold: false) == nil)
        #expect(StrikeImpactRender.flash(nil, speed: 0.4, hold: true) == nil)
        #expect(StrikeImpactRender.flash(0.12, speed: 1, hold: false)
            == "setpts=PTS-STARTPTS,fade=t=in:st=0:d=0.120000:color=white")
        #expect(StrikeImpactRender.flash(0.12, speed: 1, hold: true)
            == "fps=30,setpts=PTS-STARTPTS,fade=t=in:st=0:d=0.120000:color=white")
        #expect(StrikeImpactRender.flash(0.12, speed: 0.4, hold: false)
            == "setpts=(PTS-STARTPTS)/0.4000,fade=t=in:st=0:d=0.120000:color=white,setpts=PTS*0.4000")
    }

    @Test func windowsSegmentsAndCache() throws {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 3)
        clip.videoFile = "/tmp/flash.mp4"
        clip.flashIn = 0.12
        let document = Fixtures.timelineDocument(clips: [clip])
        let resolved = try #require(MultitrackRenderer.resolveClips(document: document, scenes: []).first)
        #expect(resolved.flashIn == 0.12)
        let start = MultitrackRenderer.Segment(start: 0, end: 1, clips: [resolved])
        let later = MultitrackRenderer.Segment(start: 1, end: 3, clips: [resolved])
        #expect(MultitrackRenderer.placements(for: start).first?.flashIn == 0.12)
        #expect(MultitrackRenderer.placements(for: later).first?.flashIn == nil)
        // Segment boundaries are rounded to milliseconds: a piece starting at
        // 1.2346 is entered at 1.235 and still flashes.
        var rounded = resolved
        rounded.startTime = 1.2346
        let entered = MultitrackRenderer.Segment(start: 1.235, end: 3, clips: [rounded])
        #expect(MultitrackRenderer.placements(for: entered).first?.flashIn == 0.12)
        #expect(MultitrackRenderer.windowed(document, from: 0, to: 1).videoTrack.first?.flashIn == 0.12)
        #expect(MultitrackRenderer.windowed(document, from: 0.05, to: 1).videoTrack.first?.flashIn == nil)
        var crops = document
        crops.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 1),
                            .init(layout: .fullScreen, startTime: 1, duration: 2)]
        let split = MultitrackRenderer.resolveClips(document: crops, scenes: [])
        #expect(split.first?.flashIn == 0.12 && split.last?.flashIn == nil)
        // A layout change 20 ms after the contact drops the first sliver; the flash moves to the next piece.
        crops.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 0.02),
                            .init(layout: .fullScreen, startTime: 0.02, duration: 2.98)]
        let sliver = MultitrackRenderer.resolveClips(document: crops, scenes: [])
        #expect(sliver.count == 1 && sliver.first?.flashIn == 0.12)
        var input = RenderSegmentKey(start: 0, duration: 3, clips: [resolved], captions: [], overlays: [], masks: [:],
            fontFingerprints: [], captionStyle: CaptionStyle(), settings: RenderSettings(), encoder: [])
        let flashedKey = try RenderSegmentCache.key(input)
        var slow = input
        slow.slowAudio = true
        #expect(try RenderSegmentCache.key(slow) != flashedKey)
        input.clips[0].flashIn = nil
        let plainKey = try RenderSegmentCache.key(input)
        #expect(flashedKey != plainKey)
        let data = try JSONEncoder().encode(input.clips[0])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["flashIn"] == nil)
        let roundTrip = try JSONDecoder().decode(MultitrackRenderer.ResolvedClip.self, from: data)
        input.clips = [roundTrip]
        #expect(try RenderSegmentCache.key(input) == plainKey)
    }
    @Test func slowPiecesKeepSourceCaptionsStayAndFlashClocks() throws {
        let scene = Fixtures.scene(start: 0, end: 4)
        var clip = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 0, duration: 4)
        clip.captions = "bottom"
        let drawing = Telestration(time: 1, figures: [.init(linger: 1)])
        let paused = try #require(TimelinePauseRules.insert([
            .init(time: 1, duration: 0.8, drawing: drawing, owner: clip.uid)
        ], into: Fixtures.timelineDocument(clips: [clip]), resolve: { $0 }))
        let tail = try #require(paused.document.videoTrack.last)
        // Clamp the lead to the resume boundary: the slow piece carries the stay.
        let slowed = try #require(TimelineSlowRules.insert([2.1], owner: tail.uid, strength: .medium, into: paused.document))
        var document = slowed.document
        let slowIndex = try #require(document.videoTrack.firstIndex { $0.slowGroup != nil })
        document.videoTrack[slowIndex].flashIn = 0.12
        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [scene])
        let moving = try #require(resolved.first { abs($0.speed - 0.4) < 1e-9 })
        #expect(moving.lingering == drawing)
        #expect(abs(try #require(moving.flashIn) - 0.12) < 1e-9)
        let captions = MultitrackRenderer.captionCuts(resolved)
        let slowCaption = try #require(captions.first { abs($0.speed - 0.4) < 1e-9 })
        #expect(abs(slowCaption.start - 1.8) < 1e-9)
        #expect(abs(slowCaption.sourceStart - 1) < 1e-9)
        #expect(abs(slowCaption.end - 2.55) < 1e-9)
        #expect(StrikeImpactRender.audioTempo(speed: moving.speed) == "atempo=0.5000,atempo=0.8000,")
        #expect(StrikeImpactRender.flash(moving.flashIn, speed: moving.speed, hold: false)
            == "setpts=(PTS-STARTPTS)/0.4000,fade=t=in:st=0:d=0.120000:color=white,setpts=PTS*0.4000")
    }

    @Test func trackedCropUsesSourceTimeAcrossSpeedChanges() throws {
        var first = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 4)
        first.centerStage = true
        var second = first; second.uid = UUID(); second.track = 1
        let slowed = try #require(StrikeImpactRules.sharedSlowing([[first], [second]], contacts: [2], strength: .medium))
        let document = Fixtures.timelineDocument(clips: slowed.tracks.flatMap { $0 })
        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [])
        let moving = try #require(resolved.first { abs($0.speed - 0.4) < 1e-9 })
        let path = [CameraPathKeyframe(t: 0, x: 0.1, y: 0.1, w: 0.8, h: 0.8),
                    .init(t: 4, x: 0.25, y: 0.25, w: 0.4, h: 0.4)]
        let slowPath = CenterStageContinuity.slice(path, runStart: 0, clip: moving, transform: true)
        #expect(abs(try #require(slowPath.last).t - 0.5) < 1e-9)
        #expect(abs(moving.duration - 1.25) < 1e-9)
        var ordinary = moving
        ordinary.speed = 1; ordinary.duration = 0.5
        let ordinaryPath = CenterStageContinuity.slice(path, runStart: 0, clip: ordinary, transform: true)
        #expect(slowPath == ordinaryPath)
        let area = ScreenCropArea(name: "Full", points: [.init(x: 0, y: 0), .init(x: 1, y: 0),
            .init(x: 1, y: 1), .init(x: 0, y: 1)])
        let slowGraph = AreaFramer.pathFilter(keyframes: slowPath, source: .init(width: 640, height: 360),
            area: area, transformInterpolation: true)
        let ordinaryGraph = AreaFramer.pathFilter(keyframes: ordinaryPath, source: .init(width: 640, height: 360),
            area: area, transformInterpolation: true)
        #expect(slowGraph == ordinaryGraph)
    }

}
