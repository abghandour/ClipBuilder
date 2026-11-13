import Foundation

/// One Express Footage section as the user left it, for Undo and Redo.
/// Only what a manual change can touch; ids are local row ids.
nonisolated enum MiniUndoSnapshot: Equatable, Sendable {
    case transcript([TranscriptPick], reelOrder: [MiniReelRules.Key] = [])
    case qa(QA, reelOrder: [MiniReelRules.Key] = [])
    case highlights(Highlights, reelOrder: [MiniReelRules.Key] = [])

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
    static func transcript(picks: [TranscriptPick], reelOrder: [MiniReelRules.Key] = []) -> MiniUndoSnapshot {
        .transcript(picks.enumerated().map { position, pick in
            var pick = pick
            pick.position = position
            pick.sceneID = nil
            pick.projectID = nil
            return pick
        }, reelOrder: reelOrder)
    }

    /// Two snapshots are the same state when the section is the same. The
    /// reel order rides along to be restored and is not compared: the reel
    /// also changes with other sections and with drags in the Preview list,
    /// none of which is a change to this section's history.
    static func == (lhs: MiniUndoSnapshot, rhs: MiniUndoSnapshot) -> Bool {
        switch (lhs, rhs) {
        case (.transcript(let a, _), .transcript(let b, _)): a == b
        case (.qa(let a, _), .qa(let b, _)): a == b
        case (.highlights(let a, _), .highlights(let b, _)): a == b
        default: false
        }
    }

    var reelOrder: [MiniReelRules.Key] {
        switch self {
        case .transcript(_, let order), .qa(_, let order), .highlights(_, let order): order
        }
    }

    /// Another section's history after Undo brought a deleted pick back
    /// under another row id: only where the reel names it changes.
    func remappingReel(pickIDs: [Int64: Int64]) -> MiniUndoSnapshot {
        if case .transcript = self { return self }
        return remapping(pickIDs: pickIDs)
    }

    /// A deleted pick that Undo brought back under another row id.
    func remapping(pickIDs: [Int64: Int64]) -> MiniUndoSnapshot {
        let order = reelOrder.map { key in
            var key = key
            if key.kind == .transcript { key.itemID = pickIDs[key.itemID] ?? key.itemID }
            return key
        }
        switch self {
        case .transcript(let picks, _):
            return .transcript(picks.map { pick in
                var pick = pick
                pick.id = pickIDs[pick.id] ?? pick.id
                return pick
            }, reelOrder: order)
        case .qa(let state, _): return .qa(state, reelOrder: order)
        case .highlights(let state, _): return .highlights(state, reelOrder: order)
        }
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

    /// The reel was arranged since the state at the cursor settled (a drag
    /// in the Preview list, another section's change): that is not a step,
    /// but it is where the next step back must put things. Does nothing
    /// when the section itself is not where the history has it.
    mutating func refreshPlacement(_ state: MiniUndoSnapshot) {
        guard !states.isEmpty, partial == nil, states[cursor] == state else { return }
        states[cursor] = state
    }

    /// The reel order of a Q&A or Highlights history, after a pick it
    /// names came back under another row id.
    mutating func remapReel(pickIDs: [Int64: Int64]) {
        guard !pickIDs.isEmpty else { return }
        states = states.map { $0.remappingReel(pickIDs: pickIDs) }
        partial = partial?.remappingReel(pickIDs: pickIDs)
    }

    mutating func remap(pickIDs: [Int64: Int64]) {
        guard !pickIDs.isEmpty else { return }
        states = states.map { $0.remapping(pickIDs: pickIDs) }
        partial = partial?.remapping(pickIDs: pickIDs)
    }
}
