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

        func setting(_ edge: TranscriptQATrim.Edge, at time: Double, in range: ClosedRange<Double>,
                     limits: ClosedRange<Double>) -> ClosedRange<Double> {
            switch self {
            case .qa, .pick: TranscriptQATrim.setting(edge, at: time, in: range, limits: limits)
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
    /// The span being composed (Transcript picks): not movable or deletable, shown apart.
    var isDraft = false
    /// Rows show this many lines of the title.
    var titleLines = 1

    var isTrimmed: Bool {
        ProposedCutTrim.differs(range, proposedStart: originalRange.lowerBound, proposedEnd: originalRange.upperBound)
    }

    static func rangeCaption(_ range: ClosedRange<Double>) -> String {
        "\(range.lowerBound.timecode)–\(range.upperBound.timecode) · \((range.upperBound - range.lowerBound).formatted(.number.precision(.fractionLength(1))))s"
    }

    static func allKept(_ kept: Set<Int64>, items: [RangeReviewItem]) -> Bool {
        Set(items.map { $0.id.ownerID }).isSubset(of: kept)
    }

    static func togglingAll(_ kept: Set<Int64>, items: [RangeReviewItem]) -> Set<Int64> {
        allKept(kept, items: items) ? [] : Set(items.map { $0.id.ownerID })
    }
}

/// What Play All walks. A reel is a list of cuts, so when the selected item
/// is a reel with cuts (or one of its cuts) Play All plays those cuts back to
/// back; otherwise it plays every top-level item in order.
nonisolated enum RangeReviewPlayAll {
    static func sequence(items: [RangeReviewItem], selectedOwnerID: Int64?) -> [RangeReviewItem] {
        if let reel = items.first(where: { $0.id.ownerID == selectedOwnerID }), !reel.children.isEmpty {
            return reel.children.filter(playable)
        }
        return items.filter { !$0.isDraft && $0.id.cutIndex == nil && playable($0) }
    }

    /// True when `sequence` walks one reel's cuts rather than the list.
    static func playsCuts(items: [RangeReviewItem], selectedOwnerID: Int64?) -> Bool {
        items.first { $0.id.ownerID == selectedOwnerID }?.children.isEmpty == false
    }

    private static func playable(_ item: RangeReviewItem) -> Bool {
        item.isAvailable && item.range.upperBound > item.range.lowerBound
    }
}
