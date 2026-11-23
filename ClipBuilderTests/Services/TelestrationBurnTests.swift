import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Telestration burn frame times")
struct TelestrationBurnTests {
    @Test(arguments: [0.25, 0.5, 1.0])
    func carriedFramesStartWithDrawingAndContinueIntoStay(speed: Double) throws {
        let drawing = Telestration(figures: [.init(linger: 1)], stay: 1, drawSpeed: 0.5, fade: 0.5, motion: 0.5)
        let frames = TelestrationBurn.lingerFrameTimes(drawing, offset: 0, duration: 5, speed: speed)
        #expect(frames.count == 90)
        #expect(frames.first?.elapsed == 0)
        #expect(abs(try #require(frames.last).sourceOffset - 89 * speed / 30) < 1e-9)
        let window = TelestrationBurn.lingerFrameTimes(drawing, offset: 1.5, duration: 3, speed: speed)
        #expect(window.count == 45 && window.first?.elapsed == 1.5)
        #expect(TelestrationBurn.lingerFrameTimes(drawing, offset: 3, duration: 1, speed: speed).isEmpty)
    }

    @Test("Times use the segment grid and exclude the drawing and segment ends")
    func exclusiveEnd() throws {
        let drawing = Telestration(time: 99, figures: [.init()], stay: 1, drawSpeed: 0.5, fade: 0.5)
        let times = TelestrationBurn.frameTimes(drawing, offset: 0, duration: 4)
        #expect(times.count == 60)
        #expect(times.first == 0)
        #expect(abs(try #require(times.last) - 59.0 / 30) < 1e-9)
        #expect(times.allSatisfy { $0 < drawing.duration })
        #expect(TelestrationBurn.frameTimes(drawing, offset: 0, duration: 0.05).count == 2)
        #expect(TelestrationBurn.frameTimes(drawing, offset: drawing.duration, duration: 1).isEmpty)
        #expect(TelestrationBurn.frameTimes(drawing, offset: 0, duration: 0).isEmpty)
        #expect(TelestrationBurn.frameTimes(drawing, offset: .nan, duration: 1).isEmpty)
        #expect(TelestrationBurn.frameTimes(drawing, offset: 0, duration: .infinity).isEmpty)
    }

    @Test("The next segment continues the animation instead of restarting")
    func continuation() {
        let drawing = Telestration(figures: [.init()], stay: 1, drawSpeed: 0.5, fade: 0.5)
        let first = TelestrationBurn.frameTimes(drawing, offset: 0, duration: 1)
        let next = TelestrationBurn.frameTimes(drawing, offset: 1, duration: 1)
        let whole = TelestrationBurn.frameTimes(drawing, offset: 0, duration: 2)
        #expect(first.count + next.count == whole.count)
        #expect(zip(first + next, whole).allSatisfy { abs($0.0 - $0.1) < 1e-9 })
        #expect(next.first == 1)
        #expect(TelestrationBurn.frameTimes(drawing, offset: -1, duration: 1) == first)
    }

    @Test("Hold animation gets a 30 fps timebase without changing existing strike graphs")
    func graphClocks() throws {
        let sequence = StrikeHighlightBurn.Sequence(offset: 0, frames: 30, pattern: "/tmp/d%04d.png")
        let size = CGSize(width: 640, height: 360)
        let strikes = try StrikeHighlightBurn.inGraph([sequence], size: size, input: "[hold]", tag: "draw")
        let drawing = try StrikeHighlightBurn.inHoldGraph([sequence], size: size, input: "[hold]", tag: "draw")
        #expect(strikes == ["[hold]setpts=PTS-STARTPTS[draw_b0]",
            "movie=filename='/tmp/d%04d.png':f=image2,format=rgba,scale=640:360,setpts=N/(30*TB)+0.000000/TB[draw_m0]",
            "[draw_b0][draw_m0]overlay=eof_action=pass:repeatlast=0[draw]"])
        #expect(drawing[1].contains("settb=1/30,format=rgba"))
        #expect(drawing[2] == strikes[2])
    }

    @Test("Crop splits preserve the hold origin and optional drawing cache identity")
    func placementOffsets() throws {
        var hold = Fixtures.timelineClip(sceneID: nil, sourceStart: 4, duration: 3, startTime: 2)
        hold.hold = true
        hold.telestration = Telestration(time: 4, figures: [.init()])
        var document = Fixtures.timelineDocument(clips: [hold])
        document.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 3),
                               .init(layout: .fullScreen, startTime: 3, duration: 2)]
        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [])
        let segments = MultitrackRenderer.buildLayeredSegments(resolved).filter { !$0.clips.isEmpty }
        #expect(segments.count == 2)
        let second = try #require(segments.last)
        let placement = try #require(MultitrackRenderer.placements(for: second).first)
        #expect(placement.holdOffset(at: second.start) == 1)
        #expect(placement.holdOffset(at: 0) == 0)
        #expect(second.clips.first?.telestration == hold.telestration)
    }
}
