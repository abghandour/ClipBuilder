import Foundation
import Testing
@testable import Clip_Builder

@Suite("Transcript cleanup proposer")
struct TranscriptCleanupProposerTests {
    /// Evenly spaced words: each lasts 80% of `step`, then a short gap.
    private func words(_ text: String, start: Double = 0, step: Double = 0.3) -> [TranscriptWord] {
        text.split(separator: " ").enumerated().map { index, word in
            let begin = start + Double(index) * step
            return TranscriptWord(word: String(word), start: begin, end: begin + step * 0.8)
        }
    }

    private func row(_ id: Int64, _ words: [TranscriptWord], speaker: String? = nil) -> TranscriptRow {
        let json = String(decoding: try! JSONEncoder().encode(words), as: UTF8.self)
        return TranscriptRow(id: id, videoID: 1, language: "en", isTranslation: false,
                             startTime: words.first?.start ?? 0, endTime: words.last?.end ?? 0,
                             text: words.map(\.word).joined(separator: " "), originalText: nil,
                             wordsJSON: json, provider: "test", model: "m", speakerKey: speaker)
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(word: text, start: start, end: end)
    }

    @Test("a filler word is proposed on its own word")
    func filler() {
        let proposals = TranscriptCleanupProposer.propose(rows: [row(7, words("so um we went"))])
        #expect(proposals.count == 1)
        let cut = proposals[0]
        #expect(cut.kind == .filler)
        #expect(cut.rowID == 7)
        #expect(cut.wordRange == 1..<2)
        #expect(abs(cut.startTime - 0.3) < 1e-9)
        #expect(abs(cut.endTime - 0.54) < 1e-9)
    }

    @Test("a bigram filler covers both words")
    func bigramFiller() {
        let proposals = TranscriptCleanupProposer.propose(rows: [row(1, words("it was you know great"))])
        #expect(proposals.map(\.kind) == [.filler])
        #expect(proposals.first?.wordRange == 2..<4)
    }

    @Test("like is filler only between two pauses")
    func conditionalLike() {
        #expect(TranscriptCleanupProposer.propose(rows: [row(1, words("it was like great"))]).isEmpty)
        let paused = [word("it", 0, 0.2), word("was", 0.25, 0.45), word("like", 0.8, 1.0), word("so", 1.4, 1.6)]
        let proposals = TranscriptCleanupProposer.propose(rows: [row(1, paused)])
        #expect(proposals.map(\.kind) == [.filler])
        #expect(proposals.first?.wordRange == 2..<3)
    }

    @Test("a stutter drops the first of the two words")
    func stutter() {
        let proposals = TranscriptCleanupProposer.propose(rows: [row(1, words("the the cat sat"))])
        #expect(proposals.map(\.kind) == [.repeatWord])
        #expect(proposals.first?.wordRange == 0..<1)
    }

    @Test("a short fragment restarted after a pause is a false start")
    func falseStart() {
        let spoken = [word("I", 0, 0.2), word("was", 0.25, 0.45),
                      word("I", 1.0, 1.2), word("think", 1.25, 1.5), word("so.", 1.55, 1.8)]
        let proposals = TranscriptCleanupProposer.propose(rows: [row(1, spoken)])
        #expect(proposals.map(\.kind) == [.falseStart])
        let cut = proposals[0]
        #expect(cut.wordRange == 0..<2)
        #expect(cut.startTime == 0)
        #expect(abs(cut.endTime - 0.75) < 1e-9, "the pause is cut down to the minimum gap")
    }

    @Test("a retake removes the earlier take and keeps the last")
    func retakeKeepsLast() {
        let first = row(1, words("We went to the store yesterday.", start: 0))
        let second = row(2, words("We went to the store yesterday.", start: 3))
        let proposals = TranscriptCleanupProposer.propose(rows: [second, first])
        #expect(proposals.map(\.kind) == [.retake])
        #expect(proposals.first?.rowID == 1)
        #expect(proposals.first?.wordRange == 0..<6)

        let far = row(3, words("We went to the store yesterday.", start: 40))
        #expect(TranscriptCleanupProposer.propose(rows: [first, far]).isEmpty, "outside the retake window")
        let other = row(4, words("We went to the store yesterday.", start: 3), speaker: "guest")
        let host = row(5, words("We went to the store yesterday.", start: 0), speaker: "host")
        #expect(TranscriptCleanupProposer.propose(rows: [host, other]).isEmpty, "another speaker echoing is not a retake")
    }

    @Test("a cut is trimmed to leave the minimum gap on each side")
    func minGapTrimming() {
        let spoken = [word("so", 0, 0.2), word("um", 1.0, 1.2), word("we", 2.0, 2.2)]
        let proposals = TranscriptCleanupProposer.propose(rows: [row(1, spoken)])
        #expect(proposals.count == 1)
        #expect(abs(proposals[0].startTime - 0.45) < 1e-9)
        #expect(abs(proposals[0].endTime - 1.75) < 1e-9)
    }

    @Test("cuts never reach into a kept word and always cover the removed words")
    func wordBoundaries() {
        let spoken = [word("so", 0, 0.2), word("um", 0.3, 0.5), word("the", 0.55, 0.7), word("the", 0.9, 1.1),
                      word("cat", 1.15, 1.4), word("uh", 2.0, 2.3), word("sat.", 2.35, 2.6)]
        let source = row(1, spoken)
        let proposals = TranscriptCleanupProposer.propose(rows: [source])
        #expect(proposals.map(\.kind) == [.filler, .repeatWord, .filler])
        for cut in proposals {
            let before = cut.wordRange.lowerBound > 0 ? spoken[cut.wordRange.lowerBound - 1].end : -Double.infinity
            let after = cut.wordRange.upperBound < spoken.count ? spoken[cut.wordRange.upperBound].start : .infinity
            #expect(cut.startTime >= before - 1e-9)
            #expect(cut.endTime <= after + 1e-9)
            #expect(cut.startTime <= spoken[cut.wordRange.lowerBound].start + 1e-9)
            #expect(cut.endTime >= spoken[cut.wordRange.upperBound - 1].end - 1e-9)
        }
    }

    @Test("a cut shorter than 0.05 s is dropped")
    func tinyCutDropped() {
        let spoken = [word("so", 0, 0.3), word("uh", 0.3, 0.33), word("we", 0.33, 0.6)]
        #expect(TranscriptCleanupProposer.propose(rows: [row(1, spoken)]).isEmpty)
    }

    @Test("similarity is Jaccard on normalized tokens")
    func similarity() {
        #expect(TranscriptCleanupProposer.similarity(["We", "went."], ["we", "went"]) == 1)
        #expect(TranscriptCleanupProposer.similarity(["a", "b"], ["b", "c"]) == 1.0 / 3.0)
        #expect(TranscriptCleanupProposer.similarity([], []) == 0)
    }

    @Test("edit proposals carry the kind in the reason and skip the analyzer's overlaps")
    func editProposals() {
        let rows = [row(1, words("so um we went"))]
        let mapped = TranscriptCleanupProposer.editProposals(rows: rows, videoID: 9)
        #expect(mapped.count == 1)
        #expect(mapped.first?.videoID == 9)
        #expect(mapped.first?.decision == .pending)
        #expect(mapped.first?.reason.hasPrefix("Filler word: ") == true)
        let existing = EditProposal(id: 0, videoID: 9, kind: .filler, startTime: 0, endTime: 1,
                                    reason: "", decision: .pending)
        #expect(TranscriptCleanupProposer.editProposals(rows: rows, videoID: 9, alongside: [existing]).isEmpty)
    }

    @Test("new kinds start pending under every cleanup policy")
    func policyLeavesNewKindsPending() {
        for policy in CleanupCutPolicy.allCases {
            #expect(policy.decision(for: .repeatWord) == .pending)
            #expect(policy.decision(for: .retake) == .pending)
        }
    }
}
