import CoreGraphics
import Testing
@testable import Clip_Builder

@Suite("Center Stage face fallback")
struct CenterStageFaceFallbackTests {
    @Test("a centered face expands to head-and-shoulders framing")
    func centeredFace() {
        let face = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.15)
        let body = CenterStageService.bodyEstimate(fromFace: face)

        #expect(body.contains(face))
        #expect(abs(body.midX - face.midX) < 1e-9)
        #expect(abs(body.width - face.width * 2.6) < 1e-9)
        #expect(abs(body.height - face.height * 3.2) < 1e-9)
        #expect(abs(body.minY - (face.minY - face.height * 0.35)) < 1e-9)
        #expect(body.maxY - face.maxY > face.minY - body.minY)
        #expect(body.minX >= 0 && body.maxX <= 1)
        #expect(body.minY >= 0 && body.maxY <= 1)
    }

    @Test("a face at the top edge clips the estimate without shifting it down")
    func topEdgeFace() {
        let face = CGRect(x: 0.4, y: 0, width: 0.2, height: 0.15)
        let body = CenterStageService.bodyEstimate(fromFace: face)
        let expectedBottom = face.minY - face.height * 0.35 + face.height * 3.2

        #expect(body.contains(face))
        #expect(body.minY == 0)
        #expect(body.height < face.height * 3.2)
        #expect(abs(body.height - expectedBottom) < 1e-9)
        #expect(body.maxY <= 1)
    }

    @Test("a face at the right edge clips the estimate without shifting it left")
    func rightEdgeFace() {
        let face = CGRect(x: 0.8, y: 0.3, width: 0.2, height: 0.15)
        let body = CenterStageService.bodyEstimate(fromFace: face)
        let expectedLeft = face.midX - face.width * 2.6 / 2

        #expect(body.contains(face))
        #expect(abs(body.maxX - 1) < 1e-9)
        #expect(abs(body.minX - expectedLeft) < 1e-9)
        #expect(body.width < face.width * 2.6)
        #expect(body.minX >= 0 && body.maxX <= 1)
    }
}
