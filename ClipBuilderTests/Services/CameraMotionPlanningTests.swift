import Testing
import CoreGraphics
@testable import Clip_Builder

struct CameraMotionPlanningTests {
    /// 30 fps samples: a sine wobble of `amplitude` (fraction of the frame)
    /// at `hz`, only inside `shaky`, plus a slow pan of `pan` per second.
    private func samples(duration: Double, shaky: ClosedRange<Double>? = nil, amplitude: Double = 0.02,
                         hz: Double = 4, pan: Double = 0) -> [CameraMotionSample] {
        var previous = 0.0
        return stride(from: 0.0, through: duration, by: 1.0 / 30).map { time in
            let wobble = shaky.map { $0.contains(time) ? amplitude * sin(2 * .pi * hz * time) : 0 } ?? 0
            let position = wobble + pan * time
            defer { previous = position }
            return CameraMotionSample(time: time, dx: position - previous, dy: (position - previous) / 2)
        }
    }

    @Test func calmFootageHasNoProfile() {
        #expect(CameraMotionPlanning.profile(samples(duration: 10)) == nil)
        #expect(CameraMotionPlanning.profile(samples(duration: 10, pan: 0.05)) == nil, "a slow pan is intended motion")
        #expect(CameraMotionPlanning.profile(samples(duration: 10, shaky: 2...4, amplitude: 0.001)) == nil, "tiny wobble ignored")
    }

    @Test func shakyStretchIsFoundAndMarginFollowsItsEnvelope() throws {
        let profile = try #require(CameraMotionPlanning.profile(samples(duration: 12, shaky: 3...6, pan: 0.05)))
        #expect(profile.sections.count == 1)
        let section = try #require(profile.sections.first)
        #expect(abs(section.lowerBound - 3) < 0.6 && abs(section.upperBound - 6) < 0.6)
        #expect(profile.peak > 0.015 && profile.peak < 0.03)
        let inside = try #require(profile.shake(at: 4.5))
        #expect(inside.marginX > 0.01 && inside.marginX <= CameraMotionPlanning.maxMargin)
        #expect(inside.marginY > 0.005 && inside.marginY < inside.marginX, "y shakes half as much")
        let calm = try #require(profile.shake(at: 9))
        #expect(calm.marginX == 0 && abs(calm.x) < 0.002, "the pan does not read as shake")
        let edge = try #require(profile.shake(at: 6.3))
        #expect(edge.marginX > 0 && edge.marginX < inside.marginX, "the margin ramps out instead of jumping")
    }

    @Test func denseTimesCoverOnlyTheShakyStretches() throws {
        let profile = try #require(CameraMotionPlanning.profile(samples(duration: 12, shaky: 3...6)))
        let times = CameraMotionPlanning.denseTimes(profile, through: 12)
        #expect(times.allSatisfy { $0 >= 2.4 && $0 <= 6.6 })
        #expect(times.count > 50)
        let spacing = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(spacing.allSatisfy { abs($0 - CameraMotionPlanning.keyframeInterval) < 1e-6 })
    }

    @Test func stabilizedCropZoomsInOnlyWhereItLacksRoomAndFollowsTheShake() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // A 9:16 crop already has horizontal room, so only the height shrinks.
        let tall = CGRect(x: 600, y: 0, width: 607.5, height: 1080)
        let moved = CameraMotionPlanning.stabilized(crop: tall, shake: CGPoint(x: 10, y: -8),
            margin: CGSize(width: 20, height: 20), bounds: bounds, minHeight: 648, aspect: 9.0 / 16)
        #expect(abs(moved.height - 1040) < 1e-6 && abs(moved.width - 1040 * 9 / 16) < 1e-6)
        #expect(abs(moved.midX - (tall.midX + 10)) < 1e-6 && abs(moved.minY - 12) < 1e-6)
        // A full-frame 16:9 crop shrinks on both axes but never under minHeight.
        let full = CameraMotionPlanning.stabilized(crop: bounds, shake: .zero,
            margin: CGSize(width: 300, height: 300), bounds: bounds, minHeight: 648, aspect: 16.0 / 9)
        #expect(abs(full.height - 648) < 1e-6 && abs(full.midX - 960) < 1e-6)
        // The shift clamps at the frame edge instead of leaving the frame.
        let edge = CameraMotionPlanning.stabilized(crop: tall, shake: CGPoint(x: -700, y: 0),
            margin: .zero, bounds: bounds, minHeight: 648, aspect: 9.0 / 16)
        #expect(edge.minX == 0 && edge == CGRect(x: 0, y: 0, width: 607.5, height: 1080))
        // An off-centre crop measures its clearance on the tight side: a crop
        // touching the left edge must shrink to earn leftward room.
        let left = CGRect(x: 0, y: 0, width: 607.5, height: 1080)
        let shrunk = CameraMotionPlanning.stabilized(crop: left, shake: CGPoint(x: -20, y: 0),
            margin: CGSize(width: 20, height: 0), bounds: bounds, minHeight: 648, aspect: 9.0 / 16)
        #expect(shrunk.width < left.width - 30 && shrunk.minX < 1e-6, "zoomed in, then the shift lands at the edge")
        #expect(shrunk.width > left.width - 50)
        // No margin, no shake: untouched.
        #expect(CameraMotionPlanning.stabilized(crop: tall, shake: .zero, margin: .zero,
            bounds: bounds, minHeight: 648, aspect: 9.0 / 16) == tall)
    }

    @Test func aShotChangeInTheSourceIsNotShake() throws {
        var motion = samples(duration: 8)
        // The registration across the cut reports a huge, meaningless shift.
        motion[120] = CameraMotionSample(time: motion[120].time, dx: 0.4, dy: -0.3, cut: true)
        #expect(CameraMotionPlanning.profile(motion) == nil)
        #expect(CameraMotionPlanning.cuts(in: motion) == [motion[120].time])
        // Real shake on both sides of the cut is still found, with the cut's neighbourhood left alone.
        var shaky = samples(duration: 8, shaky: 1...7)
        shaky[120] = CameraMotionSample(time: shaky[120].time, dx: 0.4, dy: -0.3, cut: true)
        let profile = try #require(CameraMotionPlanning.profile(shaky))
        #expect(profile.cuts.count == 1)
        let atCut = try #require(profile.shake(at: 4)), before = try #require(profile.shake(at: 2.5))
        #expect(atCut.x == 0 && before.envelopeX > 0.01)
        #expect(CameraMotionPlanning.summary(profile, duration: 8, cuts: profile.cuts).contains("1 shot change in the source"))
    }

    @Test func summaryNamesTheStretches() throws {
        #expect(CameraMotionPlanning.summary(nil, duration: 5).contains("no camera shake"))
        let profile = try #require(CameraMotionPlanning.profile(samples(duration: 12, shaky: 3...6)))
        let text = CameraMotionPlanning.summary(profile, duration: 12)
        #expect(text.contains("1 shaky stretch,") && text.contains("of 12.0 s"))
    }
}
