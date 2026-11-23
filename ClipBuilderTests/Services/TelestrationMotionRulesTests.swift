import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Telestration moving picture rules")
struct TelestrationMotionRulesTests {
    private func drawing(_ time: Double = 12, motion: Double = 0.5) -> Telestration {
        Telestration(time: time, figures: [.init()], stay: 1, drawSpeed: 0.5, fade: 0.5, motion: motion)
    }

    @Test(arguments: [1.0, 0.5], [0.25, 0.5, 1.0])
    func speedsAndSourceSlices(speed: Double, motion: Double) throws {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 10 / speed, startTime: 3, speed: speed)
        let path = [CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.4, h: 1),
                    CameraPathKeyframe(t: 10, x: 0.6, y: 0, w: 0.4, h: 1)]
        clip.cameraPath = path
        let drawing = drawing(motion: motion)
        let result = TelestrationMotionRules.moving([clip], drawings: [drawing])
        if speed * motion < StrikeImpactRules.minimumSpeed {
            #expect(result.pieces == [clip] && result.stretches.isEmpty)
            #expect(result.fallback == [TelestrationMotionRules.paused(drawing)])
            return
        }
        #expect(result.fallback.isEmpty && result.pieces.count == 3)
        let end = drawing.time + drawing.duration * speed * motion
        #expect(result.pieces.map(\.sourceStart) == [10, 12, end])
        #expect(result.pieces.map(\.sourceEnd) == [12, end, 20])
        #expect(result.pieces[1].speed == speed * motion && result.pieces[1].duration == drawing.duration)
        #expect(result.pieces[1].telestration == drawing)
        #expect(result.pieces[0].telestration == nil && result.pieces[2].telestration == nil)
        #expect(result.pieces.allSatisfy { $0.hold != true && $0.slowLineage == clip.uid })
        #expect(result.pieces.dropFirst().allSatisfy { $0.stayCut == false })
        #expect(result.pieces[1].cameraPath == CenterStageService.slice(path, from: 2, duration: end - 12))
        #expect(result.pieces[2].cameraPath == CenterStageService.slice(path, from: end - 10, duration: 20 - end))
        #expect(abs(result.pieces.reduce(0) { $0 + $1.duration } - clip.duration - drawing.duration * (1 - motion)) < 1e-9)
        #expect(result.stretches == [.init(start: 12, end: end, factor: motion)])
        var cursor = clip.startTime
        for piece in result.pieces {
            #expect(abs(piece.startTime - cursor) < 1e-9)
            cursor += piece.duration
        }
    }

    @Test func fallbackReasonsAndHoldSafety() throws {
        let clip = Fixtures.timelineClip(sourceStart: 10, duration: 10)
        let moving = drawing()
        let paused = StrikeFreezeRules.pieces(clip, contacts: [12.5], hold: 0.8)
        #expect(TelestrationMotionRules.fallbackReason(moving, in: paused, drawings: [])?.contains("overlaps") == true)
        #expect(TelestrationMotionRules.moving(paused, drawings: [moving]).pieces == paused)
        #expect(TelestrationMotionRules.fallbackReason(drawing(19), in: [clip], drawings: [])?.contains("not enough") == true)
        #expect(TelestrationMotionRules.fallbackReason(drawing(10.1), in: [clip], drawings: [])?.contains("too short") == true)
        var short = moving
        short.drawSpeed = 0.05
        short.stay = 0.05
        short.fade = 0
        #expect(TelestrationMotionRules.fallbackReason(short, in: [clip], drawings: [])?.contains("too short") == true)
        var slow = clip
        slow.speed = 0.25
        #expect(TelestrationMotionRules.fallbackReason(moving, in: [slow], drawings: [])?.contains("0.25") == true)
        let other = TelestrationMotionRules.paused(drawing(12.5))
        #expect(TelestrationMotionRules.fallbackReason(moving, in: [clip], drawings: [moving, other]) == "overlaps another drawing")
        let overlap = TelestrationMotionRules.moving([clip], drawings: [moving, drawing(12.5)])
        #expect(overlap.fallback.count == 2 && overlap.stretches.isEmpty)
        let holds = StrikeFreezeRules.pieces(clip, pauses: [.init(time: moving.time, duration: moving.duration, drawing: moving)])
        #expect(try #require(holds.first { $0.hold == true }).telestration?.motion == nil)
    }

    @Test func twoDrawingsAndDrawingAfterHold() throws {
        let clip = Fixtures.timelineClip(sourceStart: 10, duration: 10, startTime: 2)
        let paused = StrikeFreezeRules.pieces(clip, contacts: [11], hold: 0.8)
        let first = drawing(12), second = drawing(16, motion: 1)
        let result = TelestrationMotionRules.moving(paused, drawings: [second, first])
        #expect(result.fallback.isEmpty && result.stretches.count == 2)
        #expect(result.pieces.compactMap(\.telestration) == [first, second])
        #expect(result.pieces.first { $0.hold == true } == paused.first { $0.hold == true })
        #expect(abs(try #require(result.pieces.first { $0.telestration == first }).startTime - 4.8) < 1e-9)
        #expect(abs(try #require(result.pieces.first { $0.telestration == second }).startTime - 9.8) < 1e-9)
        #expect(abs(result.pieces.reduce(0) { $0 + $1.duration } - 11.8) < 1e-9)
        // A span ending at a contact does not overlap its pause.
        let boundary = StrikeFreezeRules.pieces(clip, contacts: [13], hold: 0.8)
        #expect(TelestrationMotionRules.moving(boundary, drawings: [first]).fallback.isEmpty)
        // Closely spaced spans can leave a tiny moving piece even without overlap.
        let crowded = TelestrationMotionRules.moving([clip], drawings: [first, drawing(13.1)])
        #expect(crowded.fallback.count == 1)
    }

    @Test func nilMotionLeavesPiecesUntouched() {
        let clip = Fixtures.timelineClip()
        let result = TelestrationMotionRules.moving([clip], drawings: [TelestrationMotionRules.paused(drawing())])
        #expect(result.pieces == [clip] && result.stretches.isEmpty && result.fallback.isEmpty)
    }
}
