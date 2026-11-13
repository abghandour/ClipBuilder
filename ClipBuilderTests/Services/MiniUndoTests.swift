import Foundation
import Testing
@testable import Clip_Builder

struct MiniUndoTests {
    private func pick(_ id: Int64, _ start: Double, _ end: Double, kept: Bool = true) -> TranscriptPick {
        TranscriptPick(id: id, videoID: 1, position: 0, start: start, end: end, originalStart: start, originalEnd: end,
                       sceneID: nil, kept: kept)
    }
    private func state(_ picks: TranscriptPick...) -> MiniUndoSnapshot { .transcript(picks: picks) }

    @Test func undoThenRedoWalkTheHistory() {
        var stack = MiniUndoStack()
        let empty = state(), one = state(pick(1, 0, 2)), two = state(pick(1, 0, 2), pick(2, 5, 8))
        stack.begin(empty)
        stack.commit(one)
        stack.commit(two)
        #expect(stack.undoTarget == one)
        stack.stepBack()
        #expect(stack.undoTarget == empty)
        stack.stepBack()
        #expect(stack.undoTarget == nil)
        #expect(!stack.canUndo)
        #expect(stack.redoTarget == one)
        stack.stepForward()
        #expect(stack.redoTarget == two)
        stack.stepForward()
        #expect(stack.redoTarget == nil)
    }

    @Test func aReelArrangedSinceIsWhatTheNextStepBackRestores() {
        func key(_ id: Int64) -> MiniReelRules.Key { .init(kind: .transcript, itemID: id) }
        var stack = MiniUndoStack()
        let a = pick(1, 0, 2), b = pick(2, 5, 8)
        stack.begin(.transcript(picks: [a], reelOrder: [key(1)]))
        stack.commit(.transcript(picks: [a, b], reelOrder: [key(1), key(2)]))
        // The reel was dragged to B, A; then B is deleted.
        stack.refreshPlacement(.transcript(picks: [a, b], reelOrder: [key(2), key(1)]))
        stack.commit(.transcript(picks: [a], reelOrder: [key(1)]))
        #expect(stack.undoTarget?.reelOrder == [key(2), key(1)])
        #expect(stack.canUndo)
        // A section that is not where the history has it is left alone.
        stack.refreshPlacement(.transcript(picks: [b], reelOrder: [key(2)]))
        #expect(stack.current?.reelOrder == [key(1)])
    }

    @Test func aPickBroughtBackIsRenamedInAnotherSectionsReelOrder() {
        let order: [MiniReelRules.Key] = [.init(kind: .transcript, itemID: 1), .init(kind: .qa, itemID: 1)]
        var stack = MiniUndoStack()
        stack.begin(.qa(.init(kept: [1], order: [1], ranges: [:]), reelOrder: order))
        stack.remapReel(pickIDs: [1: 9])
        #expect(stack.current?.reelOrder == [.init(kind: .transcript, itemID: 9), order[1]])
        // A transcript history is renamed by `remap`, pick rows included, not here.
        var picks = MiniUndoStack()
        picks.begin(.transcript(picks: [pick(1, 0, 2)], reelOrder: order))
        picks.remapReel(pickIDs: [1: 9])
        #expect(picks.current?.reelOrder == order)
    }

    @Test func aTargetIsOnlyLeftOnceItWasRestored() {
        var stack = MiniUndoStack()
        stack.begin(state())
        stack.commit(state(pick(1, 0, 2)))
        // A restore that failed never calls stepBack: Undo is still offered.
        #expect(stack.undoTarget == state())
        #expect(stack.undoTarget == state())
    }

    @Test func aNewChangeEndsRedo() {
        var stack = MiniUndoStack()
        let empty = state(), one = state(pick(1, 0, 2)), other = state(pick(3, 4, 6))
        stack.begin(empty)
        stack.commit(one)
        stack.stepBack()
        #expect(stack.canRedo)
        stack.commit(other)
        #expect(!stack.canRedo)
        #expect(stack.undoTarget == empty)
    }

    @Test func aChangeThatLeftTheSectionAsItWasIsNotAStep() {
        var stack = MiniUndoStack()
        let empty = state(), one = state(pick(1, 0, 2))
        stack.begin(empty)
        stack.commit(one)
        stack.commit(one)
        stack.stepBack()
        #expect(!stack.canUndo)
        // And it does not end Redo either.
        stack.commit(empty)
        #expect(stack.redoTarget == one)
    }

    @Test func beginOnlySetsTheFirstState() {
        var stack = MiniUndoStack()
        stack.begin(state())
        stack.commit(state(pick(1, 0, 2)))
        stack.begin(state(pick(9, 0, 1)))
        #expect(stack.undoTarget == state())
    }

    @Test func theSavedSceneAndPositionAreNotAChange() {
        var saved = pick(1, 0, 2)
        saved.sceneID = 77
        saved.position = 4
        #expect(MiniUndoSnapshot.transcript(picks: [saved]) == state(pick(1, 0, 2)))
    }

    @Test func aRestoredPickKeepsItsHistoryUnderItsNewID() {
        var stack = MiniUndoStack()
        stack.begin(state(pick(1, 0, 2)))
        stack.commit(state())
        stack.remap(pickIDs: [1: 9])
        #expect(stack.undoTarget == state(pick(9, 0, 2)))
    }

    @Test func aStepTakesTheStateTheRestoreReallyLeft() {
        var stack = MiniUndoStack()
        let two = state(pick(1, 0, 2), pick(2, 5, 8))
        stack.begin(two)
        stack.commit(state())
        // Only one of the two picks could be put back.
        stack.stepBack(settledAs: state(pick(1, 0, 2)))
        #expect(stack.current == state(pick(1, 0, 2)))
        #expect(stack.redoTarget == state())
        stack.stepForward(settledAs: state())
        #expect(stack.undoTarget == state(pick(1, 0, 2)))
    }

    @Test func aHalfDoneRestoreKeepsTheStepsAroundIt() {
        var stack = MiniUndoStack()
        let two = state(pick(1, 0, 2), pick(2, 5, 8))
        stack.begin(two)
        stack.commit(state())
        stack.settleCurrent(state(pick(2, 5, 8)))
        #expect(stack.current == state(pick(2, 5, 8)))
        #expect(stack.undoTarget == two)
        // The retry works; Redo still leads to the state the step left.
        stack.stepBack(settledAs: two)
        #expect(stack.current == two)
        #expect(stack.redoTarget == state())
    }

    @Test func anUnrecordedChangeStartsTheHistoryOver() {
        var stack = MiniUndoStack()
        stack.begin(state())
        stack.commit(state(pick(1, 0, 2)))
        stack.reset(to: state(pick(7, 3, 4)))
        #expect(!stack.canUndo && !stack.canRedo)
        #expect(stack.current == state(pick(7, 3, 4)))
    }

    @Test func historyIsBounded() {
        var stack = MiniUndoStack()
        stack.begin(state())
        for index in 0..<(MiniUndoStack.limit + 20) { stack.commit(state(pick(1, 0, Double(index + 1)))) }
        #expect(stack.states.count == MiniUndoStack.limit + 1)
        #expect(stack.cursor == MiniUndoStack.limit)
        #expect(!stack.canRedo)
    }
}
