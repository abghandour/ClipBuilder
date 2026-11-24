import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import Clip_Builder

struct PGPreferredTests {
    private func style() throws -> CaptionStyle {
        try #require(CaptionPresets.styles.first { $0.name == "PG Preferred" }).style
    }

    /// First visible frames in the 30-fps reference, numbered from one.
    private var reference: TranscriptSegment {
        let tokens = "You have to be an actress, right? A dancer. The UFC is a show.".split(separator: " ").map(String.init)
        let frames = [5, 7, 11, 15, 18, 23, 36, 39, 43, 59, 65, 75, 80, 83, 94]
        let words = tokens.indices.map { index in
            TranscriptWord(word: tokens[index], start: Double(frames[index] - 1) / 30,
                           end: Double(frames[index + 1] - 1) / 30)
        }
        return TranscriptSegment(start: 0, end: 93.0 / 30, text: tokens.joined(separator: " "), words: words)
    }

    @Test func builtInValuesAndRoundTrip() throws {
        let preset = try #require(CaptionPresets.styles.first { $0.name == "PG Preferred" })
        let s = preset.style
        #expect(preset.family == .creator)
        #expect(s.font == "HelveticaNeue-Medium")
        #expect(s.resolvedSize(for: .text) * (s.resolvedTextDecor(for: .text).size ?? 1) == 150)
        #expect(s.resolvedLetterSpacing == -6.7)
        #expect(s.resolvedLineSpacing == 136 && s.resolvedWordSpacing == 19.15)
        #expect(s.emphasisDecor?.letterSpacing == -6.48)
        #expect(s.emphasisDecor?.decor?.letterSpacing == nil)
        #expect(s.resolvedTextDecor(for: .emphasis).letterSpacing == -6.48)
        #expect(s.position == "custom:0.50325,0.5531")
        #expect(s.resolvedHighlightColor == "#de1600")
        #expect(s.color == "#fcfcfc")
        #expect(s.colorSpace == "srgb")
        #expect(s.resolvedEmphasis == "color")
        #expect(s.resolvedEmphasisColor == "#fcfcfc")
        #expect(s.emphasisDecor?.resolvedFitLineMinimumScale == 0.6)
        #expect(s.resolvedFixedReveal && s.resolvedHighlightHold && s.resolvedRevealMotion)
        #expect(s.resolvedStrokeWidth == 0 && !s.bgOn)
        #expect(s.resolvedTextDecor(for: .text).shadowStyle == "soft")
        #expect(try JSONDecoder().decode(CaptionStyle.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func emphasisLineFitsWithAStableSizeRatioAndBaseline() throws {
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: try style(), safeArea: nil)
        for (text, index, normalRange) in [
            ("The UFC is a show.", 4, 100.0...115.0),
            ("to sell the fight.", 3, 125.0...140.0),
            ("Shake that booty.", 2, 105.0...120.0)
        ] {
            let line = try #require(renderer.emphasisLineLayout(for: text, emphasis: [index]))
            let normal = CTFontGetSize(line.fonts[0][0].font)
            let enlarged = CTFontGetSize(line.fonts[index][0].font)
            #expect(normalRange.contains(normal))
            #expect(abs(enlarged / normal - 1.539) < 0.000_001)
            #expect(abs(line.width - 939.6) < 0.01)
            #expect(abs(line.space - 19.15 * line.scale) < 0.000_001)
            #expect(abs(line.fonts[0][0].kern - -6.7 * line.scale) < 0.000_001)
            #expect(abs(line.fonts[index][0].kern - -6.48 * line.scale) < 0.000_001)
            let scratch = try directory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let active = try renderer.render(text: text, activeIndex: index, emphasis: [index], to: scratch)
            let settled = try renderer.render(text: text, emphasis: [index], to: scratch)
            #expect(active.width == settled.width && active.height == settled.height)
            let a = try pixels(active.pngURL), b = try pixels(settled.pngURL)
            // Colour changes must not alter the baseline, glyphs or reserved slots.
            #expect(stride(from: 3, to: a.count, by: 4).allSatisfy { a[$0] == b[$0] })
            // One row at the emphasis size plus the room its glow needs.
            #expect(active.height < 480)
        }
    }

    @Test func nonEmphasisPagesAreByteIdenticalToThePreviousPreset() throws {
        let current = try style()
        var previous = current
        previous.emphasis = "none"
        previous.emphasisFont = nil
        // Keep only the emphasis shadow: every page reserves room for the
        // widest effect of any word state, so the glow sets the image size.
        previous.emphasisDecor = CaptionWordDecor(decor: current.emphasisDecor?.decor.map {
            TextDecor(shadowOn: $0.shadowOn, shadowColor: $0.shadowColor, shadowOpacity: $0.shadowOpacity,
                      shadowX: $0.shadowX, shadowY: $0.shadowY, shadowBlur: $0.shadowBlur,
                      shadowStyle: $0.shadowStyle, shadowStrength: $0.shadowStrength)
        })
        let before = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: previous, safeArea: nil)
        let after = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: current, safeArea: nil)
        let scratch = try directory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        for text in ["You have to be an actress,", "right? A dancer.", "As athletes, we need to",
                     "One long page. With several sentences. That must be reduced to two rows."] {
            for active in [nil, 0, 2] as [Int?] {
                let a = try before.render(text: text, activeIndex: active, to: scratch)
                let b = try after.render(text: text, activeIndex: active, to: scratch)
                #expect(try Data(contentsOf: a.pngURL) == Data(contentsOf: b.pngURL))
            }
        }
    }

    @Test func newStateFieldsAreAbsentInOldJSONAndPreserveRendering() throws {
        let old = Data(#"{"size":80,"italic":true}"#.utf8)
        let decoded = try JSONDecoder().decode(CaptionWordDecor.self, from: old)
        #expect(decoded.fitLineMinimumScale == nil && decoded.highlightHold == nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(object["fit_line_minimum_scale"] == nil && object["highlight_hold"] == nil)
        let scratch = try directory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var saved = CaptionStyle()
        saved.emphasis = "font"
        saved.emphasisDecor = decoded
        let roundTrip = try JSONDecoder().decode(CaptionStyle.self, from: JSONEncoder().encode(saved))
        let a = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: saved, safeArea: nil)
            .render(text: "An old saved style", activeIndex: 2, emphasis: [1], to: scratch)
        let b = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: roundTrip, safeArea: nil)
            .render(text: "An old saved style", activeIndex: 2, emphasis: [1], to: scratch)
        #expect(try Data(contentsOf: a.pngURL) == Data(contentsOf: b.pngURL))
    }

    @Test func fixedRevealReservesHiddenEmphasisAndReleasesItsHighlight() throws {
        let s = try style()
        let page = CaptionPage(text: "to sell the fight.", start: 0, end: 2, words: [
            .init(word: "to", start: 0, end: 0.2), .init(word: "sell", start: 0.3, end: 0.5),
            .init(word: "the", start: 0.6, end: 0.7), .init(word: "fight.", start: 0.8, end: 1.2)])
        let plan = try CaptionOverlayPlan.plan(pages: [.init(caption: page, position: s.position, language: "en")], style: s)
        #expect(plan.overlays.allSatisfy { $0.raster.emphasis == [3] })
        #expect(plan.overlays.first { $0.start <= 0.25 && $0.end > 0.25 }?.raster.activeIndex == 0)
        #expect(plan.overlays.first { $0.start <= 1.3 && $0.end > 1.3 }?.raster.activeIndex == nil)
        var heldStyle = s
        heldStyle.highlightHold = false
        heldStyle.emphasisDecor?.highlightHold = true
        let held = try CaptionOverlayPlan.plan(pages: [.init(caption: page, position: s.position, language: "en")], style: heldStyle)
        #expect(held.overlays.first { $0.start <= 0.25 && $0.end > 0.25 }?.raster.activeIndex == nil)
        #expect(held.overlays.first { $0.start <= 1.3 && $0.end > 1.3 }?.raster.activeIndex == 3)
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: s, safeArea: nil)
        let scratch = try directory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let early = try renderer.render(text: page.text, activeIndex: 0, emphasis: [3], frame: .init(visibleWords: 1), to: scratch)
        let full = try renderer.render(text: page.text, emphasis: [3], to: scratch)
        #expect(early.width == full.width && early.height == full.height)
    }

    /// A larger word on the second row used to print over the first row.
    @Test func aLargerWordOnTheSecondRowPushesItsRowDown() throws {
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: try style(), safeArea: nil)
        let text = "Every strong moment earns"
        try #require(renderer.rowCount(for: text) == 2)
        let scratch = try directory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let second = try renderer.render(text: text, emphasis: [2], to: scratch)
        // White ink must form two bands with clear rows between them.
        let bytes = try pixels(second.pngURL)
        let inked = (0..<second.height).map { y in
            (0..<second.width).contains { x in
                let i = (y * second.width + x) * 4
                return bytes[i] > 245 && bytes[i + 1] > 245 && bytes[i + 2] > 245 && bytes[i + 3] == 255
            }
        }
        let bands = zip(inked, [false] + inked).filter { $0 && !$1 }.count
        #expect(bands == 2)
        if let keep = ProcessInfo.processInfo.environment["PG_ROWS_OUT"] {
            try? FileManager.default.copyItem(at: second.pngURL, to: URL(fileURLWithPath: keep))
        }
    }

    /// The reference: no glow while the enlarged word is spoken, then the
    /// glow grows in steps and stays.
    @Test func emphasisGlowGrowsInAfterTheWordAndStays() throws {
        let s = try style()
        let tokens = ["but", "sponsorship"]
        var words = [TranscriptWord(word: "but", start: 0, end: 0.3), TranscriptWord(word: "sponsorship", start: 0.3, end: 0.5)]
        words[1].emphasis = "primary"
        let page = CaptionPage(text: tokens.joined(separator: " "), start: 0, end: 2, words: words)
        let plan = try CaptionOverlayPlan.plan(pages: [.init(caption: page, position: "middle")], style: s)
        let shown = plan.overlays.filter { $0.raster.emphasis.contains(1) && ($0.raster.frame.visibleWords ?? 2) > 1 }
        try #require(!shown.isEmpty)
        // Spoken: no glow at all.
        #expect(shown.filter { $0.end <= 0.5 + 0.000_001 }.allSatisfy { $0.raster.frame.glow[1] == 0 })
        // Then eight rising steps, one per frame, and the full glow after.
        let growing = shown.filter { $0.start >= 0.5 - 0.000_001 && $0.raster.frame.glow[1] != nil }
        let values = growing.compactMap { $0.raster.frame.glow[1] }
        #expect(values.count == 8 && values == values.sorted() && (values.first ?? 0) > 0 && (values.last ?? 1) < 1)
        let last = try #require(shown.last)
        #expect(last.raster.frame.glow[1] == nil && abs(last.start - 0.77) < 0.001 && last.end == 2)
        // Pixels: the halo zone is empty while spoken and lit when settled.
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: s, safeArea: nil)
        let scratch = try directory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        func alpha(_ glow: [Int: Double]) throws -> Int {
            var frame = CaptionAnimation.Frame()
            frame.glow = glow
            let image = try renderer.render(text: page.text, emphasis: [1], frame: frame, to: scratch)
            let bytes = try pixels(image.pngURL)
            return stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }
        }
        let none = try alpha([1: 0]), half = try alpha([1: 0.5]), full = try alpha([:])
        #expect(none < half && half < full)
        if let keep = ProcessInfo.processInfo.environment["PG_GLOW_OUT"] {
            for (name, glow) in [("0", [1: 0.0]), ("1", [1: 0.33]), ("2", [1: 0.66]), ("3", [:])] as [(String, [Int: Double])] {
                var frame = CaptionAnimation.Frame()
                frame.glow = glow
                let image = try renderer.render(text: page.text, emphasis: [1], frame: frame, to: scratch)
                try? FileManager.default.copyItem(at: image.pngURL, to: URL(fileURLWithPath: keep).appendingPathComponent("g\(name).png"))
            }
        }
    }

    @Test func emphasisFitFallsBackInsteadOfExceedingTheMinimumScale() throws {
        var s = try style()
        s.emphasisDecor?.fitLineMinimumScale = 0.95
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: s, safeArea: nil)
        #expect(renderer.emphasisLineLayout(for: "The UFC is a show.", emphasis: [4]) == nil)
        #expect(renderer.emphasisLineLayout(for: "one two", emphasis: []) == nil)
        #expect(renderer.emphasisLineLayout(for: "one two", emphasis: [20]) == nil)
    }

    @Test func referenceEmphasisReleaseUsesWordEndRatherThanPageEnd() throws {
        let s = try style()
        #expect(s.emphasisDecor?.highlightHold == false)
        // Frame observations: show is white at 85...92; fight stays red
        // through 163, booty through 181. These supplied word-end clocks
        // exercise the release policy, not an audio alignment assertion.
        for (word, onset, wordEnd, pageEnd, whiteFrom) in [
            ("show.", 83, 85, 93, 85),
            ("fight.", 154, 164, 164, 164),
            ("booty.", 177, 182, 182, 182)
        ] {
            let page = CaptionPage(text: word, start: Double(onset - 1) / 30,
                end: Double(pageEnd - 1) / 30, words: [
                    .init(word: word, start: Double(onset - 1) / 30, end: Double(wordEnd - 1) / 30)
                ])
            let states = CaptionWordStates.states(for: page, words: page.words,
                holdHighlight: s.resolvedHighlightHold, unheldIndices: [0])
            for frame in onset..<pageEnd {
                let time = Double(frame - 1) / 30 + 0.000_001
                let state = try #require(states.first { $0.start <= time && $0.end > time })
                #expect(state.activeIndex == (frame < whiteFrom ? 0 : nil))
            }
        }
    }

    @Test func rowsBreakAfterCommasAndSentencesAndBalanceOtherwise() throws {
        #expect(CaptionRenderer.endsRow("athletes,", lineBreaks: "clause"))
        #expect(!CaptionRenderer.endsRow("athletes,", lineBreaks: "sentence"))
        #expect(CaptionRenderer.endsRow("right?”", lineBreaks: "sentence"))
        #expect(!CaptionRenderer.endsRow("athletes,", lineBreaks: "balanced"))
        #expect(CaptionRenderer.balances(["Kayla", "Harrison", "and", "Amanda", "Nunes"], lineBreaks: "clause"))
        #expect(!CaptionRenderer.balances(["As", "athletes,", "we", "need"], lineBreaks: "clause"))
        // A closing comma chooses nothing: the page is still balanced.
        #expect(CaptionRenderer.balances(["You", "have", "to", "be", "an", "actress,"], lineBreaks: "clause"))
        #expect(!CaptionRenderer.balances(["a", "b"], lineBreaks: "sentence"))
        var style = CaptionStyle()
        style.lineBreaks = "clause"
        #expect(style.resolvedLineBreaks == "clause")
    }

    @Test func referencePageBreaks() throws {
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: try style(), safeArea: nil)
        let pages = renderer.pages(for: reference)
        #expect(pages.map(\.text) == ["You have to be an actress,", "right? A dancer.", "The UFC is a show."])
        #expect(pages.map { $0.words?.count } == [6, 3, 5])
        let starts: [Double] = [4.0 / 30, 35.0 / 30, 58.0 / 30]
        #expect(pages.map(\.start) == starts)
        #expect(renderer.rowCount(for: pages[0].text) == 2)
        #expect(renderer.rowCount(for: pages[1].text) == 2)
    }

    @Test func everyReferenceFrameHasTheCorrectVisibleAndRedWords() throws {
        let s = try style()
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: s, safeArea: nil)
        let pages = renderer.pages(for: reference)
        let plan = try CaptionOverlayPlan.plan(pages: pages.map { .init(caption: $0, position: s.position) }, style: s)
        for number in 5...58 {
            let t = Double(number - 1) / 30 + 0.000_001
            let overlay = try #require(plan.overlays.first { $0.start <= t && $0.end > t })
            let pageIndex = number < 36 ? 0 : 1
            let words = try #require(pages[pageIndex].words)
            let active = try #require(words.lastIndex { $0.start <= t })
            #expect(overlay.raster.text == pages[pageIndex].text)
            #expect(overlay.raster.activeIndex == active)
            #expect(overlay.raster.frame.visibleWords == active + 1)
            let entryStart = pageIndex == 0 ? 23 : 43
            let progress = number - entryStart
            let expectedAlpha = (0...2).contains(progress) ? [0.13, 0.49, 0.83][progress] : 1
            #expect(abs(Double(overlay.raster.frame.alpha) - expectedAlpha) < 0.000_001)
            #expect(overlay.raster.frame.scale == 1 && overlay.raster.frame.offsetY == 0)
        }
        let frames = CaptionAnimation.frames(for: "soft-fade", duration: 0.1)
        let frameTimes: [Double] = [0, 1.0 / 30, 2.0 / 30, 0.1]
        #expect(zip(frames.map(\.at), frameTimes).allSatisfy { abs($0 - $1) < 0.000_001 })
        #expect(!plan.usedPageFallback && !plan.usedRevealFallback)
    }

    @Test func highlightHoldIsOptInAndDoesNotRelightSilenceBeforeSpeech() {
        let page = CaptionPage(text: "one two", start: 0, end: 3, words: [
            .init(word: "one", start: 0.2, end: 0.5), .init(word: "two", start: 1.5, end: 2)])
        let old = CaptionWordStates.states(for: page, words: nil)
        #expect(old.map(\.activeIndex) == [nil, 0, nil, 1, nil])
        let held = CaptionWordStates.states(for: page, words: nil, holdHighlight: true)
        #expect(held.map(\.activeIndex) == [nil, 0, 1])
        #expect(held.map(\.start) == [0, 0.2, 1.5])
        #expect(held.map(\.end) == [0.2, 1.5, 3])
    }

    @Test func legacyEncodingAndPixelsStayUnchanged() throws {
        let keys = ["reveal_layout", "highlight_hold", "animation_minimum_word_duration", "line_breaks", "line_spacing", "word_spacing", "color_space"]
        let legacy = try JSONDecoder().decode(CaptionStyle.self, from: Data("{}".utf8))
        #expect(!legacy.resolvedFixedReveal && !legacy.resolvedHighlightHold)
        #expect(legacy.resolvedLineSpacing == nil && legacy.resolvedWordSpacing == nil)
        for preset in CaptionPresets.styles where preset.name != "PG Preferred" {
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preset.style)) as? [String: Any])
            #expect(keys.allSatisfy { object[$0] == nil })
        }
        let scratch = try directory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: legacy, safeArea: nil)
        let old = try renderer.render(text: "one two", to: scratch)
        let explicit = try renderer.render(text: "one two", frame: .init(visibleWords: nil, wordIndex: nil), to: scratch)
        #expect(try Data(contentsOf: old.pngURL) == Data(contentsOf: explicit.pngURL))
    }

    @Test func fixedSlotsKeepEarlierPixelsAndBothLinePositionsThroughTheEntrance() throws {
        let scratch = try directory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: try style(), safeArea: nil)
        let text = "You have to be an actress,"
        let entering = try renderer.render(text: text, activeIndex: 5,
            frame: .init(alpha: 0.13, visibleWords: 6, wordIndex: 5), to: scratch)
        let settled = try renderer.render(text: text, activeIndex: 5,
            frame: .init(visibleWords: 6), to: scratch)
        let first = try renderer.render(text: text, activeIndex: 0,
            frame: .init(visibleWords: 1), to: scratch)
        #expect(entering.width == settled.width && entering.height == settled.height)
        #expect(first.width == settled.width && first.height == settled.height)
        let a = try pixels(entering.pngURL), b = try pixels(settled.pngURL)
        // The entire upper line is identical while the lower word fades.
        let topHalf = entering.width * (entering.height / 2) * 4
        #expect(a.prefix(topHalf) == b.prefix(topHalf))
        #expect(a != b)
        let firstPixels = try pixels(first.pngURL)
        let sameFirstWord = (0..<(first.height / 2)).allSatisfy { y in
            (0..<280).allSatisfy { x in
                let alpha = (y * first.width + x) * 4 + 3
                return firstPixels[alpha] == b[alpha]
            }
        }
        #expect(sameFirstWord)
        let hidden = try renderer.render(text: text, frame: .init(visibleWords: 0), to: scratch)
        #expect(try pixels(hidden.pngURL).enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 0 })
    }

    @Test func sampledVideoColorSurvivesThePNGColorProfile() throws {
        let scratch = try directory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: try style(), safeArea: nil)
        let caption = try renderer.render(text: "You", activeIndex: 0, to: scratch)
        let rgba = try pixels(caption.pngURL, space: CGColorSpace(name: CGColorSpace.sRGB)!)
        let hasSampledColor = stride(from: 0, to: rgba.count, by: 4).contains { index in
            rgba[index] == 222 && rgba[index + 1] == 22 && rgba[index + 2] == 0 && rgba[index + 3] == 255
        }
        #expect(hasSampledColor)
    }

    @Test func thumbnailAndFallbackRetainACompleteReadablePage() throws {
        let s = try style()
        let preview = try CaptionPreviewImage.render(style: s)
        #expect(preview.start > 0.3)
        #expect(!preview.data.isEmpty)
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: s, safeArea: nil)
        let pages = renderer.pages(for: reference).map { CaptionOverlayPlan.Page(caption: $0, position: s.position) }
        let fallback = try CaptionOverlayPlan.plan(pages: pages, style: s, limit: 3)
        #expect(fallback.usedRevealFallback && fallback.usedPageFallback)
        #expect(fallback.overlays.allSatisfy { $0.raster.frame.visibleWords == nil })
        let merged = try CaptionOverlayPlan.plan(pages: pages, style: s, limit: 1)
        let scratch = try directory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let raster = try #require(merged.overlays.first).raster
        let image = try renderer.render(text: raster.text, to: scratch)
        #expect(image.height > 100)
        #expect(image.width <= 1080)
    }

    @Test func secondEmphasisIsAnItalicSerifWordOnAnOrdinaryPage() throws {
        let style = try style()
        #expect(style.hasAlternateEmphasis)
        #expect(style.emphasis2Font == "Bodoni 72")
        #expect(style.emphasis2Decor?.italic == true)
        // The second look never pulls its page onto one line.
        #expect(style.emphasis2Decor?.resolvedFitLineMinimumScale == nil)
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
        #expect(renderer.wordState(at: 6, activeIndex: nil, emphasis: [6], alternateEmphasis: [6]) == .emphasis2)
        let scratch = try directory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let text = "When are you gonna get that belt?"
        let marked = try renderer.render(text: text, emphasis: [6], alternateEmphasis: [6], to: scratch)
        let plain = try renderer.render(text: text, to: scratch)
        #expect(try Data(contentsOf: marked.pngURL) != Data(contentsOf: plain.pngURL))
        // The other words keep their places: only the box grows for the taller word.
        #expect(marked.height > plain.height)
        // Spoken, the serif word stays white, as in the reference.
        #expect(renderer.wordState(at: 6, activeIndex: 6, emphasis: [6], alternateEmphasis: [6]) == .emphasis2)
        let spoken = try renderer.render(text: text, activeIndex: 6, emphasis: [6], alternateEmphasis: [6], to: scratch)
        #expect(try pixels(spoken.pngURL) == pixels(marked.pngURL))
        var taking = style
        taking.emphasis2Decor?.takesHighlightColor = nil
        let red = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: taking, safeArea: nil)
            .render(text: text, activeIndex: 6, emphasis: [6], alternateEmphasis: [6], to: scratch)
        #expect(try pixels(red.pngURL) != pixels(marked.pngURL))
        if let keep = ProcessInfo.processInfo.environment["PG_KEEP_RENDER"] {
            try? FileManager.default.removeItem(atPath: keep)
            try FileManager.default.copyItem(at: marked.pngURL, to: URL(fileURLWithPath: keep))
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pixels(_ url: URL, space: CGColorSpace = CGColorSpaceCreateDeviceRGB()) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
