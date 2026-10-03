import CoreGraphics
import Testing
@testable import Clip_Builder

@Suite("Area framer fallback")
struct AreaFramerTests {
    @Test("a portrait fallback in a landscape feed centers on the known face")
    func knownFace() {
        let window = AreaFramer.fallbackWindow(aspect: 9.0 / 16.0,
            sourceSize: CGSize(width: 1920, height: 1080), center: (x: 0.37, y: 0.4))
        #expect(window.xFrac >= 0)
        #expect(window.xFrac <= 0.37 && window.xFrac + window.wFrac >= 0.37)
        #expect(abs(window.xFrac + window.wFrac / 2 - 0.37) < 1e-9)
        #expect(abs(window.wFrac - 81.0 / 256.0) < 1e-9)
        #expect(window.yFrac == 0 && window.hFrac == 1)
    }

    @Test("faces near either horizontal edge keep the window inside the feed", arguments: [0.01, 0.99])
    func edgeFace(x: Double) {
        let window = AreaFramer.fallbackWindow(aspect: 9.0 / 16.0,
            sourceSize: CGSize(width: 1920, height: 1080), center: (x: x, y: 0.5))
        #expect(window.xFrac >= 0 && window.xFrac + window.wFrac <= 1)
        #expect(window.xFrac <= x && window.xFrac + window.wFrac >= x)
        let expectedLeft = x < 0.5 ? 0 : 1 - window.wFrac
        #expect(abs(window.xFrac - expectedLeft) < 1e-9)
    }

    @Test("a wide fallback also clamps vertically", arguments: [0.01, 0.99])
    func verticalEdgeFace(y: Double) {
        let window = AreaFramer.fallbackWindow(aspect: 16.0 / 9.0,
            sourceSize: CGSize(width: 1080, height: 1920), center: (x: 0.5, y: y))
        #expect(window.xFrac == 0 && window.wFrac == 1)
        #expect(window.yFrac >= 0 && window.yFrac + window.hFrac <= 1)
        #expect(window.yFrac <= y && window.yFrac + window.hFrac >= y)
        let expectedTop = y < 0.5 ? 0 : 1 - window.hFrac
        #expect(abs(window.yFrac - expectedTop) < 1e-9)
    }

    @Test("without a face the fallback matches the original centered window")
    func unknownFace() {
        let window = AreaFramer.fallbackWindow(aspect: 9.0 / 16.0,
            sourceSize: CGSize(width: 1920, height: 1080), center: nil)
        let width = (9.0 / 16.0) / (1920.0 / 1080.0)
        #expect(window == FreeCropRect(xFrac: (1 - width) / 2, yFrac: 0, wFrac: width, hFrac: 1))
    }
}
