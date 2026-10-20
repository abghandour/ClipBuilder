import Testing
@testable import Clip_Builder

struct CaptionOverlayPlanTests {
    @Test func sourceClocksAreStretchedAndClippedBeforeHighlighting() throws {
        var style = CaptionStyle()
        style.highlight = "color"
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
        let segment = TranscriptSegment(start: 10, end: 12, text: "hello world", words: [
            .init(word: "hello", start: 10, end: 10.5), .init(word: "world", start: 11, end: 12)])
        let pages = CaptionOverlayPlan.pages(segments: [segment], renderer: renderer,
            sourceStart: 10.25, speed: 0.5, duration: 3, position: "top")
        let plan = try CaptionOverlayPlan.plan(pages: pages, style: style)
        #expect(plan.overlays.map { $0.raster.activeIndex } == [0, nil, 1])
        #expect(plan.overlays.map(\.start) == [0, 0.5, 1.5])
        #expect(plan.overlays.map(\.end) == [0.5, 1.5, 3])
        #expect(plan.overlays.allSatisfy { $0.position == "top" })
    }

    @Test func emojiDoesNotCreateAnExtraWordState() throws {
        var style = CaptionStyle()
        style.emoji = true
        style.highlight = "color"
        let pages = [CaptionOverlayPlan.Page(caption: .init(text: "More money", start: 0, end: 2), position: "bottom")]
        let plan = try CaptionOverlayPlan.plan(pages: pages, style: style)
        #expect(plan.overlays.count == 2)
        #expect(plan.overlays.map { $0.raster.activeIndex } == [0, 1])
        #expect(plan.overlays.allSatisfy { $0.raster.text == "More money 💰" })
    }

    @Test func inputLimitFallsBackWithoutDroppingWordsOrPlacements() throws {
        var style = CaptionStyle()
        style.highlight = "color"
        style.animation = "pop"
        let pages = (0..<201).map {
            CaptionOverlayPlan.Page(caption: .init(text: "hello world", start: Double($0), end: Double($0 + 1)), position: "bottom")
        }
        let plan = try CaptionOverlayPlan.plan(pages: pages, style: style)
        #expect(plan.usedPageFallback && plan.overlays.count == pages.count)
        #expect(plan.overlays.allSatisfy { $0.raster.activeIndex == nil && $0.raster.frame == .init() })
        let long = (0..<1000).map {
            CaptionOverlayPlan.Page(caption: .init(text: "word\($0)", start: Double($0), end: Double($0 + 1)),
                                    position: $0 < 500 ? "top" : "bottom", streamID: $0 < 500 ? "a" : "b")
        }
        let bounded = try CaptionOverlayPlan.plan(pages: long, style: style)
        #expect(bounded.usedPageFallback && bounded.overlays.count <= CaptionOverlayPlan.inputLimit)
        #expect(bounded.overlays.map { $0.raster.text }.joined(separator: " ") == long.map { $0.caption.text }.joined(separator: " "))
        #expect(Set(bounded.overlays.map(\.position)) == ["top", "bottom"])
    }

    @Test func rasterCacheIncludesColourEmphasisAndFrame() {
        let plain = CaptionOverlayPlan.Raster(text: "hello")
        var active = plain
        active.activeIndex = 0
        var emphasis = plain
        emphasis.emphasis = [0]
        var color = plain
        color.textColor = "#ff0000"
        var frame = plain
        frame.frame.scale = 0.85
        #expect(Set([plain, active, emphasis, color, frame]).count == 5)
    }
}

extension CaptionOverlayPlanTests {
    @Test func cuttingIntoATranslationKeepsItsOriginalWordPaceAndDoesNotReplayEntrance() throws {
        var style = CaptionStyle()
        style.highlight = "color"
        style.animation = "pop"
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
        let pages = CaptionOverlayPlan.pages(segments: [.init(start: 10, end: 14, text: "one two three four")],
            renderer: renderer, sourceStart: 11.5, speed: 1, duration: 1.5, position: "bottom")
        let plan = try CaptionOverlayPlan.plan(pages: pages, style: style)
        #expect(plan.overlays.map { $0.raster.activeIndex } == [1, 2])
        #expect(plan.overlays.map(\.start) == [0, 0.5])
        #expect(plan.overlays.map(\.end) == [0.5, 1.5])
        #expect(plan.overlays.allSatisfy { $0.raster.frame == .init() })
    }
}
