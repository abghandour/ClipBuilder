import Foundation
import Testing
@testable import Clip_Builder

struct CaptionEmphasisWordsTests {
    private func page(_ marks: [String?]) -> CaptionPage {
        let tokens = ["20", "bright", "stars"]
        return CaptionPage(text: tokens.joined(separator: " "), start: 0, end: 3,
            words: zip(tokens, marks).enumerated().map {
                TranscriptWord(word: $0.element.0, start: Double($0.offset), end: Double($0.offset + 1), emphasis: $0.element.1)
            })
    }

    @Test func everyCombinationTakesOverOnlyItsPage() {
        let choices: [String?] = [nil, "none", "primary", "alternate"]
        for a in choices { for b in choices { for c in choices {
            let marks = [a, b, c], p = page([a, b, c])
            let selected = CaptionEmphasis.selection(for: p, language: "en")
            if marks.allSatisfy({ $0 == nil }) {
                #expect(selected.primary == CaptionEmphasis.automaticIndices(for: p, language: "en"))
                #expect(selected.alternate.isEmpty)
            } else {
                #expect(selected.primary == marks.indices.filter { marks[$0] == "primary" })
                #expect(selected.alternate == marks.indices.filter { marks[$0] == "alternate" })
            }
        } } }
        #expect(CaptionEmphasis.indices(for: page([nil, nil, nil]), language: "en").contains(0))
    }

    @Test func unknownValuesAndMisalignedWordsDoNotOverrideAutomatic() {
        var p = page(["future", nil, nil])
        #expect(CaptionEmphasis.indices(for: p, language: "en") == CaptionEmphasis.automaticIndices(for: p, language: "en"))
        p.words?[0].emphasis = "none"
        p.words?[0].word = "different"
        #expect(CaptionEmphasis.indices(for: p, language: "en").contains(0))
    }

    @Test func wordJSONIsIdenticalWhenUnmarked() throws {
        let legacy = Data(#"{"end":1,"start":0,"word":"20"}"#.utf8)
        var word = try JSONDecoder().decode(TranscriptWord.self, from: legacy)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(word.emphasis == nil)
        #expect(try encoder.encode(word) == legacy)
        for value in ["none", "primary", "alternate"] {
            word.emphasis = value
            #expect(try JSONDecoder().decode(TranscriptWord.self, from: encoder.encode(word)) == word)
        }
    }

    @Test func survivingWordsKeepMarksAndReplacedWordsLoseThem() throws {
        let before = try #require(page(["primary", "none", "alternate"]).words)
        let after = try #require(TranscriptWordAlignment.realign(text: "20 new stars", original: before, start: 0, end: 6))
        #expect(after.map(\.emphasis) == ["primary", nil, "alternate"])
        let retimed = try #require(TranscriptWordAlignment.realign(text: "20 bright stars", original: before, start: 0.5, end: 2.5))
        #expect(retimed.map(\.emphasis) == before.map(\.emphasis))
        let pristine = before.map { TranscriptWord(word: $0.word, start: $0.start, end: $0.end) }
        #expect(TranscriptWordRules.carryingMarks(from: before, onto: pristine)?.map(\.emphasis) == before.map(\.emphasis))
        #expect(TranscriptWordRules.carryingMarks(fromRecut: before, onto: pristine).map(\.emphasis) == before.map(\.emphasis))
        let right = try #require(TranscriptWordRules.confirming([2: "stars"], words: before))
        #expect(right[2].confidence == 1 && right[2].emphasis == "alternate")
        let proofread = TranscriptWordRules.suggesting([2: (heard: "stars", suggestion: .init(to: "star", reason: "test"))],
                                                      covered: [2], words: before)
        #expect(proofread.words[2].emphasis == "alternate")
    }

    @Test func repeatedWordsFollowExactKeptPositions() throws {
        let words = [TranscriptWord(word: "go", start: 0, end: 1, emphasis: "primary"),
                     TranscriptWord(word: "go", start: 1, end: 2, emphasis: "alternate")]
        let result = try #require(TranscriptWordAlignment.realign(text: "go", original: words, start: 0, end: 2, known: [0: 1]))
        #expect(result[0].emphasis == "alternate")
    }

    @Test func translationAndUntimedRowsHaveIndependentMarks() throws {
        let edit = TranscriptEmphasisRules.Edit(text: "vinte estrelas", marks: [1: "alternate"])
        let words = try #require(TranscriptEmphasisRules.applying(edit, text: edit.text, words: nil, start: 2, end: 4))
        #expect(words.map(\.emphasis) == [nil, "alternate"])
        #expect(words.map(\.start) == [2, 3])
        let cleared = TranscriptEmphasisRules.applying(.init(text: edit.text, marks: [1: "automatic"]),
            text: edit.text, words: words, start: 2, end: 4)
        #expect(cleared?.allSatisfy { $0.emphasis == nil } == true)
        #expect(TranscriptEmphasisRules.applying(edit, text: "changed", words: words, start: 2, end: 4) == nil)
    }

    @Test func styleOptionalFieldsInheritAndRoundTrip() throws {
        var style = try JSONDecoder().decode(CaptionStyle.self, from: Data("{}".utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let original = try encoder.encode(style)
        #expect(!String(decoding: original, as: UTF8.self).contains("emphasis_2"))
        #expect(style.resolvedTextDecor(for: .emphasis2) == style.resolvedTextDecor(for: .emphasis))
        style.emphasis2 = "font"
        style.emphasis2Font = "Baskerville-Italic"
        style.emphasis2Color = "#fcfcfc"
        style.emphasis2Decor = .init(italic: true, size: 100)
        #expect(try JSONDecoder().decode(CaptionStyle.self, from: encoder.encode(style)) == style)
        style.emphasis2 = nil; style.emphasis2Font = nil; style.emphasis2Color = nil; style.emphasis2Decor = nil
        #expect(try encoder.encode(style) == original)
    }

    @Test func planCarriesBothLooksThroughRetimingAndFixedReveal() throws {
        var style = CaptionStyle()
        style.emphasis = "font"
        style.reveal = "word"
        style.revealLayout = "fixed"
        style.emphasisDecor = .init(fitLineMinimumScale: 0.6)
        let p = page(["primary", nil, "alternate"])
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
        let pages = CaptionOverlayPlan.pages(segments: [.init(start: 0, end: 3, text: p.text, words: p.words)],
            renderer: renderer, sourceStart: 0, speed: 0.5, duration: 6, position: "bottom")
        #expect(pages.first?.caption.words?.last?.emphasis == "alternate")
        #expect(pages.first?.caption.words?.last?.end == 6)
        let plan = try CaptionOverlayPlan.plan(pages: pages, style: style)
        #expect(plan.overlays.first?.raster.emphasis == [0, 2])
        #expect(plan.overlays.first?.raster.alternateEmphasis == [2])
        style.emphasis = "none"
        let off = try CaptionOverlayPlan.plan(pages: pages, style: style)
        #expect(off.overlays.allSatisfy { $0.raster.emphasis.isEmpty && $0.raster.alternateEmphasis.isEmpty })
    }

    @Test func fallbackAndZeroLengthClocksKeepExplicitMarks() throws {
        let p = page(["none", nil, "alternate"])
        var words = try #require(p.words)
        for index in words.indices { words[index].start = 0; words[index].end = 0 }
        let pages = CaptionPaging.pages(text: p.text, start: 0, end: 3, words: words, maxWords: 1, fits: { _ in true })
        #expect(pages.last?.words?.first?.emphasis == "alternate")
        var style = CaptionStyle()
        style.emphasis = "font"
        let plan = try CaptionOverlayPlan.plan(pages: [
            .init(caption: p, position: "bottom"),
            .init(caption: .init(text: "now", start: 3, end: 4), position: "bottom")], style: style, limit: 1)
        #expect(plan.usedPageFallback)
        #expect(plan.overlays.first?.raster.alternateEmphasis == [2])
    }

    @Test func rendererChoosesPerWordStateAndDisablesBothLooks() {
        var style = CaptionStyle()
        style.emphasis = "font"; style.emphasis2Font = "Baskerville-Italic"; style.highlight = "color"
        var renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
        #expect(renderer.wordState(at: 0, activeIndex: nil, emphasis: [0, 2], alternateEmphasis: [2]) == .emphasis)
        #expect(renderer.wordState(at: 1, activeIndex: nil, emphasis: [0, 2], alternateEmphasis: [2]) == .text)
        #expect(renderer.wordState(at: 2, activeIndex: 2, emphasis: [0, 2], alternateEmphasis: [2]) == .emphasis2)
        style.emphasis = "none"
        renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
        #expect(renderer.wordState(at: 2, activeIndex: nil, emphasis: [0, 2], alternateEmphasis: [2]) == .text)
    }

    @Test func absentSecondStyleRendersExactlyLikePrimaryAndCacheSeparatesMarks() async throws {
        var style = CaptionStyle()
        style.emphasis = "font"; style.emphasisFont = "Georgia"; style.highlight = "color"
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for active in [nil, 0] as [Int?] {
            let a = try renderer.render(text: "stars", activeIndex: active, emphasis: [0], to: directory)
            let b = try renderer.render(text: "stars", activeIndex: active, emphasis: [0], alternateEmphasis: [0], to: directory)
            #expect(try Data(contentsOf: a.pngURL) == Data(contentsOf: b.pngURL))
        }
        let cache = CaptionPNGCache(renderer: renderer, directory: directory)
        let raster = CaptionOverlayPlan.Raster(text: "stars")
        let a = try await cache.rendered(raster)
        var identical = raster
        identical.alternateEmphasis = []
        #expect(try await cache.rendered(identical).pngURL == a.pngURL)
        var marked = raster
        marked.emphasis = [0]; marked.alternateEmphasis = [0]
        #expect(marked != raster)
        #expect(try await cache.rendered(marked).pngURL != a.pngURL)
    }
}
