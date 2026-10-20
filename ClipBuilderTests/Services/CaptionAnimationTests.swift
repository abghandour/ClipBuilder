import Testing
@testable import Clip_Builder

struct CaptionAnimationTests {
    @Test func framesAreMonotonicAndEndAtIdentity() {
        for style in ["pop", "slide-up", "fade"] {
            for duration in [0.001, 0.08, 0.16, 0.18] {
                let frames = CaptionAnimation.frames(for: style, duration: duration)
                #expect(frames.first?.at == 0 && frames.last?.at == duration)
                #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.at < $1.at })
                #expect(frames.last?.scale == 1 && frames.last?.offsetY == 0 && frames.last?.alpha == 1)
                #expect(frames.allSatisfy { $0.at <= duration })
            }
        }
    }

    @Test func shortPagesStayWithinTheirWindowAndShareSteadyRaster() throws {
        var style = CaptionStyle()
        style.animation = "pop"
        let page = CaptionOverlayPlan.Page(caption: .init(text: "Hello", start: 2, end: 2.06), position: "bottom")
        let plan = try CaptionOverlayPlan.plan(pages: [page], style: style)
        #expect(plan.overlays.first?.start == 2 && plan.overlays.last?.end == 2.06)
        #expect(plan.overlays.allSatisfy { $0.end <= 2.06 && $0.end > $0.start })
        #expect(zip(plan.overlays, plan.overlays.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    @Test func noneAndInvalidDurationsAreSteady() {
        #expect(CaptionAnimation.frames(for: "none", duration: 1) == [.init()])
        #expect(CaptionAnimation.frames(for: "pop", duration: 0) == [.init()])
        #expect(CaptionAnimation.frames(for: "fade", duration: .nan) == [.init()])
    }
}
