import Foundation

/// One passage the user picked from a transcript in AI Wizard Express. Stored
/// per video; its scene is created only when the picks become selections.
nonisolated struct TranscriptPick: Identifiable, Sendable, Equatable {
    var id: Int64
    var videoID: Int64
    var position: Int
    var start: Double
    var end: Double
    var originalStart: Double
    var originalEnd: Double
    var sceneID: Int64?
    /// Owning project; nil for a legacy pick no project has adopted yet.
    var projectID: Int64? = nil
    /// Unchecked picks stay in the list but are left out of the footage.
    var kept: Bool = true
    /// Shared by the picks added together as one unit; nil for a pick on its own.
    var groupKey: String? = nil

    var range: ClosedRange<Double> { start...max(start, end) }
    var originalRange: ClosedRange<Double> { originalStart...max(originalStart, originalEnd) }
}

/// The transcript review stays available after its picks become selections.
nonisolated struct MiniWizardTranscript: Sendable {
    var rows: [TranscriptRow]
    var labels: [Int64: String]
    var picks: [TranscriptPick]
    var speakerSpans: [TranscriptQATrim.SpeakerSpan] = []
    /// The transcript set `rows` and `picks` were read from.
    var setKey: String? = nil
}

/// Picks added together as one unit: neighbours in the list sharing a group key.
nonisolated enum TranscriptPickUnits {
    /// The list as units, in order. A pick without a key is a unit of one.
    /// A unit sits where its first pick is and holds every pick with its
    /// key in list order, next to each other or not: two Macs adding at the
    /// same time give their picks the same positions, and after a sync the
    /// two units' picks alternate.
    static func units(_ picks: [TranscriptPick]) -> [[TranscriptPick]] {
        var result: [[TranscriptPick]] = []
        var index: [String: Int] = [:]
        for pick in picks {
            if let key = pick.groupKey {
                if let at = index[key] { result[at].append(pick); continue }
                index[key] = result.count
            }
            result.append([pick])
        }
        return result
    }

    /// Which row is selected once the pick at `removed` leaves `unit` (its
    /// pick ids in order) while the one at `selected` was on screen: the
    /// same pick, or the neighbour of the one removed. A unit's row is named
    /// by its first pick, and a unit left with one pick has no cuts.
    static func selectionAfterRemoving(unit: [Int64], removed: Int, selected: Int) -> (owner: Int64, cut: Int?)? {
        guard unit.indices.contains(removed), unit.indices.contains(selected), unit.count > 1 else { return nil }
        var left = unit
        left.remove(at: removed)
        let cut = selected == removed ? min(removed, left.count - 1) : selected > removed ? selected - 1 : selected
        return (left[0], left.count > 1 ? cut : nil)
    }

    /// Every pick id after `unit`'s picks (ids, in order) take `order` (their
    /// old places, in the new order), and the row to select so the cut at
    /// `selected` stays the one on screen.
    static func moving(_ picks: [TranscriptPick], unit: [Int64], order: [Int], selected: Int?)
        -> (ids: [Int64], owner: Int64, cut: Int?)? {
        guard unit.count > 1, order.sorted() == Array(unit.indices) else { return nil }
        let moved = order.map { unit[$0] }
        let members = Set(unit)
        var ids: [Int64] = []
        var placed = false
        for pick in contiguous(picks) {
            if members.contains(pick.id) {
                if !placed { ids += moved; placed = true }
            } else {
                ids.append(pick.id)
            }
        }
        return (ids, moved[0], selected.flatMap { order.firstIndex(of: $0) })
    }

    /// Link (`key` set): `ids`, in that order, become one unit standing
    /// where the first of them stood. Unlink (nil): they lose their key and
    /// stay where they are. Positions follow the list.
    static func linking(_ picks: [TranscriptPick], ids: [Int64], key: String?) -> [TranscriptPick] {
        let byID = Dictionary(picks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<Int64> = []
        let members = ids.filter { byID[$0] != nil && seen.insert($0).inserted }
        guard key != nil ? members.count > 1 : !members.isEmpty else { return picks }
        var result = picks.filter { !seen.contains($0.id) || key == nil }
        if key != nil {
            result.insert(contentsOf: members.compactMap { byID[$0] }, at: picks.prefix { !seen.contains($0.id) }.count)
        }
        return result.enumerated().map { position, pick in
            var pick = pick
            if seen.contains(pick.id) { pick.groupKey = key }
            pick.position = position
            return pick
        }
    }

    /// `added` joins the unit made of `unit` (those still in the list take
    /// its key) right after the unit's last pick; at the end when none is left.
    static func adding(_ added: TranscriptPick, to picks: [TranscriptPick], unit: [Int64]) -> [TranscriptPick] {
        var result = picks.filter { $0.id != added.id }
        let last = result.lastIndex { unit.contains($0.id) }
        result.insert(added, at: last.map { $0 + 1 } ?? result.count)
        return result.enumerated().map { position, pick in
            var pick = pick
            if unit.contains(pick.id) { pick.groupKey = added.groupKey }
            pick.position = position
            return pick
        }
    }

    /// An add may finish after Unlink or Link has changed its old members.
    static func completingAddition(_ added: TranscriptPick, to picks: [TranscriptPick],
                                   originalUnit: [TranscriptPick]) -> [TranscriptPick] {
        let members = picks.filter { pick in
            guard let original = originalUnit.first(where: { $0.id == pick.id }) else { return false }
            return pick.groupKey == original.groupKey
                || (original.groupKey == nil && pick.groupKey == added.groupKey)
        }
        var added = added
        if members.isEmpty { added.groupKey = nil }
        return adding(added, to: picks, unit: members.map(\.id))
    }

    /// The list with every unit's picks next to each other.
    static func contiguous(_ picks: [TranscriptPick]) -> [TranscriptPick] {
        units(picks).flatMap { $0 }
    }

    /// Every pick id, given the units' first pick ids in a new order; units
    /// the order does not name follow in their current order.
    static func order(_ picks: [TranscriptPick], unitOwners: [Int64]) -> [Int64] {
        let units = units(picks)
        let byOwner = Dictionary(units.map { ($0[0].id, $0) }, uniquingKeysWith: { first, _ in first })
        let named = Set(unitOwners)
        return (unitOwners.compactMap { byOwner[$0] } + units.filter { !named.contains($0[0].id) }).flatMap { $0.map(\.id) }
    }

    /// The kept pick ids after the user's Keep boxes say `owners` (units by
    /// their first pick id). A unit that stays checked keeps its cuts as
    /// they were; one newly checked keeps them all.
    static func kept(_ picks: [TranscriptPick], owners: Set<Int64>) -> Set<Int64> {
        var result = Set<Int64>()
        for unit in units(picks) where owners.contains(unit[0].id) {
            let already = unit.filter(\.kept)
            result.formUnion((already.isEmpty ? unit : already).map(\.id))
        }
        return result
    }
}

/// The passages being composed in Express's Transcript tab before Add: one,
/// or several marked with Shift, numbered in the order they were marked.
nonisolated struct TranscriptDraftSelection: Equatable, Sendable {
    /// Every marked passage, in the order marked. None is empty.
    private(set) var spans: [ClosedRange<Double>] = []
    /// Index of the passage being adjusted; `spans.count` while another one
    /// was started (Shift pressed) and has no words yet.
    private(set) var current = 0
    /// Where a passage that was started sits until it has words.
    private(set) var startedAt: Double?

    var currentRange: ClosedRange<Double>? { spans.indices.contains(current) ? spans[current] : nil }
    /// Shown as "#n" once the selection has more than one passage.
    var currentNumber: Int? { spans.count > 1 || current >= spans.count && !spans.isEmpty ? current + 1 : nil }
    var others: [TranscriptDraftSpan] {
        spans.enumerated().filter { $0.offset != current }.map { TranscriptDraftSpan(number: $0.offset + 1, range: $0.element) }
    }

    /// Shift pressed: the next span is a new passage, after the current one.
    mutating func begin() {
        guard let range = currentRange else { return }
        startedAt = range.upperBound
        current = spans.count
    }

    /// The passage being adjusted becomes `range`; an empty range removes it.
    mutating func set(_ range: ClosedRange<Double>) {
        guard range.upperBound > range.lowerBound else { remove(number: current + 1); return }
        if spans.indices.contains(current) {
            spans[current] = range
        } else {
            spans.append(range)
            current = spans.count - 1
        }
        startedAt = nil
    }

    mutating func select(number: Int) {
        guard spans.indices.contains(number - 1) else { return }
        current = number - 1
        startedAt = nil
    }

    /// The passages after it take the numbers before theirs.
    mutating func remove(number: Int) {
        let index = number - 1
        if spans.indices.contains(index) {
            spans.remove(at: index)
            if current > index { current -= 1 }
        }
        current = min(current, max(0, spans.count - 1))
        startedAt = nil
    }
}
