import Foundation
import Testing
@testable import Clip_Builder

@Suite("Speaker turn cleanup")
struct SpeakerTurnCleanupTests {
    private func turn(_ start: Double, _ end: Double, _ key: String) -> SpeakerTurn {
        var turn = SpeakerTurn(videoID: 1, start: start, end: end, cluster: 0, confidence: 1)
        turn.personKey = key
        return turn
    }

    private func words(_ pairs: [(String, Double, Double)]) -> [TranscriptWord] {
        pairs.map { TranscriptWord(word: $0.0, start: $0.1, end: $0.2) }
    }

    @Test("a two-second hop to another tile in the middle of a sentence is folded back into the speaker")
    func midSentenceHop() {
        let turns = [turn(27, 34, "marcello"), turn(34, 37.3, "marcello"), turn(37.3, 39.3, "thiago"), turn(39.3, 47.5, "marcello")]
        // "…né Kemuel? Boa. Kemuel fala, deixa rolar, deixa pra ir tudo…" runs on across 37.3.
        let ws = words([("né", 35.0, 35.3), (" Kemuel?", 35.3, 35.9), (" Boa.", 36.2, 36.6), (" Kemuel", 36.8, 37.2),
                        (" fala,", 37.3, 37.7), (" deixa", 37.8, 38.1), (" rolar,", 38.1, 38.6), (" deixa", 38.7, 39.0),
                        (" pra", 39.3, 39.5), (" ir", 39.5, 39.7)])
        let cleaned = SpeakerTurnCleanup.absorbInterjections(turns, words: ws)
        #expect(cleaned.map(\.personKey) == ["marcello", "marcello"])
        #expect(cleaned.last?.start == 34 && cleaned.last?.end == 47.5)
    }

    @Test("a hop after a finished sentence, after a pause, longer than three seconds, or between different speakers stands")
    func realHandovers() {
        let sentenceEnded = words([("certo.", 36.5, 37.0), (" Sim", 37.4, 37.8), (" claro", 38.0, 38.4), (" então", 39.4, 39.8)])
        #expect(SpeakerTurnCleanup.absorbInterjections(
            [turn(30, 37.3, "a"), turn(37.3, 39.3, "b"), turn(39.3, 45, "a")], words: sentenceEnded).count == 3)

        let paused = words([("certo", 35.0, 35.4), (" sim", 37.4, 37.8), (" então", 39.4, 39.8)])
        #expect(SpeakerTurnCleanup.absorbInterjections(
            [turn(30, 37.3, "a"), turn(37.3, 39.3, "b"), turn(39.3, 45, "a")], words: paused).count == 3)

        let running = words([("e", 36.9, 37.2), (" aí", 37.3, 37.6), (" foi", 40.0, 40.3), (" isso", 41.8, 42.1)])
        #expect(SpeakerTurnCleanup.absorbInterjections(
            [turn(30, 37.3, "a"), turn(37.3, 41.5, "b"), turn(41.5, 45, "a")], words: running).count == 3)
        #expect(SpeakerTurnCleanup.absorbInterjections(
            [turn(30, 37.3, "a"), turn(37.3, 39.3, "b"), turn(39.3, 45, "c")], words: running).count == 3)
        // No timed words: nothing to go on, the hop stands.
        #expect(SpeakerTurnCleanup.absorbInterjections(
            [turn(30, 37.3, "a"), turn(37.3, 39.3, "b"), turn(39.3, 45, "a")], words: []).count == 3)
    }

    @Test("a hop the voice backs is a short answer and stands even mid-sentence")
    func voiceBackedHopStands() {
        let ws = words([("e", 36.9, 37.2), (" sim", 37.3, 37.6), (" claro", 37.7, 38.0), (" então", 39.4, 39.8)])
        var hop = turn(37.3, 39.3, "b")
        hop.confidence = 0.9
        let turns = [turn(30, 37.3, "a"), hop, turn(39.3, 45, "a")]
        #expect(SpeakerTurnCleanup.absorbInterjections(turns, words: ws).count == 1)
        #expect(SpeakerTurnCleanup.absorbInterjections(turns, words: ws, supported: { $0.confidence >= 0.6 }).count == 3)
    }

    @Test("the re-cut does not split a row at a hop the words show to be mid-sentence")
    func recutHonoursCleanup() {
        let ws = words([("a", 0, 0.4), (" b", 0.5, 0.9), (" c", 1.0, 1.4), (" d", 1.5, 1.9), (" e", 2.0, 2.4), (" f", 2.5, 2.9)])
        let json = String(data: try! JSONEncoder().encode(ws), encoding: .utf8)
        let row = TranscriptRow(id: 1, videoID: 1, language: "pt", isTranslation: false, startTime: 0, endTime: 3,
                                text: "a b c d e f", originalText: nil, wordsJSON: json, provider: nil, model: nil)
        let hop = [turn(-10, 1.0, "a"), turn(1.0, 2.0, "b"), turn(2.0, 10, "a")]
        let plan = TranscriptSpeakerRecut.plan(rows: [row], turns: hop)
        #expect(plan.splitRows == 0 && plan.pieces.count == 1)
    }
}
