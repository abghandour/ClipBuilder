import CoreGraphics
import Testing
@testable import Clip_Builder

struct PortraitBoxParsingTests {
    @Test func pixelCoordinatesAreNormalisedBeforeClamping() {
        let parsed = PortraitBoxParsing.normalise(.init(x: 480, y: 108, w: 192, h: 432), width: 1920, height: 1080)
        #expect(parsed.wasPixels)
        #expect(parsed.box == .init(x: 0.25, y: 0.1, w: 0.1, h: 0.4))
    }

    @Test func anyPixelValueScalesTheWholeBox() {
        let parsed = PortraitBoxParsing.normalise(.init(x: 0.5, y: 0, w: 200, h: 100), width: 1000, height: 500)
        #expect(parsed.wasPixels)
        #expect(parsed.box == .init(x: 0.0005, y: 0, w: 0.2, h: 0.2))
    }

    @Test func normalisedBoxesAndExistingClampLimitsStayUnchanged() {
        let box = VideoPersonRecord.PortraitBox(x: 0.2, y: 0.3, w: 0.1, h: 0.4)
        let parsed = PortraitBoxParsing.normalise(box, width: 1920, height: 1080)
        #expect(!parsed.wasPixels && parsed.box == box)
        let clipped = PortraitBoxParsing.normalise(.init(x: -100, y: 2000, w: 0, h: 4000), width: 1920, height: 1080)
        #expect(clipped.box == .init(x: 0, y: 1, w: 0.02, h: 1))
    }

    @Test func frameSizeFitsTheSourceInsideTheBudgetWithoutUpscaling() {
        let fitted = PortraitBoxParsing.frameSize(width: 1920, height: 1080, longestEdge: 1024)
        #expect(fitted.width == 1024 && fitted.height == 576)
        let tall = PortraitBoxParsing.frameSize(width: 1080, height: 1920, longestEdge: 1024)
        #expect(tall.width == 576 && tall.height == 1024)
        let small = PortraitBoxParsing.frameSize(width: 640, height: 360, longestEdge: 1024)
        #expect(small.width == 640 && small.height == 360)
        #expect(PortraitBoxParsing.frameSize(width: 1920, height: 1080, longestEdge: 0).width == 1920)
    }

    @Test func snappingPairsBoxesAndFacesLeftToRightAndBuildsPortraits() {
        // The model's boxes are at an unknown scale but keep their order.
        let boxes: [(key: String, box: VideoPersonRecord.PortraitBox)] = [
            ("guest", .init(x: 0.25, y: 0.12, w: 0.11, h: 0.8)), ("host", .init(x: 0.14, y: 0.17, w: 0.10, h: 0.75))]
        let hostFace = CGRect(x: 0.34, y: 0.2, width: 0.04, height: 0.1)
        let guestFace = CGRect(x: 0.55, y: 0.18, width: 0.05, height: 0.11)
        let tiny = CGRect(x: 0.8, y: 0.5, width: 0.005, height: 0.01)
        let snapped = PortraitBoxParsing.snapped(boxes: boxes, toFaces: [guestFace, tiny, hostFace])
        #expect(snapped["host"] == PortraitBoxParsing.portrait(around: hostFace))
        #expect(snapped["guest"] == PortraitBoxParsing.portrait(around: guestFace))
        let host = try! #require(snapped["host"])
        #expect(abs(host.x + host.w / 2 - hostFace.midX) < 0.0001 && host.y < hostFace.minY && host.y + host.h > hostFace.maxY)
        #expect(PortraitBoxParsing.snapped(boxes: boxes, toFaces: []).isEmpty)
        #expect(PortraitBoxParsing.snapped(boxes: [], toFaces: [hostFace]).isEmpty)
        // Too few faces, or a lone box: nearest centre wins, and a face is claimed once.
        #expect(Array(PortraitBoxParsing.snapped(boxes: boxes, toFaces: [hostFace]).keys) == ["guest"])
        let single = PortraitBoxParsing.snapped(boxes: [boxes[1]], toFaces: [guestFace, hostFace])
        #expect(single["host"] == PortraitBoxParsing.portrait(around: hostFace))
        let far: [(key: String, box: VideoPersonRecord.PortraitBox)] = [("left", .init(x: 0.05, y: 0.1, w: 0.1, h: 0.5)), ("right", .init(x: 0.7, y: 0.1, w: 0.1, h: 0.5))]
        let shared = PortraitBoxParsing.snapped(boxes: far, toFaces: [guestFace, hostFace, tiny])
        // Two boxes, three faces: the two largest faces pair by order, the tiny one is ignored.
        #expect(shared["left"] == PortraitBoxParsing.portrait(around: hostFace) && shared["right"] == PortraitBoxParsing.portrait(around: guestFace))
        let edge = PortraitBoxParsing.portrait(around: CGRect(x: 0.97, y: 0.0, width: 0.06, height: 0.5))
        #expect(edge.x + edge.w <= 1 && edge.y >= 0 && edge.y + edge.h <= 1)
    }
}
