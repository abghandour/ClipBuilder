import CoreGraphics
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
        #expect(!plan.usedRevealFallback)
        #expect(plan.overlays.allSatisfy { $0.raster.activeIndex == nil && $0.raster.frame == .init() })
        let long = (0..<1000).map { (index: Int) -> CaptionOverlayPlan.Page in
            CaptionOverlayPlan.Page(caption: .init(text: "word\(index)", start: Double(index), end: Double(index + 1)),
                                    position: index < 500 ? "top" : "bottom", streamID: index < 500 ? "a" : "b")
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
    @Test func revealWithoutHighlightUsesWordClocksAndWhitespaceTokens() throws {
        var style = CaptionStyle()
        style.reveal = "word"
        let page = CaptionPage(text: "a  b\nc", start: 0, end: 3, words: [
            .init(word: "a", start: 0, end: 0.5),
            .init(word: "b", start: 0.5, end: 2),
            .init(word: "c", start: 2, end: 3)])
        let plan = try CaptionOverlayPlan.plan(pages: [.init(caption: page, position: "top", textColor: "#123456")], style: style)
        #expect(plan.overlays.map { $0.raster.text } == ["a", "a b", "a b c"])
        #expect(plan.overlays.map(\.start) == [0, 0.5, 2])
        #expect(plan.overlays.map(\.end) == [0.5, 2, 3])
        #expect(plan.overlays.allSatisfy { $0.raster.activeIndex == nil && $0.raster.textColor == "#123456" && $0.position == "top" })
        #expect(!plan.usedRevealFallback && !plan.usedPageFallback)
        #expect(Set(plan.overlays.map(\.raster)).count == 3)
    }

    @Test func revealSkipsLeadingSilenceKeepsGapsAndDelaysEmoji() throws {
        var style = CaptionStyle()
        style.reveal = "word"
        style.highlight = "color"
        style.emoji = true
        let page = CaptionPage(text: "More money", start: 0, end: 4, words: [
            .init(word: "More", start: 1, end: 1.5),
            .init(word: "money", start: 2, end: 3)])
        let plan = try CaptionOverlayPlan.plan(pages: [.init(caption: page, position: "bottom")], style: style)
        #expect(plan.overlays.map { $0.raster.text } == ["More", "More", "More money 💰", "More money 💰"])
        #expect(plan.overlays.map { $0.raster.activeIndex } == [0, nil, 1, nil])
        #expect(plan.overlays.map(\.start) == [1, 1.5, 2, 3])
        #expect(plan.overlays.map(\.end) == [1.5, 2, 3, 4])
    }

    @Test func revealOnlyEmphasisesVisibleWords() throws {
        var style = CaptionStyle()
        style.reveal = "word"
        style.emphasis = "both"
        let page = CaptionPage(text: "10 to 20", start: 0, end: 3)
        let plan = try CaptionOverlayPlan.plan(pages: [.init(caption: page, position: "bottom")], style: style)
        #expect(plan.overlays.map { $0.raster.emphasis } == [[0], [0], [0, 2]])
        #expect(plan.overlays.map(\.start) == [0, 1, 2])
        #expect(plan.overlays.map(\.end) == [1, 2, 3])
    }

    @Test(arguments: [false, true])
    func revealMotionAnimatesWordEntrancesButNeverSilence(eachWord: Bool) throws {
        var style = CaptionStyle()
        style.reveal = "word"
        style.revealMotion = eachWord
        style.animation = "pop"
        let page = CaptionPage(text: "a b", start: 0, end: 4, words: [
            .init(word: "a", start: 1, end: 1.5),
            .init(word: "b", start: 2, end: 3)])
        let plan = try CaptionOverlayPlan.plan(pages: [.init(caption: page, position: "bottom")], style: style)
        let first = plan.overlays.filter { $0.start >= 1 && $0.start < 1.5 }
        #expect(first.map { $0.raster.frame.scale } == [0.85, 0.98, 1.08, 1.03, 1])
        #expect(first.first?.start == 1 && first.last?.end == 1.5)
        let second = plan.overlays.filter { $0.start >= 2 && $0.start < 3 }
        #expect(second.map { $0.raster.frame.scale } == (eachWord ? [0.85, 0.98, 1.08, 1.03, 1] : [1]))
        #expect(second.first?.start == 2 && second.last?.end == 3)
        let silence = plan.overlays.filter { $0.start == 1.5 || $0.start == 3 }
        #expect(silence.count == 2 && silence.allSatisfy { $0.raster.frame == .init() })
        #expect(plan.overlays.allSatisfy { $0.start >= 1 && $0.raster.activeIndex == nil && $0.raster.frame.at == 0 })
    }

    @Test func revealMotionFitsShortWordsAndClipsWithoutReplayingEntrance() throws {
        var style = CaptionStyle()
        style.reveal = "word"
        style.revealMotion = true
        style.animation = "pop"
        let page = CaptionPage(text: "a b", start: 0, end: 0.25, words: [
            .init(word: "a", start: 0, end: 0.125),
            .init(word: "b", start: 0.125, end: 0.25)])
        let plan = try CaptionOverlayPlan.plan(pages: [.init(caption: page, position: "bottom")], style: style)
        #expect(plan.overlays.map(\.start) == [0, 0.03125, 0.0625, 0.09375, 0.125, 0.15625, 0.1875, 0.21875])
        #expect(plan.overlays.map(\.end) == [0.03125, 0.0625, 0.09375, 0.125, 0.15625, 0.1875, 0.21875, 0.25])
        let clipped = try CaptionOverlayPlan.plan(pages: [
            .init(caption: page, position: "bottom", windowStart: 0.0625, windowEnd: 0.1875)], style: style)
        #expect(clipped.overlays.map(\.start) == [0.0625, 0.09375, 0.125, 0.15625])
        #expect(clipped.overlays.map { $0.raster.frame.scale } == [1.08, 1.03, 0.85, 0.98])
        #expect(clipped.overlays.last?.end == 0.1875)
    }

    @Test func revealFallbackDropsWordMotionThenRevealThenUsesStaticPages() throws {
        var style = CaptionStyle()
        style.reveal = "word"
        style.revealMotion = true
        style.animation = "pop"
        let pages = [CaptionOverlayPlan.Page(caption: .init(text: "a b c", start: 0, end: 3), position: "bottom")]
        let full = try CaptionOverlayPlan.plan(pages: pages, style: style, limit: 15)
        #expect(full.overlays.count == 15 && !full.usedRevealFallback && !full.usedPageFallback)
        let noWordMotion = try CaptionOverlayPlan.plan(pages: pages, style: style, limit: 7)
        #expect(noWordMotion.overlays.count == 7 && noWordMotion.usedRevealFallback && !noWordMotion.usedPageFallback)
        #expect(noWordMotion.overlays.map { $0.raster.text } == ["a", "a", "a", "a", "a", "a b", "a b c"])
        #expect(noWordMotion.overlays.filter { $0.start >= 1 }.allSatisfy { $0.raster.frame == .init() })
        let noReveal = try CaptionOverlayPlan.plan(pages: pages, style: style, limit: 5)
        #expect(noReveal.overlays.count == 5 && noReveal.usedRevealFallback && !noReveal.usedPageFallback)
        #expect(noReveal.overlays.allSatisfy { $0.raster.text == "a b c" })
        #expect(noReveal.overlays.first?.raster.frame.scale == 0.85)
        let staticPage = try CaptionOverlayPlan.plan(pages: pages, style: style, limit: 1)
        #expect(staticPage.usedRevealFallback && staticPage.usedPageFallback)
        #expect(staticPage.overlays.count == 1 && staticPage.overlays.first?.raster.text == "a b c")
        #expect(staticPage.overlays.first?.raster.frame == .init())
        #expect(staticPage.overlays.first?.start == 0 && staticPage.overlays.first?.end == 3)
    }

    @Test func revealFallbackPreservesHighlightBeforeStaticFallback() throws {
        var style = CaptionStyle()
        style.reveal = "word"
        style.highlight = "color"
        let pages = [CaptionOverlayPlan.Page(caption: .init(text: "a b c", start: 0, end: 3), position: "bottom")]
        let full = try CaptionOverlayPlan.plan(pages: pages, style: style, limit: 3)
        #expect(full.overlays.map { $0.raster.activeIndex } == [0, 1, 2])
        let fallback = try CaptionOverlayPlan.plan(pages: pages, style: style, limit: 2)
        #expect(fallback.usedRevealFallback && fallback.usedPageFallback)
        #expect(fallback.overlays.count == 1 && fallback.overlays.first?.raster.activeIndex == nil)
    }

    @Test func revealMotionHasNoEffectWithoutRevealOrEntrance() throws {
        let pages = [CaptionOverlayPlan.Page(caption: .init(text: "a b c", start: 0, end: 3), position: "bottom")]
        var style = CaptionStyle()
        style.revealMotion = true
        style.animation = "pop"
        let noReveal = try CaptionOverlayPlan.plan(pages: pages, style: style)
        #expect(noReveal.overlays.count == 5 && noReveal.overlays.allSatisfy { $0.raster.text == "a b c" })
        style.reveal = "word"
        style.animation = "none"
        let noEntrance = try CaptionOverlayPlan.plan(pages: pages, style: style)
        #expect(noEntrance.overlays.map { $0.raster.text } == ["a", "a b", "a b c"])
        #expect(noEntrance.overlays.allSatisfy { $0.raster.frame == .init() })
    }

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
