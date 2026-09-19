import Foundation
import Testing
@testable import Clip_Builder

@Suite("Topic segmenter")
struct TopicSegmenterTests {
    private func feature(_ start: Double, _ end: Double, _ text: String, speaker: String?,
                         kind: TranscriptFeatureSegment.Kind = .speech) -> TranscriptFeatureSegment {
        TranscriptFeatureSegment(id: 0, videoID: 1, startTime: start, endTime: end, text: text,
                                 speakerKey: speaker, energy: 0.5, kind: kind)
    }

    @Test("consecutive close lines by one speaker join into one unit; a pause, another speaker, no speaker or a long run keep them apart")
    func coalesce() {
        let lines = [
            feature(0, 3, "Pô foi tudo novo", speaker: "m"),
            feature(3.2, 6, "comecei na cidade", speaker: "m"),
            feature(6.5, 9, "aí fui competir", speaker: "m"),
            feature(9.5, 12, "e você?", speaker: "h"),
            feature(16, 18, "depois de uma pausa", speaker: "h"),
            feature(18, 20, "sem falante", speaker: nil),
            feature(20, 22, "outro sem falante", speaker: nil),
        ]
        let joined = TopicSegmenter.coalesced(lines)
        #expect(joined.map(\.text) == ["Pô foi tudo novo comecei na cidade aí fui competir", "e você?", "depois de uma pausa",
                                       "sem falante", "outro sem falante"])
        #expect(joined[0].startTime == 0 && joined[0].endTime == 9)
        // A run past the span limit is left in pieces so the span rule can cut it.
        let long = (0..<10).map { feature(Double($0) * 10, Double($0) * 10 + 9.5, "l\($0)", speaker: "m") }
        let pieces = TopicSegmenter.coalesced(long)
        #expect(pieces.count == 2 && pieces[0].endTime <= 75)
    }

    @Test("a topic boundary never lands inside an answer")
    func boundariesRespectAnswers() {
        // A host question at 0, a 40 s answer in short lines, a new question after a pause.
        var lines = [feature(0, 4, "como foi?", speaker: "h")]
        for i in 0..<10 { lines.append(feature(4 + Double(i) * 4, 8 + Double(i) * 4, "parte \(i)", speaker: "m")) }
        lines.append(feature(48, 52, "e depois?", speaker: "h"))
        for i in 0..<10 { lines.append(feature(52 + Double(i) * 4, 56 + Double(i) * 4, "mais \(i)", speaker: "m")) }
        let topics = TopicSegmenter.segment(lines, videoID: 1)
        for topic in topics {
            #expect(!(topic.startTime > 4 && topic.startTime < 44), "topic starts mid-answer at \(topic.startTime)")
            #expect(!(topic.startTime > 52 && topic.startTime < 92), "topic starts mid-answer at \(topic.startTime)")
        }
    }
}
