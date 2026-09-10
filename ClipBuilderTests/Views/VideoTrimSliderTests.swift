import Foundation
import Testing
@testable import Clip_Builder

@MainActor struct VideoTrimSliderTests {
    @Test func handlesNeverCross() {
        let w = VideoTrimSlider.handleWidth
        // A one-pixel selection deep inside a long strip.
        let narrow = VideoTrimSlider.handleLayout(startX: 300, endX: 301, width: 600)
        #expect(narrow.startHandleX + w <= narrow.endHandleX)
        #expect(narrow.frameWidth == w * 2)
        #expect(abs((narrow.frameX + narrow.frameWidth / 2) - 300.5) < 0.001)
        // Wide enough: identity.
        let wide = VideoTrimSlider.handleLayout(startX: 100, endX: 200, width: 600)
        #expect(wide == .init(frameX: 100, frameWidth: 100, startHandleX: 100, endHandleX: 200 - w))
        // Inverted input (a stale binding) is drawn as a valid frame, not crossed.
        let inverted = VideoTrimSlider.handleLayout(startX: 250, endX: 240, width: 600)
        #expect(inverted.startHandleX + w <= inverted.endHandleX)
        // Clamped to the strip at both ends.
        let atStart = VideoTrimSlider.handleLayout(startX: 0, endX: 1, width: 600)
        #expect(atStart.frameX == 0)
        let atEnd = VideoTrimSlider.handleLayout(startX: 599, endX: 600, width: 600)
        #expect(atEnd.frameX + atEnd.frameWidth == 600)
        // Sweep: no combination crosses or leaves the strip.
        for s in stride(from: 0.0, through: 600, by: 37) {
            for e in stride(from: 0.0, through: 600, by: 41) {
                let l = VideoTrimSlider.handleLayout(startX: s, endX: e, width: 600)
                #expect(l.startHandleX + w <= l.endHandleX)
                #expect(l.frameX >= 0 && l.frameX + l.frameWidth <= 600)
            }
        }
    }
}
