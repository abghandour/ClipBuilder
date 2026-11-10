import Foundation

/// One Express Footage section as the user left it, for Undo and Redo.
/// Only what a manual change can touch; ids are local row ids.
nonisolated enum MiniUndoSnapshot: Equatable, Sendable {
    case transcript([TranscriptPick])
    case qa(QA)
    case highlights(Highlights)

    struct QA: Equatable, Sendable {
        var kept: Set<Int64>
        var order: [Int64]
        /// Each exchange's trimmed range, by scene id.
        var ranges: [Int64: ClosedRange<Double>]
    }

    struct Highlights: Equatable, Sendable {
        /// A take's plan. `WizardPlan` is not Equatable and comparing two
        /// would mean encoding both, so a plan is told apart by the count
        /// of manual edits its take has had (`AppStore.miniPlanRevisions`).
        struct Plan: Equatable, Sendable {
            var takeID: Int64
            var revision: Int
            var plan: WizardPlan

            static func == (a: Plan, b: Plan) -> Bool { a.takeID == b.takeID && a.revision == b.revision }
        }
        var kept: Set<Int64>
        var order: [Int64]
        var plans: [Int64: Plan]
    }

    /// Picks as Undo compares and restores them: list order, range and
    /// check mark. The scene a pick was saved as is not the user's change.
    static func transcript(picks: [TranscriptPick]) -> MiniUndoSnapshot {
        .transcript(picks.enumerated().map { position, pick in
            var pick = pick
            pick.position = position
            pick.sceneID = nil
            pick.projectID = nil
            return pick
        })
    }

    /// A deleted pick that Undo brought back under another row id.
    func remapping(pickIDs: [Int64: Int64]) -> MiniUndoSnapshot {
        guard case .transcript(let picks) = self else { return self }
        return .transcript(picks.map { pick in
            var pick = pick
            pick.id = pickIDs[pick.id] ?? pick.id
            return pick
        })
    }
}

/// Undo and Redo for one section of one recording: the states the section
/// has settled in, oldest first, and where the user stands among them.
/// Lives in memory, so it lasts while the app is open.
nonisolated struct MiniUndoStack: Sendable {
    /// Steps kept; older ones fall off.
    static let limit = 50
    private(set) var states: [MiniUndoSnapshot] = []
    private(set) var cursor = 0
    /// Where a restore that stopped part way left the section: neither the
    /// state at the cursor nor the target. Kept beside the history, never
    /// in it, so the state at the cursor is still there for the way back.
    private(set) var partial: MiniUndoSnapshot?

    var isEmpty: Bool { states.isEmpty }
    /// The state the section is expected to be in now.
    var current: MiniUndoSnapshot? { states.isEmpty ? nil : partial ?? states[cursor] }
    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor + 1 < states.count }
    var undoTarget: MiniUndoSnapshot? { canUndo ? states[cursor - 1] : nil }
    var redoTarget: MiniUndoSnapshot? { canRedo ? states[cursor + 1] : nil }

    /// The state before the first manual change; later calls do nothing.
    mutating func begin(_ state: MiniUndoSnapshot) {
        if states.isEmpty { states = [state] }
    }

    /// The state a manual change settled in. A change that left the section
    /// as it was is not a step; a real one ends Redo.
    mutating func commit(_ state: MiniUndoSnapshot) {
        guard !states.isEmpty else { states = [state]; return }
        partial = nil
        guard states[cursor] != state else { return }
        states.removeSubrange((cursor + 1)...)
        states.append(state)
        cursor += 1
        let extra = states.count - (Self.limit + 1)
        if extra > 0 {
            states.removeFirst(extra)
            cursor -= extra
        }
    }

    /// Called once the target state has been restored. `settled` is the
    /// section as the restore really left it, which takes the target's
    /// place: a restore only puts back what still exists.
    mutating func stepBack(settledAs settled: MiniUndoSnapshot? = nil) {
        guard canUndo else { return }
        cursor -= 1
        partial = nil
        if let settled { states[cursor] = settled }
    }

    mutating func stepForward(settledAs settled: MiniUndoSnapshot? = nil) {
        guard canRedo else { return }
        cursor += 1
        partial = nil
        if let settled { states[cursor] = settled }
    }

    /// A restore stopped part way: the section stands in `state`, neither
    /// where it was nor at the target. The history is untouched, so the
    /// step can be tried again and, once it works, taken back.
    mutating func settleCurrent(_ state: MiniUndoSnapshot) {
        guard !states.isEmpty else { return }
        partial = state == states[cursor] ? nil : state
    }

    /// The section changed by something that was not recorded: the history
    /// no longer leads anywhere true, and starts again from `state`.
    mutating func reset(to state: MiniUndoSnapshot) {
        states = [state]
        cursor = 0
        partial = nil
    }

    mutating func remap(pickIDs: [Int64: Int64]) {
        guard !pickIDs.isEmpty else { return }
        states = states.map { $0.remapping(pickIDs: pickIDs) }
        partial = partial?.remapping(pickIDs: pickIDs)
    }
}
