import Testing
@testable import Clip_Builder

struct CaptionWordStatesTests {
    @Test func clocksAndGaps() {
        let page = CaptionPage(text: "Hello world", start: 1, end: 4)
        let words = [TranscriptWord(word: "Hello", start: 1.2, end: 2),
                     TranscriptWord(word: "world", start: 2.5, end: 3.5)]
        let states = CaptionWordStates.states(for: page, words: words)
        #expect(states.map(\.activeIndex) == [nil, 0, nil, 1, nil])
        #expect(states.map(\.start) == [1, 1.2, 2, 2.5, 3.5])
        #expect(states.map(\.end) == [1.2, 2, 2.5, 3.5, 4])
    }

    @Test func translationsAndOneWordPages() {
        let page = CaptionPage(text: "Olá mundo", start: 0, end: 2)
        let states = CaptionWordStates.states(for: page, words: [TranscriptWord(word: "Hello", start: 0, end: 2)])
        #expect(states.map(\.activeIndex) == [0, 1])
        #expect(states.map(\.start) == [0, 1])
        let single = CaptionPage(text: "word", start: 3, end: 4)
        #expect(CaptionWordStates.states(for: single, words: nil) == [.init(page: single, activeIndex: 0, start: 3, end: 4)])
    }

    @Test func repeatedWordsKeepTheirOwnPageClocks() {
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: CaptionPresets.styles[3].style)
        let segment = TranscriptSegment(start: 0, end: 3, text: "go go", words: [
            .init(word: "go", start: 0, end: 1), .init(word: "go", start: 2, end: 3)])
        let pages = renderer.pages(for: segment)
        #expect(pages.count == 2)
        let states = CaptionWordStates.states(for: pages[1], words: pages[1].words)
        #expect(states.first?.start == 2 && states.first?.activeIndex == 0)
    }
}
