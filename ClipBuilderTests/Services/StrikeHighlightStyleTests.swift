import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Strike highlight styles")
struct StrikeHighlightStyleTests {
    private func highlight(contour: Bool) -> StrikeHighlightRules.Highlight {
        .init(limb: [CGPoint(x: 0.2, y: 0.25), CGPoint(x: 0.55, y: 0.25)],
            target: CGPoint(x: 0.8, y: 0.7), radius: 0.04, cost: 0,
            limbSide: .left, usesArm: true, attackerOnLeft: true,
            contour: contour ? [CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.6, y: 0.15),
                                CGPoint(x: 0.6, y: 0.35), CGPoint(x: 0.15, y: 0.35)] : nil)
    }

    private func pixels(style: String, contour: Bool, topLeft: Bool) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
            bytesPerRow: 1024, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 256, height: 256))
        if topLeft {
            context.translateBy(x: 0, y: 256)
            context.scaleBy(x: 1, y: -1)
        }
        StrikeHighlightPainter.draw(highlight(contour: contour), opacity: 1, in: context,
            rect: CGRect(x: 0, y: 0, width: 256, height: 256), topLeftOrigin: topLeft, style: style)
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: 256 * 256 * 4))
    }

    /// Bitmap rows are top first, as are the highlight's normalized coordinates.
    private func pixel(_ bytes: [UInt8], x: Int, y: Int) -> [UInt8] {
        let index = (y * 256 + x) * 4
        return Array(bytes[index..<(index + 4)])
    }

    @Test("HD outline is green and solid is red, with the same impact ring", arguments: [false, true])
    func contourPixelStyles(topLeft: Bool) throws {
        let outline = try pixels(style: "outline", contour: true, topLeft: topLeft)
        let solid = try pixels(style: "solid", contour: true, topLeft: topLeft)
        let green = pixel(outline, x: 90, y: 64), red = pixel(solid, x: 90, y: 64)
        #expect(green[1] > green[0] * 2 && green[1] > green[2])
        #expect(red[0] > red[1] * 2 && red[0] > red[2] * 2)
        #expect(red[3] >= 190 && red[3] > green[3])
        #expect(pixel(solid, x: 90, y: 192)[3] == 0)
        let impactOutline = pixel(outline, x: 214, y: 179)
        let impactSolid = pixel(solid, x: 214, y: 179)
        #expect(impactOutline == impactSolid)
        #expect(impactSolid[0] > impactSolid[1] && impactSolid[3] > 0)
        #expect(pixel(outline, x: 5, y: 5)[3] == 0)
    }

    @Test("A highlight without an HD contour keeps the green band in either style", arguments: [false, true])
    func plainBandFallback(topLeft: Bool) throws {
        let outline = try pixels(style: "outline", contour: false, topLeft: topLeft)
        let solid = try pixels(style: "solid", contour: false, topLeft: topLeft)
        #expect(outline == solid)
        let band = pixel(solid, x: 90, y: 64)
        #expect(band[1] > band[0] && band[1] > band[2] && band[3] > 0)
    }

    @Test("Timeline style survives Codable and participates in equality; old clips remain outline")
    func timelineStyleRoundTrip() throws {
        var clip = Fixtures.timelineClip()
        clip.strikeHighlights = true
        let oldJSON = try JSONEncoder().encode(clip)
        let legacy = try JSONDecoder().decode(TimelineClip.self, from: oldJSON)
        #expect(legacy.strikeHighlightStyle == nil)
        clip.strikeHighlightStyle = "solid"
        let roundTrip = try JSONDecoder().decode(TimelineClip.self, from: JSONEncoder().encode(clip))
        #expect(roundTrip.strikeHighlightStyle == "solid")
        var other = roundTrip
        other.strikeHighlightStyle = nil
        #expect(other != roundTrip)
        var document = TimelineDocument()
        document.videoTrack = [clip]
        WizardStrikeHighlights.apply(to: &document, enabled: true, style: "solid",
            sourceTypes: [clip.videoFile ?? "": .fight])
        // Use an explicit whole-file source, independent of fixture scene lookups.
        document.videoTrack[0].videoFile = "/private/tmp/style-source.mov"
        document.videoTrack[0].sceneID = nil
        WizardStrikeHighlights.apply(to: &document, enabled: true, style: "solid",
            sourceTypes: ["/private/tmp/style-source.mov": .fight])
        #expect(document.videoTrack[0].strikeHighlightStyle == "solid")
        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [])
        #expect(resolved.first?.strikeHighlightStyle == "solid")
    }

    private func resolved() -> MultitrackRenderer.ResolvedClip {
        var clip = MultitrackRenderer.ResolvedClip(sourcePath: "/private/tmp/style-source.mov", videoID: 1,
            sourceStart: 0, startTime: 0, duration: 3, track: 0, wide: false, muted: false,
            transIn: nil, transOut: nil, effectivePosition: "center", effectiveCropXFrac: nil,
            freeCrops: nil, screenCrop: nil, areaWindow: nil, captionsPosition: nil)
        clip.framingIdentity = "style-fixture"
        clip.strikeHighlights = true
        clip.strikeTracks = [.init(keyframes: [.init(time: 1, highlight: highlight(contour: true))],
            contact: 1, aspect: 1, contourVersion: StrikeHighlightRules.contourVersion)]
        return clip
    }

    @Test("Segment styles key differently; nil has exactly the old property-absent key")
    func segmentStyleKeys() throws {
        var input = RenderSegmentKey(start: 0, duration: 3, clips: [resolved()], captions: [], overlays: [],
            masks: [:], fontFingerprints: [], captionStyle: CaptionStyle(), settings: RenderSettings(), encoder: [])
        let legacyKey = try RenderSegmentCache.key(input)
        // With no style the property is not encoded at all, so the key is
        // what it was before the property existed.
        let encoded = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        #expect(!encoded.contains("strikeHighlightStyle"))
        input.clips[0].strikeHighlightStyle = "outline"
        let outline = try RenderSegmentCache.key(input)
        input.clips[0].strikeHighlightStyle = "solid"
        #expect(try RenderSegmentCache.key(input) != outline)
        #expect(try RenderSegmentCache.key(input) != legacyKey)
    }

    /// The pre-4a-2 input has no style property. Keep it independent of the new encoder.
    private nonisolated struct LegacyPrepass: Encodable {
        var source: String
        var fingerprint: String
        var start: Double
        var duration: Double
        var hold: Bool
        var path: [CameraPathKeyframe]?
        var area: ScreenCropArea?
        var region: FreeCropRect?
        var focus: AreaFocus?
        var framingPlan: FramingPlan?
        var contentWindow: FreeCropRect?
        var tuning: String
        var settings: RenderSettings
        var encoder: [String]
        var rendererVersion = RenderSegmentCache.rendererVersion
        var strikeTracks: [StrikeHighlightRules.Track]?
        var strikeBurn: Int?
    }

    @Test("Framing keys distinguish styles and preserve nil's old input key")
    func prepassStyleKeys() throws {
        var clip = resolved()
        let settings = RenderSettings()
        let old = LegacyPrepass(source: "style-fixture", fingerprint: "style-fixture", start: 0, duration: 3,
            hold: false, tuning: "fixture", settings: settings, encoder: [], strikeTracks: clip.strikeTracks,
            strikeBurn: StrikeHighlightBurn.version)
        let legacy = try RenderSegmentCache.key(old, version: MultitrackRenderer.framingVersion)
        #expect(try MultitrackRenderer.prepassKey(clip, area: nil, tuning: "fixture", settings: settings, encoder: []) == legacy)
        clip.strikeHighlightStyle = "outline"
        let outline = try MultitrackRenderer.prepassKey(clip, area: nil, tuning: "fixture", settings: settings, encoder: [])
        clip.strikeHighlightStyle = "solid"
        let solid = try MultitrackRenderer.prepassKey(clip, area: nil, tuning: "fixture", settings: settings, encoder: [])
        #expect(solid != outline && solid != legacy)
    }
}
