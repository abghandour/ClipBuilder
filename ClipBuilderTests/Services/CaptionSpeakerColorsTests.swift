import Testing
@testable import Clip_Builder

struct CaptionSpeakerColorsTests {
    private let turns: [SpeakerTurn] = [
        .init(videoID: 1, start: 0, end: 2, cluster: 0, confidence: 1, personKey: "ana"),
        .init(videoID: 1, start: 2, end: 6, cluster: 1, confidence: 1, personKey: "bob"),
        .init(videoID: 1, start: 6, end: 8, cluster: 0, confidence: 1, personKey: "ana"),
    ]

    @Test func firstSpeakerWinsAndColoursSurviveCutsAndTranslations() {
        let crossing = TranscriptSegment(start: 1.5, end: 5, text: "Two speakers")
        #expect(CaptionSpeakerColors.color(for: crossing, turns: turns, rows: []) == CaptionSpeakerColors.palette[0])
        let second = TranscriptSegment(start: 3, end: 4, text: "Outra língua")
        #expect(CaptionSpeakerColors.color(for: second, turns: turns, rows: []) == CaptionSpeakerColors.palette[1])
        let returning = TranscriptSegment(start: 7, end: 8, text: "Again")
        #expect(CaptionSpeakerColors.color(for: returning, turns: turns, rows: []) == CaptionSpeakerColors.palette[0])
        #expect(CaptionSpeakerColors.color(for: crossing, turns: [], rows: []) == nil)
    }

    @Test func manualAttributionAndUnknownAreRespected() {
        let segment = TranscriptSegment(start: 0, end: 1, text: "Hello")
        var row = TranscriptRow(id: 1, videoID: 1, language: "en", isTranslation: false,
                                startTime: 0, endTime: 1, text: "Hello", speakerKey: "bob")
        #expect(CaptionSpeakerColors.color(for: segment, turns: turns, rows: [row]) == CaptionSpeakerColors.palette[1])
        row.speakerKey = ""
        #expect(CaptionSpeakerColors.color(for: segment, turns: turns, rows: [row]) == nil)
    }
}
