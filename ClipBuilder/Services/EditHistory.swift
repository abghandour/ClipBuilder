import Foundation

/// Undo, Redo and Discard for one value edited in place and saved as it
/// changes (a text look in the inspector). The owner reports the value as it
/// was before each edit; a burst of edits close together (a slider drag
/// calls its setter on every tick) is one step.
nonisolated struct EditHistory<Value: Equatable & Sendable>: Sendable {
    /// The value when editing began: what Discard returns to.
    private(set) var baseline: Value
    private var undone: [Value] = []
    private var redone: [Value] = []
    private var lastEdit: Date?
    /// Edits closer together than this join the step before them.
    var burst: TimeInterval = 0.6
    var limit = 100

    init(baseline: Value) { self.baseline = baseline }

    var canUndo: Bool { !undone.isEmpty }
    var canRedo: Bool { !redone.isEmpty }
    func canDiscard(_ current: Value) -> Bool { current != baseline }

    /// Call before an edit replaces `before`.
    mutating func record(before: Value, changingTo after: Value, at time: Date = .now) {
        guard before != after else { return }
        defer { lastEdit = time }
        redone.removeAll()
        if let lastEdit, time.timeIntervalSince(lastEdit) < burst, !undone.isEmpty { return }
        push(before)
    }

    /// The value to restore, or nil when there is nothing to undo.
    mutating func undo(from current: Value) -> Value? {
        guard let previous = undone.popLast() else { return nil }
        redone.append(current)
        lastEdit = nil
        return previous
    }

    mutating func redo(from current: Value) -> Value? {
        guard let next = redone.popLast() else { return nil }
        push(current)
        lastEdit = nil
        return next
    }

    /// Back to the baseline as one step, so Undo brings the edits back.
    mutating func discard(from current: Value) -> Value? {
        guard current != baseline else { return nil }
        push(current)
        redone.removeAll()
        lastEdit = nil
        return baseline
    }

    private mutating func push(_ value: Value) {
        undone.append(value)
        if undone.count > limit { undone.removeFirst(undone.count - limit) }
    }
}
