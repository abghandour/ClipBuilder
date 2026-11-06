import Foundation
import Testing
@testable import Clip_Builder

struct VoiceCloneSamplerTests {
    private func turn(_ start: Double, _ end: Double, video: Int64 = 1,
                      person: String? = "alice", confidence: Double = 0.9) -> SpeakerTurn {
        SpeakerTurn(videoID: video, start: start, end: end, cluster: person == "alice" ? 0 : 1,
                    confidence: confidence, personKey: person)
    }

    private func row(_ start: Double, _ end: Double, video: Int64 = 1,
                     translated: Bool = false) -> TranscriptRow {
        TranscriptRow(id: 0, videoID: video, language: "pt", isTranslation: translated,
                      startTime: start, endTime: end, text: "Clean speech", originalText: nil,
                      wordsJSON: nil, provider: nil, model: nil)
    }

    @Test func excludesOtherSpeakersAndTheirSafetyMargins() {
        let turns = [turn(0, 20), turn(6, 9, person: "bob"), turn(14, 16, person: nil)]
        let result = VoiceCloneSampler.select(personKey: "alice", name: "Alice", turns: turns,
            transcripts: [row(0, 5.7), row(5.8, 6), row(9, 13), row(9.3, 13.7), row(16, 20), row(16.3, 20)])
        #expect(result.ranges == [
            .init(videoID: 1, start: 0, end: 5.7),
            .init(videoID: 1, start: 9.3, end: 13.7),
            .init(videoID: 1, start: 16.3, end: 20),
        ])
    }

    @Test func requiresThreeSecondsAndConfidenceAndTrimsToWholeRows() {
        let result = VoiceCloneSampler.select(personKey: "alice", name: "Alice",
            turns: [turn(0, 2.9), turn(10, 20, confidence: 0.59), turn(30, 40, confidence: 0.6)],
            transcripts: [row(0, 2.9), row(10, 20), row(29, 32), row(32, 35), row(35, 38), row(38, 41)])
        #expect(result.ranges == [.init(videoID: 1, start: 32, end: 38)])
    }

    @Test func capsAt120SecondsAtATranscriptEdge() {
        let rows = stride(from: 0, to: 180, by: 10).map { row(Double($0), Double($0 + 10)) }
        let result = VoiceCloneSampler.select(personKey: "alice", name: "Alice",
            turns: [turn(0, 180)], transcripts: rows)
        #expect(result.seconds == 120)
        #expect(result.ranges == [.init(videoID: 1, start: 0, end: 120)])
        #expect(result.reason == nil)
    }

    @Test func neverCutsARowJustToFillTheCap() {
        let result = VoiceCloneSampler.select(personKey: "alice", name: "Alice", turns: [turn(0, 150)],
            transcripts: [row(0, 70), row(70, 115), row(115, 150)])
        #expect(result.seconds == 115)
        #expect(result.ranges.first?.end == 115)
    }

    @Test func explainsTooLittleUsingThePersonAndSeconds() {
        let result = VoiceCloneSampler.select(personKey: "alice", name: "Alice",
            turns: [turn(0, 18)], transcripts: [row(0, 18)])
        #expect(result.seconds == 18)
        #expect(result.reason == "Only 18 s of Alice alone; analyze more of their footage or pick a voice.")
        let empty = VoiceCloneSampler.select(personKey: "alice", name: "Alice", turns: [], transcripts: [])
        #expect(empty.reason?.contains("0 s of Alice") == true)
        let enough = VoiceCloneSampler.select(personKey: "alice", name: "Alice",
            turns: [turn(0, 30)], transcripts: [row(0, 30)])
        #expect(enough.reason == nil)
    }

    @Test func spreadsAcrossVideosLongestTurnFirstInEachRound() {
        let result = VoiceCloneSampler.select(personKey: "alice", name: "Alice",
            turns: [turn(0, 40), turn(50, 100), turn(0, 30, video: 2), turn(40, 60, video: 2)],
            transcripts: [row(0, 40), row(50, 100), row(0, 30, video: 2), row(40, 60, video: 2)])
        #expect(result.ranges.map(\.videoID) == [1, 2, 1])
        #expect(result.ranges.map(\.duration) == [50, 30, 40])
        #expect(result.seconds == 120)
    }

    @Test func ignoresTranslationsAndDoesNotCountDuplicateTurnsTwice() {
        let result = VoiceCloneSampler.select(personKey: "alice", name: "Alice",
            turns: [turn(0, 18), turn(0, 18), turn(20, 50)],
            transcripts: [row(0, 18), row(20, 50, translated: true)])
        #expect(result.seconds == 18)
        #expect(result.ranges.count == 1)
    }

    @Test func oneLongVideoCannotConsumeTheOtherVideosShare() {
        let rows = stride(from: 0, to: 180, by: 10).map { row(Double($0), Double($0 + 10)) }
            + [row(0, 30, video: 2)]
        let result = VoiceCloneSampler.select(personKey: "alice", name: "Alice",
            turns: [turn(0, 180), turn(0, 30, video: 2)], transcripts: rows)
        #expect(result.ranges.map(\.videoID) == [1, 2])
        #expect(result.ranges.map(\.duration) == [90, 30])
        #expect(result.seconds == 120)
    }

    @Test func anUnusableLongRowCannotReserveTheWholeBudget() {
        let result = VoiceCloneSampler.select(personKey: "alice", name: "Alice",
            turns: [turn(0, 30), turn(0, 200, video: 2)],
            transcripts: [row(0, 30), row(0, 200, video: 2)])
        #expect(result.seconds == 30)
        #expect(result.reason == nil)
    }
}
