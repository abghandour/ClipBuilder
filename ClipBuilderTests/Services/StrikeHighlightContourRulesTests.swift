import CoreGraphics
import Foundation
import Testing

@testable import Clip_Builder

@Suite("HD strike highlight contours")
struct StrikeHighlightContourRulesTests {
    private typealias Rules = StrikeHighlightContourRules

    private func highlight(contour: [CGPoint]? = nil) -> StrikeHighlightRules.Highlight {
        .init(limb: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5)],
              target: CGPoint(x: 0.9, y: 0.9), radius: 0.05, cost: 0.2, limbSide: .right,
              usesArm: true, attackerOnLeft: true, contour: contour)
    }

    private func bitmap(_ rows: [String]) -> Rules.Bitmap {
        .init(width: rows[0].count, height: rows.count, pixels: rows.flatMap { $0.map { $0 == "#" } })
    }

    private var rectangle: [CGPoint] {
        [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.2, y: 0.8)]
    }

    @Test("The area follows the limb's own width: tapering, wider over the hand or foot, and a leg starts below the hip")
    func capsuleGeometry() {
        let limb = highlight()
        let extended = Rules.extendedLimb(limb.limb)
        #expect(abs((extended.last?.x ?? 0) - 0.72) < 0.000001)
        // An arm 0.4 long: 0.04 wide at the shoulder, 0.034 at the wrist, 0.048 over the fist.
        let arm = Rules.capsule(limb, aspect: 1, width: 100, height: 100)
        #expect(arm.contains(CGPoint(x: 0.17, y: 0.5)))
        #expect(arm.contains(CGPoint(x: 0.3, y: 0.52)) && !arm.contains(CGPoint(x: 0.3, y: 0.54)))
        #expect(arm.contains(CGPoint(x: 0.58, y: 0.52)) && !arm.contains(CGPoint(x: 0.58, y: 0.55)))
        #expect(arm.contains(CGPoint(x: 0.68, y: 0.53)) && arm.contains(CGPoint(x: 0.74, y: 0.5)))
        #expect(!arm.contains(CGPoint(x: 0.79, y: 0.5)))
        // A leg is thicker, and its first quarter (the hip, where both legs meet) is left out.
        var leg = limb
        leg.usesArm = false
        let area = Rules.capsule(leg, aspect: 1, width: 100, height: 100)
        #expect(area.contains(CGPoint(x: 0.3, y: 0.54)) && !area.contains(CGPoint(x: 0.16, y: 0.5)))
        // Never the old blanket: nothing a limb's length to the side of it.
        #expect(!area.contains(CGPoint(x: 0.4, y: 0.58)))
    }

    @Test("Only what is joined to the limb's line is kept, even when another body part in the area is larger")
    func joinedToTheLimb() {
        // The limb's line runs along the top row; a bigger blob sits apart below it.
        let rows = ["####......", "..........", "#########.", "#########."]
        let region = Rules.region(bitmap(rows), along: [CGPoint(x: 0.05, y: 0.1), CGPoint(x: 0.35, y: 0.1)])
        #expect(region.pixels.count { $0 } == 4 && region.contains(x: 0, y: 0) && !region.contains(x: 0, y: 2))
        // No part of the line on the mask: fall back to the largest piece.
        #expect(Rules.region(bitmap(rows), along: [CGPoint(x: 0.95, y: 0.1), CGPoint(x: 0.97, y: 0.1)]).contains(x: 0, y: 2))
    }

    @Test("A rectangle traces four simplified corners in clockwise order")
    func rectangleBoundary() {
        let boundary = Rules.boundary(bitmap(["......", ".####.", ".####.", "......"]))
        #expect(boundary.count == 4)
        #expect(abs(Rules.signedArea(boundary) - 1.0 / 3) < 0.000001)
        #expect(boundary.contains(CGPoint(x: 1.0 / 6, y: 0.25)))
    }

    @Test("An L remains concave instead of becoming a convex hull")
    func concaveBoundary() {
        let boundary = Rules.boundary(bitmap(["#...", "#...", "###.", "...."]))
        #expect(boundary.count == 6)
        #expect(abs(Rules.signedArea(boundary) - 5.0 / 16) < 0.000001)
        #expect(boundary.contains(CGPoint(x: 0.25, y: 0.5)))
    }

    @Test("Only the larger of two disconnected blobs survives")
    func largestBlob() {
        let region = Rules.largestRegion(bitmap(["##...#", "##....", "......"]))
        #expect(region.pixels.count { $0 } == 4)
        #expect(!region.contains(x: 5, y: 0))
        #expect(Rules.boundary(region).count == 4)
    }

    @Test("Holes do not replace the outer boundary, including frame-edge pixels")
    func boundaryHoles() {
        let boundary = Rules.boundary(bitmap(["####", "#..#", "#..#", "####"]))
        #expect(boundary.count == 4)
        #expect(abs(Rules.signedArea(boundary) - 1) < 0.000001)
        #expect(Rules.boundary(bitmap(["....", "...."])).isEmpty)
    }

    @Test("Resampling is 48 points, clockwise, starts nearest the first joint, and is evenly spaced")
    func contourResampling() throws {
        let points = try #require(Rules.resample(Array(rectangle.reversed()), nearest: CGPoint(x: 0.2, y: 0.5), aspect: 1))
        #expect(points.count == StrikeHighlightRules.contourPoints)
        #expect(points.first == CGPoint(x: 0.2, y: 0.5))
        #expect(Rules.signedArea(points) > 0)
        #expect(points[1].y < points[0].y)
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            #expect(abs(hypot(next.x - points[index].x, next.y - points[index].y) - 0.05) < 0.000001)
        }
    }

    @Test("Masks are chosen by coverage along the limb")
    func instanceSelection() {
        let wrong = bitmap(["####", "....", "....", "...."])
        let right = bitmap(["....", "....", "####", "...."])
        #expect(Rules.bestMask([wrong, right], limb: highlight().limb) == right)
        #expect(Rules.bestMask([], limb: highlight().limb) == nil)
    }

    @Test("The area gates include 15 and 95 percent and reject empty capsules")
    func areaThresholds() {
        #expect(!Rules.acceptableArea(region: 14, capsule: 100))
        #expect(Rules.acceptableArea(region: 15, capsule: 100))
        #expect(Rules.acceptableArea(region: 95, capsule: 100))
        #expect(!Rules.acceptableArea(region: 96, capsule: 100))
        #expect(!Rules.acceptableArea(region: 0, capsule: 0))
    }

    @Test("Sixty percent is required within the contact window, independent of outside frames")
    func contactCoverage() {
        let contour = Array(repeating: CGPoint(x: 0.3, y: 0.4), count: 48)
        var track = StrikeHighlightRules.Track(keyframes: (0..<10).map { index in
            .init(time: 0.7 + Double(index) * 0.05, highlight: highlight(contour: index < 6 ? contour : nil))
        }, contact: 1, aspect: 1)
        #expect(Rules.enoughContours(track))
        track.keyframes[5].highlight.contour = nil
        track.keyframes.append(.init(time: 1.2, highlight: highlight(contour: contour)))
        #expect(!Rules.enoughContours(track))
        track.keyframes = []
        #expect(!Rules.enoughContours(track))
    }

    @Test("Dense times preserve endpoints and cap high frame rates at 30")
    func denseFrameTimes() {
        let times = Rules.frameTimes(start: 1, end: 1.5, frameRate: 60)
        #expect(times.count == 16)
        #expect(times.first == 1 && times.last == 1.5)
        #expect(Rules.frameTimes(start: 1, end: 1.5, frameRate: 24).count == 13)
        #expect(Rules.frameTimes(start: 1.01, end: 1.49, frameRate: 30).last == 1.49)
    }

    @Test("Contours interpolate only when both neighbours have one; exact keyframes retain their own")
    func contourInterpolation() throws {
        let a = try #require(Rules.resample(rectangle, nearest: CGPoint(x: 0.2, y: 0.5), aspect: 1))
        let b = a.map { CGPoint(x: $0.x + 0.1, y: $0.y + 0.1) }
        var track = StrikeHighlightRules.Track(keyframes: [
            .init(time: 1, highlight: highlight(contour: a)), .init(time: 1.1, highlight: highlight(contour: b)),
            .init(time: 1.2, highlight: highlight(contour: a)),
        ], contact: 1.1, aspect: 1, contourVersion: StrikeHighlightRules.contourVersion)
        let middle = try #require(StrikeHighlightRules.sample(track, at: 1.05)?.highlight.contour)
        #expect(abs(middle[0].x - a[0].x - 0.05) < 0.000001)
        track.keyframes[0].highlight.contour = nil
        #expect(StrikeHighlightRules.sample(track, at: 1.05)?.highlight.contour == nil)
        #expect(StrikeHighlightRules.sample(track, at: 1.1)?.highlight.contour == b)
        track.keyframes[0].highlight.contour = a
        track.keyframes[1].highlight.contour = nil
        #expect(StrikeHighlightRules.sample(track, at: 1.05)?.highlight.contour == nil)
    }

    @Test("Legacy JSON with no contour still decodes as a plain track")
    func legacyTrackDecoding() throws {
        let json = #"{"keyframes":[{"time":1,"highlight":{"limb":[[0.2,0.5],[0.6,0.5]],"target":[0.9,0.9],"radius":0.05,"cost":0.2,"limbSide":"right","usesArm":true,"attackerOnLeft":true}}],"contact":1,"aspect":1.7777777778}"#
        let decoded = try JSONDecoder().decode(StrikeHighlightRules.Track.self, from: Data(json.utf8))
        #expect(decoded.keyframes.count == 1)
        #expect(decoded.keyframes[0].highlight.contour == nil)
        #expect(!decoded.isHD)
    }

    @Test("Drawable identity and JSON round-trip retain HD contours")
    func drawableContour() throws {
        let contour = try #require(Rules.resample(rectangle, nearest: .zero, aspect: 1))
        var track = StrikeHighlightRules.Track(keyframes: [.init(time: 1, highlight: highlight(contour: contour))], contact: 1, aspect: 1)
        // Outlines found by older rules are not HD and are not drawn: HD is made again.
        #expect(!track.isHD && StrikeHighlightRules.sample(track, at: 1)?.highlight.contour == nil)
        #expect(StrikeHighlightRules.drawable(track).keyframes[0].highlight.contour == nil)
        track.contourVersion = StrikeHighlightRules.contourVersion
        #expect(track.isHD)
        #expect(StrikeHighlightRules.drawable(track).keyframes[0].highlight.contour == contour)
        #expect(try JSONDecoder().decode(StrikeHighlightRules.Track.self, from: JSONEncoder().encode(track)) == track)
    }

    @Test("Mask intersection produces an outline and rejects a mask filling the whole capsule")
    func maskIntersection() throws {
        let width = 100, height = 100
        var pixels = [Bool](repeating: false, count: width * height)
        for y in 47..<53 { for x in 18..<74 { pixels[y * width + x] = true } }
        let contour = try #require(Rules.contour(mask: .init(width: width, height: height, pixels: pixels), highlight: highlight(), aspect: 1))
        #expect(contour.count == 48)
        #expect(contour.allSatisfy { $0.y >= 0.47 && $0.y <= 0.53 })
        let full = Rules.Bitmap(width: width, height: height, pixels: Array(repeating: true, count: width * height))
        #expect(Rules.contour(mask: full, highlight: highlight(), aspect: 1) == nil)
    }

    @Test("Painter fills the HD polygon without drawing the old band, in both coordinate systems")
    func polygonPainter() throws {
        let polygon = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.4, y: 0.2), CGPoint(x: 0.4, y: 0.3), CGPoint(x: 0.2, y: 0.3)]
        for topLeft in [true, false] {
            let context = try #require(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            if topLeft {
                context.translateBy(x: 0, y: 200)
                context.scaleBy(x: 1, y: -1)
            }
            StrikeHighlightPainter.draw(highlight(contour: polygon), opacity: 1, in: context,
                                        rect: CGRect(x: 0, y: 0, width: 200, height: 200), topLeftOrigin: topLeft)
            let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            #expect(data[(50 * 200 + 60) * 4 + 1] > 50)
            #expect(data[(100 * 200 + 100) * 4 + 3] == 0)
        }
    }

    @Test("An outline whose start jumped to another edge is turned back to match the frame before")
    func alignment() throws {
        let before = try #require(Rules.resample(rectangle, nearest: CGPoint(x: 0.2, y: 0.5), aspect: 1))
        let moved = rectangle.map { CGPoint(x: $0.x + 0.01, y: $0.y) }
        // The same shape a hair to the right, but started from the opposite edge.
        let jumped = try #require(Rules.resample(moved, nearest: CGPoint(x: 0.8, y: 0.5), aspect: 1))
        #expect(abs(jumped[0].x - before[0].x) > 0.5)
        let turned = Rules.aligned(jumped, to: before, aspect: 1)
        #expect(zip(turned, before).allSatisfy { abs($0.x - $1.x - 0.01) < 0.0001 && abs($0.y - $1.y) < 0.0001 })
        #expect(Set(turned.map { "\($0.x),\($0.y)" }) == Set(jumped.map { "\($0.x),\($0.y)" }))
        #expect(Rules.aligned(jumped, to: nil, aspect: 1) == jumped)
    }

    @Test("Scanning only the limb's box gives the same area as scanning the whole frame")
    func capsuleBox() {
        let area = Rules.capsule(highlight(), aspect: 16.0 / 9, width: 96, height: 54)
        let marked = area.pixels.indices.filter { area.pixels[$0] }
        #expect(!marked.isEmpty)
        // Every marked pixel has an unmarked ring of the box around the area.
        let xs = marked.map { $0 % 96 }, ys = marked.map { $0 / 96 }
        #expect(xs.min()! > 0 && xs.max()! < 95 && ys.min()! > 0 && ys.max()! < 53)
        #expect(area.contains(CGPoint(x: 0.4, y: 0.5)) && !area.contains(CGPoint(x: 0.4, y: 0.9)))
    }
}
