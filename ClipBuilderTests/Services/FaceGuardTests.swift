import CoreGraphics
import Testing
@testable import Clip_Builder

struct FaceGuardTests {
    @Test func rightEdgeFaceMovesCropAndKeepsMargin() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let face = CGRect(x: 1740, y: 180, width: 150, height: 200)
        let crop = CGRect(x: 1300, y: 0, width: 540, height: 960)
        let result = FaceGuard.contain(crop, faces: [face], bounds: bounds)
        #expect(result.contains(face.insetBy(dx: -18, dy: -24)))
        #expect(bounds.contains(result))
        #expect(abs(result.width / result.height - 9.0 / 16) < 1e-9)
    }

    @Test func tallerFacePullsBackToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let face = CGRect(x: 800, y: 50, width: 300, height: 1000)
        let result = FaceGuard.contain(CGRect(x: 850, y: 350, width: 225, height: 400), faces: [face], bounds: bounds)
        #expect(result.height == bounds.height)
        #expect(result.contains(face))
        #expect(bounds.contains(result))
    }

    @Test func separatedFacesGrowCrop() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let faces = [CGRect(x: 700, y: 300, width: 100, height: 120), CGRect(x: 1050, y: 300, width: 100, height: 120)]
        let crop = CGRect(x: 700, y: 200, width: 225, height: 400)
        let result = FaceGuard.contain(crop, faces: faces, bounds: bounds)
        #expect(result.width > crop.width)
        #expect(faces.allSatisfy { result.contains($0.insetBy(dx: -12, dy: -14.4)) })
    }

    @Test func containedFaceDoesNotMoveCrop() {
        let crop = CGRect(x: 500, y: 100, width: 450, height: 800)
        let face = CGRect(x: 650, y: 300, width: 100, height: 120)
        #expect(FaceGuard.contain(crop, faces: [face], bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)) == crop)
        #expect(FaceGuard.contain(crop, faces: [], bounds: crop) == crop)
    }
}
