import Foundation
import Testing
@testable import Clip_Builder

struct CaptionPreviewImageTests {
    @Test func blankPhraseFallsBackToTheStockSample() {
        #expect(CaptionPreviewImage.text(nil) == CaptionPreviewImage.sampleText)
        #expect(CaptionPreviewImage.text("   \n") == CaptionPreviewImage.sampleText)
        #expect(CaptionPreviewImage.text("  Hello there  ") == "Hello there")
    }

    @Test func loopLastsAtLeastThreeSecondsAndGrowsWithTheWords() {
        #expect(CaptionPreviewImage.duration(of: "Hi") == 3)
        #expect(CaptionPreviewImage.duration(of: CaptionPreviewImage.sampleText) == 3)
        let twelve = Array(repeating: "word", count: 12).joined(separator: " ")
        #expect(abs(CaptionPreviewImage.duration(of: twelve) - 7.2) < 0.001)
    }

    @Test func framesSpeakTheTypedPhrase() throws {
        var style = CaptionStyle()
        style.wordsPerPage = 2
        let frames = try CaptionPreviewImage.frames(style: style, text: "one two three four")
        #expect(!frames.isEmpty)
        #expect(frames.first?.start == 0)
        #expect(abs((frames.last?.end ?? 0) - 3) < 0.01)
        let stock = try CaptionPreviewImage.frames(style: style)
        #expect(abs((stock.last?.end ?? 0) - 3) < 0.01)
        #expect(stock.count != frames.count || stock.first?.size != frames.first?.size)
    }
}

extension CaptionPreviewImageTests {
    @Test func wordStatesRenderOneSwatchPerStyleGroup() throws {
        var style = CaptionStyle()
        style.highlight = "color"
        style.highlightColor = "#ff0000"
        style.emphasis = "scale"
        let states = try CaptionPreviewImage.wordStates(style: style)
        #expect(states.map(\.kind) == [.text, .highlight, .emphasis])
        for state in states {
            #expect(!state.image.data.isEmpty)
            #expect(state.image.size.width > 0 && state.image.size.height > 0)
        }
        // The scaled emphasis word is wider than the plain one; the coloured
        // spoken word differs in pixels but keeps the plain word's size.
        #expect(states[2].image.size.width > states[0].image.size.width)
        #expect(states[1].image.data != states[0].image.data)
    }
}
