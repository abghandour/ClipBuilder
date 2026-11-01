import Foundation
import Testing
@testable import Clip_Builder

/// Pure rules the Builder renderer shares with the Wizard's Generate so an
/// Open in Editor timeline renders like the reel (docs/Open-In-Editor-Plan.md).
@Suite("Wizard Builder parity")
struct WizardBuilderParityTests {
    @Test("word reveal staggers one window per word and holds the full text to the end")
    func wordRevealSteps() {
        let steps = WordRevealSchedule.steps(duration: 6, wordCount: 4)
        // duration / 3 / words = 0.5, capped at 0.3 per word.
        #expect(steps.map(\.visibleWords) == [1, 2, 3, 4])
        #expect(steps.map(\.start).enumerated().allSatisfy { abs($0.element - Double($0.offset) * 0.3) < 1e-9 })
        #expect(abs(steps[2].end - 0.9) < 1e-9 && steps[3].end == 6)
        // Short overlays floor the step at 0.1 s.
        let short = WordRevealSchedule.steps(duration: 0.9, wordCount: 6)
        #expect(abs(short[1].start - 0.1) < 1e-9 && short.last?.end == 0.9)
        // Windows past the end never show; one word does not reveal.
        let tight = WordRevealSchedule.steps(duration: 0.25, wordCount: 5)
        #expect(tight.count == 3 && tight.last?.end == 0.25)
        #expect(WordRevealSchedule.steps(duration: 3, wordCount: 1).isEmpty)
    }

    @Test("word_reveal survives the document round trip and stays absent elsewhere")
    func overlayAnimationRoundTrip() throws {
        var item = TextOverlayItem(text: "Three word hook", startTime: 1, endTime: 4)
        item.animation = WordRevealSchedule.animation
        let decoded = try JSONDecoder().decode(TextOverlayItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.animation == "word_reveal")
        let plain = try JSONEncoder().encode(TextOverlayItem(text: "Plain"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("animation"))
        #expect(try JSONDecoder().decode(TextOverlayItem.self, from: plain).animation == nil)
    }

    @Test("brand layers sit under cutaways for the full Wizard and over all footage otherwise")
    func brandStageOrdering() {
        // Steps bottom first: two main crops, a cutaway, then a track-1 main.
        let steps = [false, false, true, false, true]
        #expect(MultitrackRenderer.brandInsertionIndex(stepIsCutaway: steps, underCutaways: false) == 5)
        #expect(MultitrackRenderer.brandInsertionIndex(stepIsCutaway: steps, underCutaways: true) == 4)
        #expect(MultitrackRenderer.brandInsertionIndex(stepIsCutaway: [false, true], underCutaways: true) == 1)
        #expect(MultitrackRenderer.brandInsertionIndex(stepIsCutaway: [true], underCutaways: true) == 0)
        #expect(MultitrackRenderer.brandInsertionIndex(stepIsCutaway: [], underCutaways: true) == 0)
    }

    @Test("brand spans clip to each segment on its own clock")
    func brandWindows() {
        let spans = [0.0..<4.0, 6.0..<10.0]
        #expect(MultitrackRenderer.brandLayerWindows(spans: spans, segmentStart: 3, segmentEnd: 7) == [0.0..<1.0, 3.0..<4.0])
        #expect(MultitrackRenderer.brandLayerWindows(spans: spans, segmentStart: 4, segmentEnd: 6).isEmpty)
        #expect(MultitrackRenderer.brandLayerWindows(spans: spans, segmentStart: 6, segmentEnd: 8) == [0.0..<2.0])
    }

    @Test("caption cuts join crop splits and pieces of one origin, never separate cuts")
    func captionCutExtent() {
        // One cut split at 2 s by a crop/B-roll boundary, then a new cut.
        var a = clip(start: 0, duration: 2, sourceStart: 10, origin: "cut-1")
        var b = clip(start: 2, duration: 3, sourceStart: 12, origin: "cut-1")
        let c = clip(start: 5, duration: 2, sourceStart: 40, origin: "cut-2")
        var cuts = MultitrackRenderer.captionCuts([c, b, a])
        #expect(cuts.count == 2)
        #expect(cuts[0].start == 0 && cuts[0].end == 5 && cuts[0].sourceStart == 10 && cuts[0].sourceEnd == 15)
        #expect(cuts[1].start == 5 && cuts[1].originKey == "cut-2")
        // A source jump inside one origin, a different origin, or a moved
        // caption position all start a new cut.
        b.sourceStart = 30
        #expect(MultitrackRenderer.captionCuts([a, b]).count == 2)
        b.sourceStart = 12
        a.captionsPosition = "top"
        #expect(MultitrackRenderer.captionCuts([a, b]).count == 2)
        // Without an origin, contiguous source-continuous clips of one video join.
        let x = clip(start: 0, duration: 2, sourceStart: 10, origin: "")
        let y = clip(start: 2, duration: 2, sourceStart: 12, origin: "")
        cuts = MultitrackRenderer.captionCuts([x, y])
        #expect(cuts.count == 1 && cuts[0].end == 4)
        // Cutaways and uncaptioned clips never form cuts.
        var cutaway = clip(start: 1, duration: 1, sourceStart: 0, origin: "broll")
        cutaway.role = .cutaway
        var silent = clip(start: 8, duration: 1, sourceStart: 0, origin: "x")
        silent.captionsPosition = nil
        #expect(MultitrackRenderer.captionCuts([cutaway, silent]).isEmpty)
    }

    @Test("cut caption overlays slice into segments on the segment clock")
    func captionSlices() {
        let overlays = [overlay(0.5, 1.5), overlay(1.5, 2.6), overlay(2.6, 4)]
        let first = MultitrackRenderer.captionOverlays(overlays, segmentStart: 0, segmentEnd: 2)
        #expect(first.map(\.start) == [0.5, 1.5] && first.map(\.end) == [1.5, 2])
        let second = MultitrackRenderer.captionOverlays(overlays, segmentStart: 2, segmentEnd: 5)
        #expect(second.count == 2)
        #expect(second[0].start == 0 && abs(second[0].end - 0.6) < 1e-9)
        #expect(abs(second[1].start - 0.6) < 1e-9 && second[1].end == 2)
    }

    private func clip(start: Double, duration: Double, sourceStart: Double, origin: String) -> MultitrackRenderer.ResolvedClip {
        var clip = MultitrackRenderer.ResolvedClip(
            sourcePath: "/tmp/fixture.mp4", videoID: 1, sourceStart: sourceStart,
            startTime: start, duration: duration, track: 0, wide: false,
            muted: false, transIn: nil, transOut: nil, effectivePosition: "center",
            effectiveCropXFrac: nil, freeCrops: nil, screenCrop: nil,
            areaWindow: nil, captionsPosition: "bottom")
        clip.originKey = origin
        return clip
    }

    private func overlay(_ start: Double, _ end: Double) -> CaptionOverlayPlan.Overlay {
        CaptionOverlayPlan.Overlay(raster: CaptionOverlayPlan.Raster(text: "word"), position: "bottom", start: start, end: end)
    }
}
