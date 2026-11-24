import Foundation
import Testing
@testable import Clip_Builder

@Suite("Telestration playback clock")
struct TelestrationPlaybackTests {
    /// Two figures at 0.5 s, 1 s stay, 0.5 s fade: 2.5 s of animation.
    private func drawing(motion: Double? = nil, linger: Double? = nil) -> Telestration {
        Telestration(time: 10, figures: [.init(kind: .line), .init(kind: .oval, linger: linger)],
                     stay: 1, drawSpeed: 0.5, fade: 0.5, motion: motion)
    }

    @Test func motionIsOptionalAndClamped() throws {
        #expect(drawing().motion == nil)
        #expect(Telestration(motion: 0).motion == nil)
        #expect(Telestration(motion: 0.1).motion == 0.25)
        #expect(Telestration(motion: 3).motion == 1)
        let paused = try JSONEncoder().encode(drawing())
        #expect(!String(decoding: paused, as: UTF8.self).contains("motion"))
        let moving = try JSONDecoder().decode(Telestration.self, from: JSONEncoder().encode(drawing(motion: 0.5)))
        #expect(moving.motion == 0.5)
        #expect(abs(moving.sourceSpan - 1.25) < 1e-9)
        #expect(drawing().sourceSpan == 0)
    }

    @Test func pausedPreviewHoldsTheFrame() {
        let plan = TelestrationPlayback.preview(drawing(), end: 20)
        #expect(plan.total == 2.5)
        #expect(!plan.movesPicture)
        let middle = plan.moment(at: 1)
        #expect(middle == .init(source: 10, rate: 0, drawing: 1))
    }

    @Test func movingPreviewAdvancesAtItsSpeedThenLingers() {
        let plan = TelestrationPlayback.preview(drawing(motion: 0.5, linger: 1), end: 20)
        #expect(plan.movesPicture)
        #expect(abs(plan.total - 3.5) < 1e-9)
        #expect(plan.moment(at: 2) == .init(source: 11, rate: 0.5, drawing: 2))
        let after = plan.moment(at: 3)
        #expect(abs(after.source - 11.75) < 1e-9)
        #expect(after.rate == 1)
        #expect(after.drawing == nil)
        #expect(abs((after.linger ?? 0) - 0.5) < 1e-9)
        #expect(plan.boundaries == [2.5])
    }

    @Test func clipPlanPlaysLeadDrawingAndTailInRealTime() {
        let plan = TelestrationPlayback.clip(drawing(motion: 0.25), range: 8...14)
        #expect(plan.lead == 2)
        #expect(abs(plan.resume - 10.625) < 1e-9)
        #expect(abs(plan.total - (2 + 2.5 + 3.375)) < 1e-9)
        #expect(plan.moment(at: 1) == .init(source: 9, rate: 1))
        #expect(plan.moment(at: 3) == .init(source: 10.25, rate: 0.25, drawing: 1))
        #expect(plan.boundaries == [2, 4.5])
        // A pause adds its whole length to the clip.
        #expect(TelestrationPlayback.clip(drawing(), range: 8...14).total == 8.5)
    }

    @Test func recordingWaitsOnTheDrawingAndStretchesItsStay() {
        // Lead 2 s, figures and stay 2 s (the 0.5 s fade is left out), then it waits.
        let plan = TelestrationPlayback.recording(drawing(motion: 0.5), range: 8...14)
        #expect(plan.waits && plan.tail == 0 && plan.drawn == 2)
        #expect(plan.moment(at: 3) == .init(source: 10.5, rate: 0.5, drawing: 1))
        let waiting = plan.moment(at: 60)
        #expect(waiting == .init(source: 11, rate: 0, drawing: 2))
        #expect(TelestrationPlayback.state(of: drawing(), at: waiting).opacity == 1)
        #expect(plan.boundaries == [2])
        // Stopped before the drawing ends: nothing changes.
        #expect(TelestrationPlayback.stay(of: drawing(), covering: 3.5, in: plan) == nil)
        // 3.33 s past the drawing: the stay grows by that, rounded up to a tenth.
        #expect(TelestrationPlayback.stay(of: drawing(), covering: 7.33, in: plan) == 4.4)
        #expect(TelestrationPlayback.stay(of: drawing(), covering: 900, in: plan) == Telestration.maximumStay)
        // Play is not a recording.
        #expect(TelestrationPlayback.stay(of: drawing(), covering: 900, in: TelestrationPlayback.clip(drawing(), range: 8...14)) == nil)
    }

    @Test func tooLittleFootageFallsBackToAPause() {
        // 2.5 s at normal speed needs 2.5 s of footage; 2 s minus the last piece is left.
        #expect(TelestrationPlayback.rate(of: drawing(motion: 1), end: 12) == 0)
        #expect(TelestrationPlayback.rate(of: drawing(motion: 0.5), end: 12) == 0.5)
        #expect(TelestrationPlayback.room(after: 10, end: 12) == 1.75)
    }

    @Test func stateFollowsTheMoment() {
        let drawing = drawing(linger: 1)
        #expect(TelestrationPlayback.state(of: drawing, at: .init(source: 9, rate: 1)).figures.isEmpty)
        #expect(TelestrationPlayback.state(of: drawing, at: .init(source: 10, rate: 0, drawing: 0.75)).figures.count == 2)
        #expect(TelestrationPlayback.state(of: drawing, at: .init(source: 10, rate: 1, linger: 0.2)).figures.map(\.figure.kind) == [.oval])
        #expect(TelestrationPlayback.label(nil) == "Paused")
        #expect(TelestrationPlayback.label(0.25) == "25%")
        #expect(TelestrationPlayback.label(1) == "Normal speed")
    }
}
