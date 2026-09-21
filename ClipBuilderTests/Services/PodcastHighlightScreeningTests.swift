import Foundation
import AppKit
import Testing
@testable import Clip_Builder

@Suite("Podcast highlight screening")
struct PodcastHighlightScreeningTests {
    @MainActor
    @Test func ratingKeysOnlyBelongToActiveScreeningOutsideTextFields() throws {
        for (key, code, expected) in [("u", UInt16(32), PodcastHighlightScreeningState.Verdict.approved),
                                      ("d", 2, .rejected), ("", 126, .approved), ("", 125, .rejected)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code))
            #expect(PodcastHighlightScreeningKeys.verdict(for: event, isActive: true, editingText: false) == expected)
            #expect(PodcastHighlightScreeningKeys.verdict(for: event, isActive: false, editingText: false) == nil)
            #expect(PodcastHighlightScreeningKeys.verdict(for: event, isActive: true, editingText: true) == nil)
        }
        let command = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil, characters: "u", charactersIgnoringModifiers: "u",
            isARepeat: false, keyCode: 32))
        #expect(PodcastHighlightScreeningKeys.verdict(for: command, isActive: true, editingText: false) == nil)
    }

    @Test func verdictsAdvanceAndStopPreservesUnratedSelections() {
        let ids = (0..<4).map { _ in UUID() }
        var state = PodcastHighlightScreeningState(candidateIDs: ids)
        #expect(state.currentID == ids[0])
        state.rate(.rejected)
        state.rate(.approved)
        #expect(state.position == 2)
        #expect(state.approved == [ids[1]])
        #expect(state.selectionOnStop(previous: [ids[0], ids[2]]) == [ids[1], ids[2]])
        state.previous()
        state.rate(.rejected)
        #expect(state.approved.isEmpty)
        #expect(state.rejectedCount == 2 && state.unratedCount == 2)
    }

    @Test func navigationBoundsAndSummaryCanBeRevisited() {
        let id = UUID()
        var state = PodcastHighlightScreeningState(candidateIDs: [id])
        state.previous()
        #expect(state.position == 0)
        state.rate(.approved)
        state.next()
        state.rate(.rejected)
        #expect(state.isComplete && state.currentID == nil && state.approved == [id])
        state.previous()
        #expect(state.currentID == id)
        state.rate(.rejected)
        #expect(state.isComplete && state.approved.isEmpty)
        state.restart()
        #expect(state.position == 0 && state.verdicts[id] == .rejected)
        let empty = PodcastHighlightScreeningState(candidateIDs: [])
        #expect(empty.isComplete && empty.selectionOnStop(previous: [id]).isEmpty)
    }
}
