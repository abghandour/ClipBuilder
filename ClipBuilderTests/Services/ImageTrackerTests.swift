import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Image face tracking")
struct ImageTrackerTests {
    private let seed = CGRect(x: 0.4, y: 0.3, width: 0.1, height: 0.2)

    @Test func nearestFaceRejectsDistanceAndSizeChanges() {
        let near = seed.offsetBy(dx: 0.02, dy: 0.01)
        let far = seed.offsetBy(dx: 0.3, dy: 0)
        let huge = CGRect(x: 0.3, y: 0.1, width: 0.3, height: 0.6)
        #expect(ImageTracker.nearestFace([far, huge, near], to: seed) == near)
        #expect(ImageTracker.nearestFace([far, huge], to: seed) == nil)
        #expect(ImageTracker.nearestFace([], to: seed) == nil)
    }

    @Test func missesHoldAndThreeConsecutiveMissesStop() {
        var state = ImageTracker.FollowState(face: seed)
        state = ImageTracker.advance(state, faces: [])
        #expect(state.face == seed && state.misses == 1 && !state.ended)
        state = ImageTracker.advance(state, faces: [seed.offsetBy(dx: 0.02, dy: 0)])
        #expect(state.misses == 0)
        let held = state.face
        for _ in 0..<3 { state = ImageTracker.advance(state, faces: []) }
        #expect(state.ended && state.face == held)
        #expect(ImageTracker.advance(state, faces: [seed]).face == held)
        #expect(ImageTracker.advance(state, faces: [seed]).ended)
    }

    @Test func smoothingPreservesTimesWidthsAndEndpoints() {
        let keys = [key(1, 0.2), key(2, 0.8), key(3, 0.2)]
        let smoothed = ImageTracker.smoothed(keys)
        #expect(smoothed.first == keys.first && smoothed.last == keys.last)
        #expect(abs(smoothed[1].xFrac - 0.4) < 1e-9)
        #expect(smoothed.map(\.time) == [1, 2, 3])
        #expect(smoothed.map(\.wFrac) == keys.map(\.wFrac))
    }

    @Test func interpolationLerpsAndHoldsEndpoints() throws {
        let keys = [key(10, 0.2), key(12, 0.8)]
        let midpoint = try #require(ImageTrackKey.interpolate(keys, at: 11))
        #expect(abs(midpoint.xFrac - 0.5) < 1e-9)
        #expect(midpoint.time == 11)
        #expect(ImageTrackKey.interpolate(keys, at: -1) == keys.first)
        #expect(ImageTrackKey.interpolate(keys, at: 40) == keys.last)
        #expect(ImageTrackKey.interpolate([keys[0]], at: 20) == keys[0])
        #expect(ImageTrackKey.interpolate([], at: 1) == nil)
    }

    @Test func sampleTimesIncludeExactEndpointsOnce() {
        #expect(ImageTracker.times(start: 1, end: 1.6) == [1, 1.25, 1.5, 1.6])
        #expect(ImageTracker.times(start: 1, end: 1.5) == [1, 1.25, 1.5])
        #expect(ImageTracker.times(start: 1, end: 1).isEmpty)
        #expect(ImageTracker.times(start: 0, end: 1, step: 0).isEmpty)
    }

    @Test func placementInverseRoundTripsOffsetCrop() {
        let placement = ImageGeneration.Placement(
            window: FreeCropRect(xFrac: 0.25, yFrac: 0.1, wFrac: 0.5, hFrac: 0.8),
            box: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.4))
        let result = placement.inputRect(placement.outputRect(seed))
        #expect(abs(result.minX - seed.minX) < 1e-9)
        #expect(abs(result.minY - seed.minY) < 1e-9)
        #expect(abs(result.width - seed.width) < 1e-9)
        #expect(abs(result.height - seed.height) < 1e-9)
    }

    @Test func optionalTrackDecodesOldDocumentAndInvalidatesCache() throws {
        var item = ImageOverlayItem(path: "/tmp/image.png")
        let minimal = Data(#"{"path":"/tmp/old.png"}"#.utf8)
        let legacy = try JSONDecoder().decode(ImageOverlayItem.self, from: minimal)
        #expect(legacy.track == nil && !legacy.keepsPlacement && legacy.opacity == 1)
        let old = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(ImageOverlayItem.self, from: old).track == nil)
        let staticKey = try RenderSegmentCache.key(item)
        item.track = [key(0, 0.2), key(3, 0.8)]
        let data = try JSONEncoder().encode(item)
        #expect(String(decoding: data, as: UTF8.self).contains("x_frac"))
        #expect(try JSONDecoder().decode(ImageOverlayItem.self, from: data).track == item.track)
        let firstKey = try RenderSegmentCache.key(item)
        #expect(staticKey != firstKey)
        item.track?[1].xFrac = 0.6
        #expect(try RenderSegmentCache.key(item) != firstKey)
    }

    @Test func expressionsRebaseWithSegmentClock() {
        var overlay = MultitrackRenderer.TimedOverlayPNG(png: URL(fileURLWithPath: "/tmp/test.png"),
            startTime: 10, endTime: 12, transIn: "cut", transOut: "cut", track: [key(10, 0.2), key(12, 0.8)]).positioned()
        #expect(overlay.xExpr?.contains("W*(") == true)
        #expect(overlay.xExpr?.contains("-w/2") == true)
        #expect(overlay.yExpr?.contains("-h/2") == true)
        overlay.shiftTrack(by: -10)
        #expect(overlay.track?.map(\.time) == [0, 2])
        #expect(overlay.xExpr?.contains("clip((t-0.000000)/2.000000,0,1)") == true)
        #expect(overlay.xExpr?.contains("10.000000") == false)
        #expect(AppJobKind.trackImage.shortTitle == "Track Face")
    }

    @Test func finalCacheIncludesMovingPositions() throws {
        let directory = try TempDirectory(prefix: "ImageTrackCache")
        let png = directory.url.appendingPathComponent("overlay.png")
        try Data([1, 2, 3]).write(to: png)
        var overlay = MultitrackRenderer.TimedOverlayPNG(png: png, startTime: 0, endTime: 3,
            transIn: "cut", transOut: "cut", track: [key(0, 0.2), key(3, 0.8)]).positioned()
        let before = try RenderSegmentCache.key(RenderFinishingKey.overlayIdentities([overlay]))
        overlay.track?[1].xFrac = 0.4
        overlay = overlay.positioned()
        #expect(try RenderSegmentCache.key(RenderFinishingKey.overlayIdentities([overlay])) != before)
    }

    @Test func longExpressionsStayShallowAndOutputClockStaysOrdered() {
        let keys = (0..<1000).map { key(Double($0) / 4, $0.isMultiple(of: 2) ? 0.2 : 0.8) }
        let expression = ImageTracker.expression(keys, axis: \.xFrac)
        var depth = 0, maximum = 0
        for character in expression {
            if character == "(" { depth += 1; maximum = max(maximum, depth) }
            if character == ")" { depth -= 1 }
        }
        #expect(depth == 0 && maximum < 20)
        var overlay = MultitrackRenderer.TimedOverlayPNG(png: URL(fileURLWithPath: "/tmp/test.png"),
            startTime: 0, endTime: 3, transIn: "cut", transOut: "cut", track: [key(1.75, 0.2), key(2, 0.4), key(2.5, 0.8)])
        overlay.remapTrack(using: RenderClock(segmentStarts: [0, 2], overlaps: [0: 0.5]))
        #expect(overlay.track?.map(\.time) == [1.5, 1.75, 2])
    }

    private func key(_ time: Double, _ x: Double) -> ImageTrackKey {
        ImageTrackKey(time: time, xFrac: x, yFrac: 0.4, wFrac: 0.2)
    }
}
