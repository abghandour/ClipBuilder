import Testing
@testable import Clip_Builder

struct TranscriptTextDiffTests {
    @Test func unchangedWordsAreSame() {
        #expect(TranscriptTextDiff.diff(original: "one  two", edited: "one\ntwo") == [
            .init(kind: .same, text: "one"), .init(kind: .same, text: "two")])
    }

    @Test func insertionDeletionAndReplacement() {
        #expect(TranscriptTextDiff.diff(original: "one old three", edited: "one new three extra") == [
            .init(kind: .same, text: "one"), .init(kind: .deleted, text: "old"),
            .init(kind: .inserted, text: "new"), .init(kind: .same, text: "three"),
            .init(kind: .inserted, text: "extra")])
    }

    @Test func caseAndPunctuationAreExact() {
        #expect(TranscriptTextDiff.diff(original: "Hello", edited: "hello!") == [
            .init(kind: .deleted, text: "Hello"), .init(kind: .inserted, text: "hello!")])
    }

    @Test func emptyAndRepeatedTokensReconstructBothSides() {
        #expect(TranscriptTextDiff.diff(original: "", edited: "").isEmpty)
        for (original, edited) in [("", "new"), ("old", ""), ("a b a a", "a a b a")] {
            let diff = TranscriptTextDiff.diff(original: original, edited: edited)
            #expect(diff.filter { $0.kind != .inserted }.map(\.text).joined(separator: " ") == original)
            #expect(diff.filter { $0.kind != .deleted }.map(\.text).joined(separator: " ") == edited)
        }
    }
}
