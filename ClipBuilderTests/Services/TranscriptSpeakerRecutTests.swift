import Foundation
import Testing
@testable import Clip_Builder

@Suite("Transcript re-cut by speaker")
struct TranscriptSpeakerRecutTests {
    private func row(_ id: Int64, _ start: Double, _ end: Double, _ text: String,
                     words: [TranscriptWord]? = nil, edited: Bool = false, speakerKey: String? = nil) -> TranscriptRow {
        let json = words.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        return TranscriptRow(id: id, videoID: 1, language: "pt", isTranslation: false, startTime: start, endTime: end,
                             text: text, originalText: edited ? "before" : nil, wordsJSON: json,
                             provider: "apple", model: "SpeechTranscriber", speakerKey: speakerKey)
    }

    private func turn(_ start: Double, _ end: Double, _ key: String?, cluster: Int = 0) -> SpeakerTurn {
        var turn = SpeakerTurn(videoID: 1, start: start, end: end, cluster: cluster, confidence: 1)
        turn.personKey = key
        return turn
    }

    private func words(_ pairs: [(String, Double, Double)]) -> [TranscriptWord] {
        pairs.map { TranscriptWord(word: $0.0, start: $0.1, end: $0.2) }
    }

    @Test("a row that straddles a speaker change splits at the word gap, each half labelled by its turn")
    func splitsAtWordGap() {
        // Marcelo talks until 6:40.4; guernuiel from 6:40.9. The boundary the
        // audio found (6:40.6) falls in the gap between "hein?" and "Não".
        let line = row(1, 386, 392, "Você quase bateu o recorde, hein? Não não éuel.",
                       words: words([("Você", 386.0, 386.4), (" quase", 386.4, 386.8), (" bateu", 386.8, 387.2),
                                     (" o", 387.2, 387.3), (" recorde,", 387.3, 388.0), (" hein?", 388.0, 388.4),
                                     (" Não", 388.9, 389.3), (" não", 389.3, 389.6), (" éuel.", 389.6, 392.0)]))
        let turns = [turn(370, 388.6, "marcello"), turn(388.6, 400, "guernuiel")]
        let pieces = TranscriptSpeakerRecut.split(line, turns: turns)
        #expect(pieces.count == 2)
        #expect(pieces[0].text == "Você quase bateu o recorde, hein?")
        #expect(pieces[1].text == "Não não éuel.")
        #expect(pieces[0].start == 386 && pieces[1].end == 392)
        // Edge to edge, cut at the gap: the first ends where the second starts.
        #expect(pieces[0].end == pieces[1].start)
        #expect(pieces[1].start == 388.9)
        #expect(pieces[0].words?.count == 6 && pieces[1].words?.count == 3)
        #expect(pieces.allSatisfy { $0.split && $0.sourceRowID == 1 })
    }

    @Test("an interjection shorter than a second stays with the speaker around it; a single-speaker row passes through")
    func interjectionsAndPassthrough() {
        let line = row(2, 0, 10, "one two three four five six seven eight nine ten",
                       words: words((0..<10).map { ("w\($0)", Double($0), Double($0) + 0.9) }))
        let turns = [turn(0, 4, "ann"), turn(4, 4.5, "bob"), turn(4.5, 10, "ann")]
        let pieces = TranscriptSpeakerRecut.split(line, turns: turns)
        #expect(pieces.count == 1)
        #expect(!pieces[0].split)
        #expect(pieces[0].text == line.text && pieces[0].words?.count == 10)

        let plan = TranscriptSpeakerRecut.plan(rows: [line], turns: [turn(0, 10, "ann")])
        #expect(plan.splitRows == 0 && !plan.hasChanges && plan.pieces.count == 1)
    }

    @Test("hand-edited rows and translations are never split; manual attribution rides onto every piece")
    func protectedRows() {
        let edited = row(3, 0, 10, "edited text here", words: words([("edited", 0, 3), (" text", 3, 6), (" here", 6, 10)]), edited: true)
        let overridden = row(4, 0, 10, "alpha beta", words: words([("alpha", 0, 4), (" beta", 6, 10)]), speakerKey: "carl")
        var translation = row(5, 0, 10, "alpha beta", words: words([("alpha", 0, 4), (" beta", 6, 10)]))
        translation.isTranslation = true
        let turns = [turn(0, 5, "ann"), turn(5, 10, "bob")]
        #expect(TranscriptSpeakerRecut.split(edited, turns: turns).count == 1)
        let plan = TranscriptSpeakerRecut.plan(rows: [overridden, translation], turns: turns)
        #expect(plan.splitRows == 1)
        #expect(plan.pieces.count == 2)
        #expect(plan.pieces.allSatisfy { $0.speakerKey == "carl" })
    }

    @Test("without word timings the text is spread evenly over the row and cut at the nearest token")
    func proportionalSplit() {
        let line = row(6, 0, 10, "a b c d e f g h i j")
        let turns = [turn(0, 6, "ann"), turn(6, 10, "bob")]
        let pieces = TranscriptSpeakerRecut.split(line, turns: turns)
        #expect(pieces.count == 2)
        #expect(pieces[0].text == "a b c d e f")
        #expect(pieces[1].text == "g h i j")
        #expect(pieces[0].words == nil && pieces[1].words == nil)
    }

    @Test("gaps between turns belong to the speaker before them and spans cover the whole row")
    func spans() {
        let line = row(7, 10, 20, "x")
        let spans = TranscriptSpeakerRecut.speakerSpans(for: line, turns: [turn(8, 13, "ann"), turn(15, 25, "bob")], minimumTurn: 1)
        #expect(spans.map(\.speaker) == ["ann", "bob"])
        #expect(spans[0].start == 10 && spans[0].end == 15 && spans[1].end == 20)
        #expect(TranscriptSpeakerRecut.speakerSpans(for: line, turns: [], minimumTurn: 1).isEmpty)
        // A long turn the row's edge clips to half a second is still a handover, not an interjection.
        let clipped = TranscriptSpeakerRecut.speakerSpans(for: line, turns: [turn(8, 19.5, "ann"), turn(19.5, 30, "bob")], minimumTurn: 1)
        #expect(clipped.map(\.speaker) == ["ann", "bob"] && clipped[1].start == 19.5)
        // A genuinely short turn inside the row still folds.
        let brief = TranscriptSpeakerRecut.speakerSpans(for: line, turns: [turn(8, 14, "ann"), turn(14, 14.5, "bob"), turn(14.5, 30, "ann")], minimumTurn: 1)
        #expect(brief.map(\.speaker) == ["ann"])
        #expect(TranscriptSpeakerRecut.joined(["Olá", " tudo", "bem", "?"]) == "Olá tudo bem?")
    }

    @Test("unnamed turns are told apart by tile before voice cluster, like the transcript's labels")
    func tileIdentity() {
        let line = row(8, 0, 10, "alpha beta", words: words([("alpha", 0, 4), (" beta", 6, 10)]))
        var left = turn(0, 5, nil); left.tile = 0
        var right = turn(5, 10, nil); right.tile = 1
        // Same cluster, different tiles: a real handover.
        #expect(TranscriptSpeakerRecut.split(line, turns: [left, right]).count == 2)
        // Different clusters on one tile: the same person.
        var same = turn(5, 10, nil, cluster: 2); same.tile = 0
        #expect(TranscriptSpeakerRecut.split(line, turns: [left, same]).count == 1)
    }

    @Test("corrections made after a re-cut count as edits beyond the backup; the backup's own do not")
    func editsBeyondBackup() {
        let backup = [row(1, 0, 10, "fixed", edited: true), row(2, 10, 20, "alpha beta", speakerKey: "ann")]
        let recut = [row(3, 0, 10, "fixed", edited: true),
                     row(4, 10, 15, "alpha", speakerKey: "ann"), row(5, 15, 20, "beta", speakerKey: "ann")]
        #expect(!TranscriptSpeakerRecut.hasEdits(recut, beyond: backup))
        var retyped = recut; retyped[1] = row(4, 10, 15, "alfa", edited: true, speakerKey: "ann")
        #expect(TranscriptSpeakerRecut.hasEdits(retyped, beyond: backup))
        var reassigned = recut; reassigned[2].speakerKey = "bob"
        #expect(TranscriptSpeakerRecut.hasEdits(reassigned, beyond: backup))
        var cleared = recut; cleared[1].speakerKey = nil
        #expect(TranscriptSpeakerRecut.hasEdits(cleared, beyond: backup))
        var translation = row(6, 0, 10, "x"); translation.isTranslation = true
        #expect(!TranscriptSpeakerRecut.hasEdits(recut + [translation], beyond: backup))
    }
}
