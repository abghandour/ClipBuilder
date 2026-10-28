import CoreGraphics
import Testing
@testable import Clip_Builder

@Suite("Preview handle geometry")
nonisolated struct PreviewHandleGeometryTests {
    private let minimum = CGSize(width: 24, height: 12)

    @Test func zoomOutGrowsUniformlyAboutTheCentre() {
        let rect = CGRect(x: 80, y: 90, width: 40, height: 20)
        let result = PreviewHandleGeometry.scaled(rect, by: 2, aspect: nil,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200), minimum: minimum)
        #expect(result == CGRect(x: 60, y: 80, width: 80, height: 40))
        #expect(result.midX == rect.midX && result.midY == rect.midY)
    }

    @Test func zoomOutShiftsTheOriginInsideOffsetSourceBounds() {
        let bounds = CGRect(x: -100, y: -50, width: 300, height: 200)
        let result = PreviewHandleGeometry.scaled(CGRect(x: 100, y: 100, width: 80, height: 40),
            by: 2, aspect: nil, bounds: bounds, minimum: minimum)
        #expect(result == CGRect(x: 40, y: 70, width: 160, height: 80))
        #expect(bounds.contains(result))
    }

    @Test func zoomOutCapsTheSizeAndShiftsBothOrigins() {
        let bounds = CGRect(x: -100, y: -50, width: 300, height: 200)
        let result = PreviewHandleGeometry.scaled(CGRect(x: 100, y: 100, width: 80, height: 40),
            by: 100, aspect: nil, bounds: bounds, minimum: minimum)
        #expect(result == CGRect(x: -100, y: 0, width: 300, height: 150))
        #expect(bounds.contains(result))
    }

    @Test func zoomInHonoursBothMinimumDimensionsWithUniformScaling() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let wide = PreviewHandleGeometry.scaled(CGRect(x: 100, y: 100, width: 100, height: 25),
            by: 0.01, aspect: nil, bounds: bounds, minimum: minimum)
        #expect(wide == CGRect(x: 126, y: 106.5, width: 48, height: 12))
        let tall = PreviewHandleGeometry.scaled(CGRect(x: 100, y: 100, width: 50, height: 100),
            by: 0.01, aspect: nil, bounds: bounds, minimum: minimum)
        #expect(tall == CGRect(x: 113, y: 126, width: 24, height: 48))
    }

    @Test func lockedAspectSurvivesZoomAndEitherSourceLimit() {
        let rect = CGRect(x: 30, y: 30, width: 40, height: 20)
        for bounds in [CGRect(x: 0, y: 0, width: 100, height: 80),
                       CGRect(x: 0, y: 0, width: 200, height: 60)] {
            for factor: CGFloat in [0.01, 1.5, 100] {
                let result = PreviewHandleGeometry.scaled(rect, by: factor, aspect: 0.5, bounds: bounds, minimum: minimum)
                #expect(result.height / result.width == 0.5)
                #expect(result.width >= minimum.width && result.height >= minimum.height)
                #expect(bounds.contains(result))
            }
        }
    }

    @Test func sourceBoundsWinWhenSmallerThanTheMinimum() {
        let bounds = CGRect(x: -5, y: 10, width: 10, height: 5)
        let result = PreviewHandleGeometry.scaled(bounds, by: 0.1, aspect: 0.5, bounds: bounds, minimum: minimum)
        #expect(result == bounds)
    }

    @Test func fullCanvasAndOversizedFramesHaveVisibleInsetGrips() {
        let visible = CGRect(x: 20, y: 30, width: 200, height: 100)
        let expected = CGRect(x: 28, y: 38, width: 184, height: 84)
        #expect(PreviewHandleGeometry.insetForDisplay(visible, visible: visible, inset: 8) == expected)
        #expect(PreviewHandleGeometry.insetForDisplay(visible.insetBy(dx: -40, dy: -60), visible: visible, inset: 8) == expected)
    }

    @Test func displayInsetOnlyMovesSidesWithinOnePointOfTheVisibleEdge() {
        let visible = CGRect(x: 20, y: 30, width: 200, height: 100)
        let topLeft = CGRect(x: 20.5, y: 31, width: 100, height: 50)
        #expect(PreviewHandleGeometry.insetForDisplay(topLeft, visible: visible, inset: 8)
            == CGRect(x: 28, y: 38, width: 92.5, height: 43))
        let bottomRight = CGRect(x: 80, y: 60, width: 139, height: 69.5)
        #expect(PreviewHandleGeometry.insetForDisplay(bottomRight, visible: visible, inset: 8)
            == CGRect(x: 80, y: 60, width: 132, height: 62))
        let interior = visible.insetBy(dx: 2, dy: 2)
        #expect(PreviewHandleGeometry.insetForDisplay(interior, visible: visible, inset: 8) == interior)
    }

    @Test func displayInsetDoesNotChangeTrueGeometryUsedForZoom() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let displayed = PreviewHandleGeometry.insetForDisplay(rect, visible: rect, inset: 8)
        let scaled = PreviewHandleGeometry.scaled(rect, by: 2, aspect: nil,
            bounds: CGRect(x: -100, y: -50, width: 400, height: 200), minimum: minimum)
        #expect(displayed == CGRect(x: 8, y: 8, width: 184, height: 84))
        #expect(scaled == CGRect(x: -100, y: -50, width: 400, height: 200))
    }
}
