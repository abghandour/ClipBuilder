import Foundation

/// The rules of the Cleanup Cuts sheet: which cuts a filter shows, what the
/// summary counts, the words around a cut, and how an edge may be nudged.
nonisolated enum CleanupCutReview {
    enum StateFilter: String, CaseIterable, Identifiable, Sendable {
        case pending, cut, kept, all

        var id: String { rawValue }

        var label: String {
            switch self {
            case .pending: "To Review"
            case .cut: "Cut"
            case .kept: "Kept"
            case .all: "All"
            }
        }

        func includes(_ decision: EditProposal.Decision) -> Bool {
            switch self {
            case .pending: decision == .pending
            case .cut: decision == .accepted
            case .kept: decision == .rejected
            case .all: true
            }
        }
    }

    struct Summary: Equatable, Sendable {
        var pending = 0
        var cut = 0
        var kept = 0
        /// Seconds the cuts decided so far remove.
        var removedSeconds = 0.0
        /// Seconds removed if every undecided cut were cut too.
        var possibleSeconds = 0.0

        var total: Int { pending + cut + kept }

        func count(_ filter: StateFilter) -> Int {
            switch filter {
            case .pending: pending
            case .cut: cut
            case .kept: kept
            case .all: total
            }
        }
    }

    /// The words a cut removes and the words on either side of it.
    struct Context: Equatable, Sendable {
        var before = ""
        var removed = ""
        var after = ""

        var isEmpty: Bool { before.isEmpty && removed.isEmpty && after.isEmpty }
    }

    /// Only the kinds that remove footage are reviewed here.
    static func cuts(_ proposals: [EditProposal]) -> [EditProposal] {
        proposals.filter(\.kind.isCleanupCut)
    }

    /// Seconds are counted once where cuts overlap (a nudged edge can
    /// run into its neighbour).
    static func summary(_ cuts: [EditProposal]) -> Summary {
        var summary = Summary()
        for cut in cuts {
            switch cut.decision {
            case .pending: summary.pending += 1
            case .accepted: summary.cut += 1
            case .rejected: summary.kept += 1
            }
        }
        summary.removedSeconds = covered(cuts.filter { $0.decision == .accepted })
        summary.possibleSeconds = covered(cuts.filter { $0.decision != .rejected })
        return summary
    }

    /// The seconds the cuts cover together.
    static func covered(_ cuts: [EditProposal]) -> Double {
        var total = 0.0
        var reach = -Double.greatestFiniteMagnitude
        for cut in cuts.sorted(by: { $0.startTime < $1.startTime }) where cut.endTime > cut.startTime {
            let from = max(cut.startTime, reach)
            if cut.endTime > from { total += cut.endTime - from }
            reach = max(reach, cut.endTime)
        }
        return total
    }

    /// The cuts a filter shows. `sticky` cuts stay listed whatever their
    /// decision, so a cut decided in "To Review" does not jump away under
    /// the pointer.
    static func shown(_ cuts: [EditProposal], state: StateFilter, kind: EditProposal.Kind?,
                      sticky: Set<Int64> = []) -> [EditProposal] {
        cuts.filter { cut in
            (kind == nil || cut.kind == kind) && (state.includes(cut.decision) || sticky.contains(cut.id))
        }
    }

    /// The kinds present under a state filter with their counts, in the
    /// order the analysis lists them.
    static func kinds(_ cuts: [EditProposal], state: StateFilter, sticky: Set<Int64> = []) -> [(kind: EditProposal.Kind, count: Int)] {
        let listed = shown(cuts, state: state, kind: nil, sticky: sticky)
        return EditProposal.Kind.cleanupCuts.compactMap { kind in
            let count = listed.count { $0.kind == kind }
            return count > 0 ? (kind, count) : nil
        }
    }

    /// The words inside the cut and up to `span` words on each side, from
    /// the spoken rows' word timings. A word belongs to the cut when its
    /// middle falls inside it. Rows without word timings give the line the
    /// cut starts in as `after`, so the row still says where it is.
    static func context(for cut: EditProposal, rows: [TranscriptRow], span: Int = 7) -> Context {
        let spoken = rows.filter { !$0.isTranslation }.sorted { $0.startTime < $1.startTime }
        let words = spoken.flatMap { $0.words ?? [] }.sorted { $0.start < $1.start }
        guard !words.isEmpty else {
            let line = spoken.last { $0.startTime <= cut.startTime } ?? spoken.first
            return Context(after: line?.text ?? "")
        }
        var before: [String] = []
        var removed: [String] = []
        var after: [String] = []
        for word in words {
            let middle = (word.start + word.end) / 2
            if middle < cut.startTime {
                before.append(word.word)
            } else if middle <= cut.endTime {
                removed.append(word.word)
            } else {
                after.append(word.word)
                if after.count == span { break }
            }
        }
        return Context(before: joined(before.suffix(span)), removed: joined(removed), after: joined(after))
    }

    private static func joined(_ words: some Sequence<String>) -> String {
        words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The decision a click on Cut or Keep leaves: the same button again
    /// puts the cut back to undecided.
    static func toggled(_ current: EditProposal.Decision, to target: EditProposal.Decision) -> EditProposal.Decision {
        current == target ? .pending : target
    }

    /// A cut with its edges moved, kept inside the file and at least
    /// `minimum` seconds long. An edge that cannot move stays where it is.
    static func nudged(_ cut: EditProposal, start: Double = 0, end: Double = 0,
                       duration: Double, minimum: Double = 0.05) -> EditProposal {
        var result = cut
        let limit = duration > 0 ? duration : .greatestFiniteMagnitude
        if start != 0 {
            result.startTime = min(max(0, cut.startTime + start), result.endTime - minimum)
        }
        if end != 0 {
            result.endTime = max(min(limit, cut.endTime + end), result.startTime + minimum)
        }
        return result
    }

    /// The row to move to from `current` in `shown`: the next or previous
    /// one, the first when nothing is current.
    static func neighbour(of current: Int64?, in shown: [EditProposal], forward: Bool) -> Int64? {
        guard !shown.isEmpty else { return nil }
        guard let current, let index = shown.firstIndex(where: { $0.id == current }) else { return shown.first?.id }
        let next = index + (forward ? 1 : -1)
        return shown[min(max(0, next), shown.count - 1)].id
    }

    /// The ids from `anchor` to `target` inclusive, in list order (a
    /// Shift-click). Just the target when the anchor is not listed.
    static func range(from anchor: Int64?, to target: Int64, in shown: [EditProposal]) -> Set<Int64> {
        guard let anchor, let first = shown.firstIndex(where: { $0.id == anchor }),
              let last = shown.firstIndex(where: { $0.id == target }) else { return [target] }
        return Set(shown[min(first, last)...max(first, last)].map(\.id))
    }

    /// Minutes, seconds and tenths: cuts are often shorter than a second.
    static func timecode(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }

    /// A length as the summary shows it: "0:50", "1:43".
    static func length(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Caption rows as a SubRip file.
nonisolated enum SubRipExport {
    static func document(_ rows: [TranscriptRow]) -> String {
        rows.sorted { $0.startTime < $1.startTime }.enumerated().map { index, row in
            "\(index + 1)\n\(time(row.startTime)) --> \(time(row.endTime))\n\(row.text)\n"
        }.joined(separator: "\n")
    }

    static func time(_ seconds: Double) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60,
                      milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
