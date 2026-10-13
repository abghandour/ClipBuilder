import CoreGraphics
import Testing
@testable import Clip_Builder

@Suite("Avatar crop")
struct AvatarCropTests {
    @Test func faceCropZoomsOnTheFaceAndStaysInsideTheImage() {
        // A small face near the top-left of a 1000×600 frame.
        let face = CGRect(x: 0.05, y: 0.8, width: 0.05, height: 0.1)
        let rect = AvatarCrop.rect(imageSize: CGSize(width: 1000, height: 600), faceBox: face)
        #expect(rect.width == 132 && rect.height == 132)
        #expect(rect.minX >= 0 && rect.minY >= 0)
        // Face centre (75, 90) lies inside the crop, slightly above its middle.
        #expect(rect.contains(CGPoint(x: 75, y: 90)))
        #expect(rect.midY > 90)
    }

    @Test func faceCropIsCappedByTheImage() {
        let rect = AvatarCrop.rect(imageSize: CGSize(width: 300, height: 400),
                                   faceBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        #expect(rect.width == 300 && rect.minX == 0)
    }

    @Test func noFaceCropsTheCentreOfAPlainImage() {
        let centered = AvatarCrop.rect(imageSize: CGSize(width: 200, height: 600), faceBox: nil)
        #expect(centered == CGRect(x: 0, y: 200, width: 200, height: 200))
    }

    @Test func noFaceInABodyBoxCropsTheHeadZoneNotTheTorso() {
        // A standing fighter's box on a 720×1280 frame: x 0–0.3, y 0.36–0.81.
        let marker = PersonMarker(id: 1, videoID: 1, atTime: 0, x: 0, y: 0.36, width: 0.3, height: 0.45)
        let rect = AvatarCrop.headRect(imageSize: CGSize(width: 720, height: 1280), marker: marker)
        // Square of 90% of the box width (wider than a third of its
        // height here), centred on the box horizontally and near its top.
        #expect(abs(rect.width - 194.4) < 0.01)
        #expect(abs(rect.minX - 10.8) < 0.01)
        let headCenterY = (0.36 + 0.45 * 0.16) * 1280
        #expect(abs(rect.midY - headCenterY) < 0.01)
        #expect(rect.minY > 0.36 * 1280 - rect.height / 2 && rect.maxY < 0.81 * 1280)
        // Never leaves the image.
        let edge = AvatarCrop.headRect(imageSize: CGSize(width: 720, height: 1280),
                                       marker: PersonMarker(id: 1, videoID: 1, atTime: 0, x: 0.9, y: 0, width: 0.3, height: 0.2))
        #expect(edge.maxX <= 720 && edge.minY >= 0)
    }

    @Test func picksTheLargestFaceInsideTheMarker() {
        // Marker covers the left half of the frame (top-left normalized).
        let marker = PersonMarker(id: 1, videoID: 1, atTime: 0, x: 0.05, y: 0.1, width: 0.4, height: 0.8)
        let inside = CGRect(x: 0.2, y: 0.6, width: 0.05, height: 0.08)
        let insideSmall = CGRect(x: 0.3, y: 0.5, width: 0.03, height: 0.05)
        let outside = CGRect(x: 0.7, y: 0.6, width: 0.2, height: 0.3)
        #expect(AvatarCrop.face(among: [outside, insideSmall, inside], inside: marker) == inside)
        #expect(AvatarCrop.face(among: [outside], inside: marker) == nil)
    }
}
