import Foundation
import Testing
@testable import Clip_Builder

struct MiniBRollRulesTests {
    private func piece(_ id: Int64 = 1, range: ClosedRange<Double> = 10...15, cuts: [BRollCut] = []) -> MiniBRollRules.Piece {
        .init(id: .init(selectionID: id, clipIndex: 0), takeID: id, sceneID: 1, range: range, cuts: cuts)
    }

    private var source: TranscriptQATrim.Transcript {
        var result = TranscriptQATrim.Transcript()
        let words = (0..<6).map { PodcastHighlightTrim.Word(id: $0, text: "word\($0)", start: 10 + Double($0), end: 10.8 + Double($0)) }
        result.words = words
        result.lines = [
            .init(id: 0, start: 10, end: 11.8, speaker: "Host", words: Array(words[0...1])),
            .init(id: 1, start: 12, end: 12.8, speaker: "Host", words: [words[2]]),
            .init(id: 2, start: 13, end: 15.8, speaker: "Guest", words: Array(words[3...5]))
        ]
        return result
    }

    @Test func transcriptUsesReelOrderAndOnlySpeakerChangesBreakBlocks() {
        let pieces = [piece(2, range: 13...16), piece(1, range: 10...13), piece(3, range: 10...12)]
        let result = MiniBRollRules.transcript(pieces: pieces, source: source)
        #expect(result.words.map(\.text) == ["word3", "word4", "word5", "word0", "word1", "word2", "word0", "word1"])
        #expect(result.blocks.map(\.speaker) == ["Guest", "Host"])
        #expect(result.words.map(\.id) == Array(0..<8))
        #expect(result.words[3].pieceID != result.words[6].pieceID)
    }

    @Test func forwardAndBackwardSelectionCannotCrossPieces() throws {
        let transcript = MiniBRollRules.transcript(pieces: [piece(), piece(2, range: 10...16)], source: source)
        let forward = try #require(MiniBRollRules.selection(anchor: 1, target: 10, transcript: transcript))
        #expect(forward.pieceID == piece().id && forward.range.lowerBound == 11 && abs(forward.range.upperBound - 14.8) < 1e-9)
        let backward = try #require(MiniBRollRules.selection(anchor: 7, target: 0, transcript: transcript))
        #expect(backward.pieceID == piece(2).id && backward.range.lowerBound == 10 && abs(backward.range.upperBound - 12.8) < 1e-9)
    }

    @Test func selectionStartsAtFirstWordAndCapsToSceneAndNextCut() throws {
        let item = piece()
        let transcript = MiniBRollRules.transcript(pieces: [item], source: source)
        let selection = try #require(MiniBRollRules.selection(anchor: 1, target: 4, transcript: transcript))
        let scene = Fixtures.scene(id: 20, start: 50, end: 51.5)
        let cut = try #require(MiniBRollRules.makeCut(selection: selection, piece: item, scene: scene))
        #expect(cut.start == 11 && cut.end == 12.5 && cut.sceneOffset == 0)
        #expect(cut.origin == .user && cut.reason == "word1 word2 word3 word4")
        var occupied = item
        occupied.cuts = [.init(start: 12, end: 14, sceneID: 20, sceneOffset: 0, reason: "", origin: .user)]
        #expect(MiniBRollRules.makeCut(selection: selection, piece: occupied, scene: scene)?.end == 12)
        let overlap = MiniBRollRules.Selection(pieceID: item.id, range: 13...14, text: "overlap")
        #expect(MiniBRollRules.makeCut(selection: overlap, piece: occupied, scene: scene) == nil)
    }

    @Test func resizeKeepsStartAndSnapsEndWithinEveryLimit() {
        let cut = BRollCut(start: 10, end: 11.8, sceneID: 20, sceneOffset: 1, reason: "words", origin: .user)
        let next = BRollCut(start: 13, end: 14, sceneID: 20, sceneOffset: 0, reason: "next", origin: .user)
        let scene = Fixtures.scene(id: 20, start: 40, end: 60)
        let item = piece(cuts: [cut, next])
        let words = MiniBRollRules.transcript(pieces: [item], source: source).words
        let bounded = MiniBRollRules.resized(cut, end: 100, piece: item, words: words, scene: scene)
        #expect(bounded.start == 10 && abs(bounded.end - 12.8) < 1e-9)
        #expect(abs(MiniBRollRules.resized(cut, end: 11.7, piece: item, words: words, scene: scene).end - 11.8) < 1e-9)
        #expect(abs(MiniBRollRules.resized(cut, end: 0, piece: item, words: words, scene: scene).end - 10.8) < 1e-9)
        let shortScene = Fixtures.scene(id: 20, start: 40, end: 42)
        #expect(abs(MiniBRollRules.resized(cut, end: 100, piece: item, words: words, scene: shortScene).end - 10.8) < 1e-9)
        let noNext = piece(cuts: [cut])
        #expect(abs(MiniBRollRules.resized(cut, end: 100, piece: noNext, words: words, scene: scene).end - 14.8) < 1e-9)
        #expect(MiniBRollRules.resized(cut, end: .nan, piece: item, words: words, scene: scene) == cut)
    }

    @Test func replaceAndOffsetPreserveAnchorAndStayWithinScene() {
        let cut = BRollCut(start: 10, end: 14, sceneID: 20, sceneOffset: 2, reason: "words", origin: .user)
        let short = Fixtures.scene(id: 30, start: 50, end: 52)
        let replacement = MiniBRollRules.replacing(cut, scene: short)
        #expect(replacement.id == cut.id && replacement.start == 10 && replacement.end == 12)
        #expect(replacement.sceneID == 30 && replacement.sceneOffset == 0)
        let long = Fixtures.scene(id: 20, start: 50, end: 60)
        let offset = MiniBRollRules.offset(cut, to: 100, scene: long)
        #expect(offset.sceneOffset == 6 && offset.start == 10 && offset.end == 14)
        #expect(MiniBRollRules.offset(cut, to: -10, scene: long).sceneOffset == 0)
    }

    @Test func removedWordsDropCutsWhileUnchangedPiecesKeepIdentity() {
        let cut = BRollCut(start: 11, end: 14, sceneID: 20, sceneOffset: 0, reason: "words", origin: .user)
        #expect(MiniBRollRules.retained([cut], in: 10...15) == [cut])
        #expect(MiniBRollRules.retained([cut], in: 12...15).isEmpty)
        #expect(MiniBRollRules.retained([cut], in: 10...13).isEmpty)
    }
}

extension MiniBRollRulesTests {
    @Test func refindingSameFootageRetainsOnlyStillKeptWords() {
        var old = Fixtures.plan(clips: [Fixtures.planClip(start: 10, end: 20)])
        let cut = BRollCut(start: 11, end: 14, sceneID: 2, sceneOffset: 1, reason: "words", origin: .user)
        old.clips[0].brollCuts = [cut]
        let same = MiniBRollRules.preservingCuts(in: Fixtures.plan(clips: [Fixtures.planClip(start: 10, end: 20)]), from: [old])
        #expect(same.clips[0].brollCuts == [cut])
        let shortened = MiniBRollRules.preservingCuts(in: Fixtures.plan(clips: [Fixtures.planClip(start: 12, end: 20)]), from: [old])
        #expect(shortened.clips[0].brollCuts == [])
        let other = MiniBRollRules.preservingCuts(in: Fixtures.plan(clips: [Fixtures.planClip(sceneID: 3, start: 10, end: 20)]), from: [old])
        #expect(other.clips[0].brollCuts == [])
    }
}
