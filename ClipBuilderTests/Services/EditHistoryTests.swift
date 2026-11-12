import Foundation
import Testing
@testable import Clip_Builder

struct EditHistoryTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func aBurstOfEditsIsOneStep() {
        var history = EditHistory(baseline: 0)
        history.record(before: 0, changingTo: 1, at: start)
        history.record(before: 1, changingTo: 2, at: start.addingTimeInterval(0.1))
        history.record(before: 2, changingTo: 3, at: start.addingTimeInterval(0.2))
        #expect(history.undo(from: 3) == 0)
        #expect(!history.canUndo)
        #expect(history.redo(from: 0) == 3)
    }

    @Test func separateEditsAreSeparateSteps() {
        var history = EditHistory(baseline: 0)
        history.record(before: 0, changingTo: 1, at: start)
        history.record(before: 1, changingTo: 2, at: start.addingTimeInterval(5))
        #expect(history.undo(from: 2) == 1)
        #expect(history.undo(from: 1) == 0)
        #expect(history.undo(from: 0) == nil)
        #expect(history.redo(from: 0) == 1)
        #expect(history.redo(from: 1) == 2)
        #expect(!history.canRedo)
    }

    @Test func anEditAfterUndoStartsItsOwnStepAndDropsRedo() {
        var history = EditHistory(baseline: 0)
        history.record(before: 0, changingTo: 1, at: start)
        #expect(history.undo(from: 1) == 0)
        // Right after the undo, inside the burst window: still a new step.
        history.record(before: 0, changingTo: 7, at: start.addingTimeInterval(0.1))
        #expect(!history.canRedo)
        #expect(history.undo(from: 7) == 0)
    }

    @Test func discardReturnsToTheBaselineAndCanBeUndone() {
        var history = EditHistory(baseline: 0)
        #expect(!history.canDiscard(0))
        #expect(history.discard(from: 0) == nil)
        history.record(before: 0, changingTo: 1, at: start)
        history.record(before: 1, changingTo: 2, at: start.addingTimeInterval(5))
        #expect(history.canDiscard(2))
        #expect(history.discard(from: 2) == 0)
        #expect(history.undo(from: 0) == 2)
    }

    @Test func anEditThatChangesNothingIsIgnored() {
        var history = EditHistory(baseline: 0)
        history.record(before: 0, changingTo: 0, at: start)
        #expect(!history.canUndo)
    }

    @Test func historyIsCapped() {
        var history = EditHistory(baseline: 0)
        history.limit = 3
        for step in 0..<10 {
            history.record(before: step, changingTo: step + 1, at: start.addingTimeInterval(Double(step) * 5))
        }
        var current = 10, steps = 0
        while let previous = history.undo(from: current) { current = previous; steps += 1 }
        #expect(steps == 3)
        #expect(current == 7)
    }
}
