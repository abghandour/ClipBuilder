import Foundation

/// Presentation and source-time editing data shared by Q&A and Highlights.
nonisolated struct RangeReviewItem: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        var ownerID: Int64
        var revisionID: Int64? = nil
        var cutIndex: Int? = nil
    }

    struct Caption: Sendable {
        var text: String
        var lineLimit = 1
        var monospaced = false
    }

    enum TrimPolicy: Sendable {
        /// `pick` is Q&A trimming that also allows an empty range (nothing selected yet).
        case qa, wizard, pick

        var minimumSpan: Double { self == .wizard ? ProposedCutTrim.minimumSpan : TranscriptQATrim.minimumSpan }

        func clamp(_ range: ClosedRange<Double>, limits: ClosedRange<Double>) -> ClosedRange<Double> {
            switch self {
            case .qa: return TranscriptQATrim.clamped(range, limits: limits)
            case .pick:
                if range.upperBound <= range.lowerBound {
                    let at = min(max(limits.lowerBound, range.lowerBound), limits.upperBound)
                    return at...at
                }
                return TranscriptQATrim.clamped(range, limits: limits)
            case .wizard: return ProposedCutTrim.clamp(start: range.lowerBound, end: range.upperBound, scene: limits)
            }
        }

        /// `minimum` is the shortest span the move may leave (Q&A and picks
        /// only): the 1 s default for a dragged edge, 0 for keys and buttons.
        func setting(_ edge: TranscriptQATrim.Edge, at time: Double, in range: ClosedRange<Double>,
                     limits: ClosedRange<Double>, minimum: Double = TranscriptQATrim.minimumSpan) -> ClosedRange<Double> {
            switch self {
            case .qa, .pick: TranscriptQATrim.setting(edge, at: time, in: range, limits: limits, minimum: minimum)
            case .wizard:
                edge == .start ? ProposedCutTrim.settingStart(at: time, in: range, scene: limits)
                    : ProposedCutTrim.settingEnd(at: time, in: range, scene: limits)
            }
        }

        func releasing(_ draft: ClosedRange<Double>, from original: ClosedRange<Double>,
                       words: [TranscriptQATrim.Word], limits: ClosedRange<Double>) -> ClosedRange<Double> {
            switch self {
            case .qa, .pick: TranscriptQATrim.releasing(draft, from: original, words: words, limits: limits)
            case .wizard: clamp(draft, limits: limits)
            }
        }
    }

    var id: ID
    var title: String
    var titleHelp: String
    var keepLabel: String
    var captions: [Caption]
    var video: VideoRecord
    var range: ClosedRange<Double>
    var originalRange: ClosedRange<Double>
    var limits: ClosedRange<Double>
    var trimPolicy: TrimPolicy
    var isAvailable = true
    var children: [RangeReviewItem] = []
    /// A cut's identity that survives a change of its place among its
    /// siblings (`id` names a cut by position); the selection follows it.
    var stableID: Int64? = nil
    /// The span being composed (Transcript picks): not movable or deletable, shown apart.
    var isDraft = false
    /// Rows show this many lines of the title; 0 wraps the whole title.
    var titleLines = 1

    var isTrimmed: Bool {
        ProposedCutTrim.differs(range, proposedStart: originalRange.lowerBound, proposedEnd: originalRange.upperBound)
    }

    static func rangeCaption(_ range: ClosedRange<Double>) -> String {
        "\(range.lowerBound.timecode)–\(range.upperBound.timecode) · \((range.upperBound - range.lowerBound).formatted(.number.precision(.fractionLength(1))))s"
    }

    /// The owners a keep list can check: a draft row has nothing to keep yet.
    static func keepableOwnerIDs(_ items: [RangeReviewItem]) -> Set<Int64> {
        Set(items.filter { !$0.isDraft }.map { $0.id.ownerID })
    }

    static func allKept(_ kept: Set<Int64>, items: [RangeReviewItem]) -> Bool {
        keepableOwnerIDs(items).isSubset(of: kept)
    }

    static func togglingAll(_ kept: Set<Int64>, items: [RangeReviewItem]) -> Set<Int64> {
        allKept(kept, items: items) ? [] : keepableOwnerIDs(items)
    }

    /// Which owners paint their background in the transcript: the kept ones
    /// (none when nothing is kept), whether or not one of them is selected
    /// (the selected item paints itself through its range). `kept` is nil
    /// for lists without Keep boxes (picks): every item is kept, so every
    /// item paints, selection or not.
    static func paintedOwnerIDs(items: [RangeReviewItem], selectedOwnerID: Int64?, kept: Set<Int64>?) -> Set<Int64> {
        let all = Set(items.map { $0.id.ownerID })
        // A keep list paints only what is kept: an empty list paints nothing,
        // so the transcript reads as unmarked until the user keeps something.
        // A draft has no Keep box and always paints its marked span.
        let drafts = Set(items.filter { $0.isDraft }.map { $0.id.ownerID })
        if let kept { return kept.intersection(all).union(drafts).subtracting(selectedOwnerID.map { [$0] } ?? []) }
        return all.subtracting(selectedOwnerID.map { [$0] } ?? [])
    }
}

/// What the list's Play button walks: the selected item (a reel's cuts back
/// to back when it is a reel with cuts), else the kept items in order, else
/// every top-level item.
nonisolated enum RangeReviewPlayAll {
    static func sequence(items: [RangeReviewItem], selectedOwnerID: Int64?,
                         kept: Set<Int64>? = nil) -> [RangeReviewItem] {
        if let selected = items.first(where: { $0.id.ownerID == selectedOwnerID }) {
            if !selected.children.isEmpty { return selected.children.filter(playable) }
            if !selected.isDraft, playable(selected) { return [selected] }
        }
        let all = items.filter { !$0.isDraft && $0.id.cutIndex == nil && playable($0) }
        if let kept, !kept.isEmpty {
            let chosen = all.filter { kept.contains($0.id.ownerID) }
            if !chosen.isEmpty { return chosen }
        }
        return all
    }

    /// True when `sequence` walks one reel's cuts rather than the list.
    static func playsCuts(items: [RangeReviewItem], selectedOwnerID: Int64?) -> Bool {
        items.first { $0.id.ownerID == selectedOwnerID }?.children.isEmpty == false
    }

    private static func playable(_ item: RangeReviewItem) -> Bool {
        item.isAvailable && item.range.upperBound > item.range.lowerBound
    }
}
